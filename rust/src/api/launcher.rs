//! Windows 底层能力：枚举已安装应用、提取高清图标、启动应用、无边框全屏、读取桌面壁纸。
//!
//! 全部通过 Win32 / Shell COM API 实现，经 flutter_rust_bridge 暴露给 Dart。

use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::{LazyLock, Mutex};

use anyhow::{anyhow, Result};
use windows::core::{w, Interface, BOOL, GUID, HSTRING, PCSTR, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, SIZE};
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, DeleteDC, DeleteObject, GetDIBits, GetMonitorInfoW, GetObjectW,
    MonitorFromWindow, BITMAP, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HGDIOBJ,
    MONITOR_DEFAULTTONEAREST, MONITOR_DEFAULTTOPRIMARY, MONITORINFO,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemAlloc, CoTaskMemFree, CoUninitialize, IBindCtx,
    CLSCTX_INPROC_SERVER, CLSCTX_LOCAL_SERVER, COINIT_APARTMENTTHREADED,
};
use windows::Win32::System::Threading::GetCurrentProcessId;
use windows::Win32::UI::Shell::Common::{COMDLG_FILTERSPEC, ITEMIDLIST};
use windows::Win32::UI::Shell::{
    ApplicationActivationManager, FileOpenDialog, IApplicationActivationManager, IContextMenu,
    IEnumIDList, IFileOpenDialog, IShellFolder, IShellItem, IShellItemImageFactory,
    FOS_ALLOWMULTISELECT, FOS_ALLNONSTORAGEITEMS, FOS_FILEMUSTEXIST, FOS_PATHMUSTEXIST,
    SIGDN_FILESYSPATH, SHCreateItemFromIDList,
    SHCreateItemFromParsingName, SHCreateItemWithParent, SHGetIDListFromObject,
    SHGetKnownFolderPath, ShellExecuteW, ACTIVATEOPTIONS, BHID_SFObject, BHID_SFUIObject,
    CMINVOKECOMMANDINFO, CMINVOKECOMMANDINFOEX,
    FOLDERID_LocalAppData, ILCombine, ILFree, KF_FLAG_CREATE, KNOWN_FOLDER_FLAG, SHCONTF_FOLDERS,
    SHCONTF_NONFOLDERS, SIGDN_DESKTOPABSOLUTEPARSING, SIGDN_NORMALDISPLAY, SIIGBF_BIGGERSIZEOK,
    SIIGBF_ICONONLY, SIIGBF_RESIZETOFIT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    BringWindowToTop, EnumWindows, GetClassNameW, GetWindowLongPtrW, GetWindowThreadProcessId,
    IsWindowVisible, PostMessageW, SetForegroundWindow, SetWindowLongPtrW, SetWindowPos,
    ShowWindow,
    SystemParametersInfoW, GWL_EXSTYLE, GWL_STYLE, HWND_NOTOPMOST, HWND_TOPMOST,
    SPI_GETDESKWALLPAPER, SWP_FRAMECHANGED, SWP_NOMOVE, SWP_NOSIZE, SWP_SHOWWINDOW, SW_HIDE,
    SW_MAXIMIZE, SW_RESTORE, SW_SHOW, SW_SHOWNORMAL, WM_CLOSE, WS_CAPTION, WS_EX_TOOLWINDOW,
    WS_MAXIMIZEBOX,
    WS_MINIMIZEBOX, WS_POPUP, WS_SYSMENU, WS_THICKFRAME,
};

// ---------------------------------------------------------------------------
// 对外数据结构
// ---------------------------------------------------------------------------

/// 应用来源类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppKind {
    /// 传统 Win32 应用（快捷方式 / 可执行文件）。
    Win32,
    /// UWP / MSIX 打包应用（通过 AUMID 激活）。
    Uwp,
}

/// 一个可在启动台中展示的应用。
#[derive(Debug, Clone)]
pub struct AppEntry {
    /// 稳定且唯一的标识（`shell:AppsFolder` 中的解析名，UWP 即 AUMID）。
    pub id: String,
    /// 展示名称。
    pub name: String,
    /// 应用来源。
    pub kind: AppKind,
    /// 排序用关键字（小写）。
    pub sort_key: String,
    /// 解析后的真实启动目标；无法解析为文件路径时与 `id` 相同（即 AUMID）。
    pub target: String,
}

/// 原始 RGBA 位图，由 Dart 侧解码为 `ui.Image`。
#[derive(Debug, Clone)]
pub struct IconBitmap {
    pub width: u32,
    pub height: u32,
    /// 长度 = width * height * 4，通道顺序 RGBA。
    pub rgba: Vec<u8>,
}

// ---------------------------------------------------------------------------
// COM 辅助
// ---------------------------------------------------------------------------

/// 在当前线程初始化 COM（容忍已初始化 / 模式冲突），退出时自动反初始化。
struct ComScope {
    should_uninit: bool,
}

impl ComScope {
    fn new() -> Self {
        unsafe {
            let hr = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
            // S_OK / S_FALSE 表示由本作用域负责反初始化；
            // RPC_E_CHANGED_MODE(0x80010106) 表示线程已是其它模式，无需反初始化。
            let should_uninit = hr.is_ok();
            Self { should_uninit }
        }
    }
}

impl Drop for ComScope {
    fn drop(&mut self) {
        if self.should_uninit {
            unsafe { CoUninitialize() };
        }
    }
}

/// 释放 `CoTaskMemAlloc` 系内存（Windows shell 返回的 PIDL / 字符串）。
unsafe fn co_free(ptr: *const c_void) {
    if !ptr.is_null() {
        CoTaskMemFree(Some(ptr));
    }
}

/// 由解析路径（支持 `shell:AppsFolder\\<AUMID>`、`.lnk`、`.exe`）创建 `IShellItem`。
fn shell_item_from_path(path: &str) -> Result<IShellItem> {
    let wide = HSTRING::from(path);
    unsafe {
        let item = SHCreateItemFromParsingName::<PCWSTR, Option<&IBindCtx>, IShellItem>(
            PCWSTR(wide.as_ptr()),
            None,
        )?;
        Ok(item)
    }
}

/// 读取 `IShellItem` 的显示名。
unsafe fn item_display_name(item: &IShellItem, sigdn: windows::Win32::UI::Shell::SIGDN) -> String {
    match item.GetDisplayName(sigdn) {
        Ok(pw) => {
            let s = pw.to_string().unwrap_or_default();
            co_free(pw.0 as *const c_void);
            s
        }
        Err(_) => String::new(),
    }
}

// ---------------------------------------------------------------------------
// 应用索引缓存
//
// `shell:AppsFolder` 的 `SIGDN_DESKTOPABSOLUTEPARSING` 返回的并不是真实文件路径
// （例如 `{6D809377-...}\7-Zip\7zFM.exe`，或 `Microsoft.AutoGenerated.{...}`），
// 直接拿去 `SHCreateItemFromParsingName` / `ShellExecuteW` 会得到 ERROR_FILE_NOT_FOUND。
//
// 因此在枚举时把每个应用的「绝对 PIDL」与「解析后的真实启动目标」缓存下来，
// 之后提取图标与启动都直接使用缓存。
// ---------------------------------------------------------------------------

static PIDL_CACHE: LazyLock<Mutex<HashMap<String, Vec<u8>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

static TARGET_CACHE: LazyLock<Mutex<HashMap<String, String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn cached_pidl(id: &str) -> Option<Vec<u8>> {
    PIDL_CACHE.lock().ok()?.get(id).cloned()
}

fn cached_target(id: &str) -> String {
    TARGET_CACHE
        .lock()
        .ok()
        .and_then(|m| m.get(id).cloned())
        .unwrap_or_default()
}

/// 计算 PIDL 占用的字节数（以 2 字节的 SHITEMID.cb == 0 结束）。
unsafe fn pidl_byte_len(pidl: *const ITEMIDLIST) -> usize {
    let base = pidl as *const u8;
    let mut offset = 0usize;
    loop {
        let cb = std::ptr::read_unaligned(base.add(offset) as *const u16) as usize;
        if cb == 0 {
            return offset + 2;
        }
        offset += cb;
        if offset > 64 * 1024 {
            return offset; // 防御性上限
        }
    }
}

unsafe fn pidl_to_vec(pidl: *const ITEMIDLIST) -> Vec<u8> {
    let len = pidl_byte_len(pidl);
    std::slice::from_raw_parts(pidl as *const u8, len).to_vec()
}

/// 把缓存的 PIDL 字节复制到一份对齐的 COM 内存中。
fn pidl_from_bytes(bytes: &[u8]) -> *mut ITEMIDLIST {
    unsafe {
        let raw = CoTaskMemAlloc(bytes.len());
        if raw.is_null() {
            return std::ptr::null_mut();
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), raw as *mut u8, bytes.len());
        raw as *mut ITEMIDLIST
    }
}

fn parse_guid(text: &str) -> Option<GUID> {
    let parts: Vec<&str> = text.trim_matches(['{', '}']).split('-').collect();
    if parts.len() != 5 {
        return None;
    }
    let d1 = u32::from_str_radix(parts[0], 16).ok()?;
    let d2 = u16::from_str_radix(parts[1], 16).ok()?;
    let d3 = u16::from_str_radix(parts[2], 16).ok()?;
    let d4 = u16::from_str_radix(parts[3], 16).ok()?;
    let d5 = u64::from_str_radix(parts[4], 16).ok()?;
    let tail = ((d4 as u128) << 48) | d5 as u128;
    Some(GUID::from_u128(
        ((d1 as u128) << 96) | ((d2 as u128) << 80) | ((d3 as u128) << 64) | tail,
    ))
}

/// 把 `{已知文件夹 GUID}\相对路径` 形式的解析名还原成真实文件路径。
fn resolve_target(parsing: &str) -> String {
    if !parsing.starts_with('{') {
        return parsing.to_string();
    }
    let Some(end) = parsing.find('}') else {
        return parsing.to_string();
    };
    let Some(guid) = parse_guid(&parsing[..=end]) else {
        return parsing.to_string();
    };
    let rest = parsing[end + 1..].trim_start_matches('\\');
    unsafe {
        match SHGetKnownFolderPath(&guid, KNOWN_FOLDER_FLAG(0), None) {
            Ok(pw) => {
                let base = pw.to_string().unwrap_or_default();
                co_free(pw.0 as *const c_void);
                if base.is_empty() {
                    parsing.to_string()
                } else if rest.is_empty() {
                    base
                } else {
                    format!("{base}\\{rest}")
                }
            }
            Err(_) => parsing.to_string(),
        }
    }
}

fn looks_like_aumid(id: &str) -> bool {
    // 形如 PackageFamilyName!AppId（Microsoft.WindowsCalculator_8wekyb3d8bbwe!App），
    // 或 `Microsoft.AutoGenerated.{...}` / `cn.apifox.app` 这类已注册的 AppUserModelID。
    if id.contains('!') {
        return true;
    }
    !id.contains('\\') && !id.contains('/') && !id.contains(':')
}

/// 为某个应用 id 构造 `IShellItem`，依次尝试 PIDL、AppsFolder 路径、真实路径。
unsafe fn shell_item_for(id: &str) -> Result<IShellItem> {
    if let Some(bytes) = cached_pidl(id) {
        let pidl = pidl_from_bytes(&bytes);
        if !pidl.is_null() {
            let result = SHCreateItemFromIDList::<IShellItem>(pidl);
            CoTaskMemFree(Some(pidl as *const c_void));
            if let Ok(item) = result {
                return Ok(item);
            }
        }
    }

    if let Ok(item) = shell_item_from_path(&format!("shell:AppsFolder\\{id}")) {
        return Ok(item);
    }

    let target = cached_target(id);
    if !target.is_empty() {
        if let Ok(item) = shell_item_from_path(&target) {
            return Ok(item);
        }
    }

    shell_item_from_path(id)
}

fn is_noise(name: &str) -> bool {
    let n = name.trim();
    if n.is_empty() {
        return true;
    }
    // 卸载残留 / 无名称占位项
    n.starts_with('{') && n.ends_with('}')
}

/// 枚举 `shell:AppsFolder` 中的全部应用（等价于「开始菜单 → 所有应用」）。
pub fn list_apps() -> Result<Vec<AppEntry>> {
    let _com = ComScope::new();
    unsafe {
        let apps_folder_item = shell_item_from_path("shell:AppsFolder")?;
        let folder: IShellFolder = apps_folder_item.BindToHandler(None, &BHID_SFObject)?;

        let parent_pidl = SHGetIDListFromObject(&apps_folder_item)?;
        if parent_pidl.is_null() {
            return Err(anyhow!("无法获取 AppsFolder 的 PIDL"));
        }

        let mut enumer: Option<IEnumIDList> = None;
        let flags = SHCONTF_FOLDERS.0 | SHCONTF_NONFOLDERS.0;
        folder.EnumObjects(HWND::default(), flags as u32, &mut enumer).ok()?;
        let enumer = match enumer {
            Some(e) => e,
            None => return Ok(Vec::new()),
        };

        let mut entries: Vec<AppEntry> = Vec::new();
        let mut seen = std::collections::HashSet::new();

        loop {
            let mut arr: [*mut ITEMIDLIST; 1] = [std::ptr::null_mut()];
            let mut fetched: u32 = 0;
            let hr = enumer.Next(&mut arr, Some(&mut fetched));
            let child = arr[0];
            if hr.is_err() || fetched == 0 || child.is_null() {
                break;
            }

            let item = SHCreateItemWithParent::<Option<&IShellFolder>, IShellItem>(
                Some(parent_pidl as *const _),
                None,
                child,
            );
            match item {
                Ok(item) => {
                    let name = item_display_name(&item, SIGDN_NORMALDISPLAY);
                    let parsing = item_display_name(&item, SIGDN_DESKTOPABSOLUTEPARSING);
                    if !is_noise(&name) && !parsing.is_empty() && seen.insert(parsing.clone()) {
                        // 缓存绝对 PIDL（提取图标用）与解析后的真实路径（启动用）
                        let absolute = ILCombine(Some(parent_pidl as *const _), Some(child as *const _));
                        if !absolute.is_null() {
                            let bytes = pidl_to_vec(absolute);
                            ILFree(Some(absolute));
                            if let Ok(mut cache) = PIDL_CACHE.lock() {
                                cache.insert(parsing.clone(), bytes);
                            }
                        }
                        if let Ok(mut cache) = TARGET_CACHE.lock() {
                            cache.insert(parsing.clone(), resolve_target(&parsing));
                        }

                        let target = cached_target(&parsing);
                        let kind = if std::path::Path::new(&target).exists() {
                            AppKind::Win32
                        } else {
                            AppKind::Uwp
                        };
                        entries.push(AppEntry {
                            id: parsing.clone(),
                            name: name.trim().to_string(),
                            kind,
                            sort_key: name.trim().to_lowercase(),
                            target,
                        });
                    }
                }
                Err(_) => { /* 跳过无法解析的项 */ }
            }
            co_free(child as *const c_void);
        }

        co_free(parent_pidl as *const c_void);

        entries.sort_by(|a, b| a.sort_key.cmp(&b.sort_key));
        Ok(entries)
    }
}

// ---------------------------------------------------------------------------
// 图标提取
// ---------------------------------------------------------------------------

/// 把 `HBITMAP` 解码为顶层向下的 RGBA 缓冲区。
unsafe fn hbitmap_to_rgba(hbm: windows::Win32::Graphics::Gdi::HBITMAP) -> Result<IconBitmap> {
    let mut bm = BITMAP::default();
    let got = GetObjectW(
        HGDIOBJ(hbm.0),
        std::mem::size_of::<BITMAP>() as i32,
        Some(&mut bm as *mut _ as *mut c_void),
    );
    if got == 0 || bm.bmWidth <= 0 || bm.bmHeight <= 0 {
        return Err(anyhow!("GetObjectW 失败"));
    }

    let width = bm.bmWidth as u32;
    let height = bm.bmHeight as u32;

    let mut info = BITMAPINFO::default();
    info.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
    info.bmiHeader.biWidth = width as i32;
    info.bmiHeader.biHeight = -(height as i32); // 负数 = 自上而下
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB.0;

    let mut buf = vec![0u8; (width * height * 4) as usize];
    let hdc = CreateCompatibleDC(None);
    if hdc.is_invalid() {
        return Err(anyhow!("CreateCompatibleDC 失败"));
    }
    let lines = GetDIBits(
        hdc,
        hbm,
        0,
        height,
        Some(buf.as_mut_ptr() as *mut c_void),
        &mut info,
        DIB_RGB_COLORS,
    );
    let _ = DeleteDC(hdc);
    if lines == 0 {
        return Err(anyhow!("GetDIBits 失败"));
    }

    // BGRA -> RGBA；同时修正 shell 常见的「预乘 alpha」导致的深色描边。
    let mut has_color = false;
    let mut looks_premultiplied = true;
    for px in buf.chunks_exact(4) {
        let (b, g, r, a) = (px[0], px[1], px[2], px[3]);
        if a > 0 && (r > a || g > a || b > a) {
            looks_premultiplied = false;
            has_color = true;
            break;
        }
        if a > 8 && (r > 0 || g > 0 || b > 0) {
            has_color = true;
        }
    }
    if !has_color {
        // 完全没有有效像素，视为失败，交由上层回退。
        return Err(anyhow!("位图不含有效像素"));
    }

    for px in buf.chunks_exact_mut(4) {
        let (b, g, r, a) = (px[0], px[1], px[2], px[3]);
        let (mut nr, mut ng, mut nb) = (r, g, b);
        if looks_premultiplied && a > 0 && a < 255 {
            let inv = 255.0f32 / a as f32;
            nr = ((r as f32 * inv).min(255.0)) as u8;
            ng = ((g as f32 * inv).min(255.0)) as u8;
            nb = ((b as f32 * inv).min(255.0)) as u8;
        }
        px[0] = nr;
        px[1] = ng;
        px[2] = nb;
        px[3] = a;
    }

    Ok(IconBitmap {
        width,
        height,
        rgba: buf,
    })
}

/// 提取指定应用的高清图标（最长边约 256px 的 RGBA 位图）。
///
/// `id` 为 [`list_apps`] 返回的 `AppEntry::id`。
pub fn load_icon(id: String) -> Result<IconBitmap> {
    let _com = ComScope::new();
    unsafe {
        let item = shell_item_for(&id)?;
        let factory: IShellItemImageFactory = item.cast()?;

        let size = SIZE { cx: 256, cy: 256 };
        let mut flags = SIIGBF_ICONONLY;

        let mut hbm = factory.GetImage(size, flags);
        if hbm.is_err() {
            flags = SIIGBF_ICONONLY | SIIGBF_BIGGERSIZEOK;
            hbm = factory.GetImage(size, flags);
        }
        if hbm.is_err() {
            hbm = factory.GetImage(size, SIIGBF_RESIZETOFIT);
        }

        let hbm = hbm?;
        let result = hbitmap_to_rgba(hbm);
        let _ = DeleteObject(HGDIOBJ(hbm.0));
        result
    }
}

// ---------------------------------------------------------------------------
// 启动应用
// ---------------------------------------------------------------------------

/// 通过 Shell 打开一个文件 / 文件夹 / 协议。
fn shell_execute_with(target: &str, parameters: Option<&str>, file: Option<&str>) -> Result<()> {
    let mut wide: Vec<u16> = target.encode_utf16().collect();
    wide.push(0);
    let verb: Vec<u16> = "open\0".encode_utf16().collect();
    let params_wide: Option<Vec<u16>> =
        parameters.map(|p| p.encode_utf16().chain(std::iter::once(0)).collect());
    let file_wide: Option<Vec<u16>> =
        file.map(|f| f.encode_utf16().chain(std::iter::once(0)).collect());
    unsafe {
        let result = ShellExecuteW(
            None,
            PCWSTR(verb.as_ptr()),
            PCWSTR(wide.as_ptr()),
            params_wide.as_ref().map_or(PCWSTR::null(), |v| PCWSTR(v.as_ptr())),
            file_wide.as_ref().map_or(PCWSTR::null(), |v| PCWSTR(v.as_ptr())),
            SW_RESTORE,
        );
        // ShellExecute 返回值 <= 32 表示失败。
        if result.0 as isize <= 32 {
            return Err(anyhow!(
                "ShellExecuteW 失败，错误码 {}",
                result.0 as isize
            ));
        }
        Ok(())
    }
}

/// 通过 AppUserModelID 激活（UWP / MSIX / 已注册的打包应用）。
fn activate_aumid(aumid: &str) -> Result<()> {
    let mut wide: Vec<u16> = aumid.encode_utf16().collect();
    wide.push(0);
    unsafe {
        let manager: IApplicationActivationManager =
            CoCreateInstance(&ApplicationActivationManager, None, CLSCTX_LOCAL_SERVER)?;
        manager.ActivateApplication(
            PCWSTR(wide.as_ptr()),
            PCWSTR::null(),
            ACTIVATEOPTIONS(0),
        )?;
        Ok(())
    }
}

/// 通过 Shell 打开一个文件 / 文件夹 / 协议。
fn shell_execute(target: &str) -> Result<()> {
    shell_execute_with(target, None, None)
}

/// 通过 `IContextMenu` 调用 Shell 项的默认动词（等价于资源管理器里双击「打开」）。
///
/// 这是对 `shell:AppsFolder` 条目最通用的启动方式，连没有真实文件路径的条目也能工作。
fn invoke_default_verb(id: &str) -> Result<()> {
    unsafe {
        let item = shell_item_for(id)?;
        let menu: IContextMenu = item.BindToHandler(None, &BHID_SFUIObject)?;
        // CMIC_MASK_UNICODE = 0x00004000，CMIC_MASK_ASYNCOK = 0x00100000
        const CMIC_MASK_UNICODE: u32 = 0x0000_4000;
        const CMIC_MASK_ASYNCOK: u32 = 0x0010_0000;

        let mut info = CMINVOKECOMMANDINFOEX {
            cbSize: std::mem::size_of::<CMINVOKECOMMANDINFOEX>() as u32,
            fMask: CMIC_MASK_UNICODE | CMIC_MASK_ASYNCOK,
            // MAKEINTRESOURCE(0) 即「默认动词」；空指针的 HIWORD 为 0，会被识别为整数资源
            lpVerb: PCSTR(std::ptr::null()),
            lpVerbW: PCWSTR(std::ptr::null()),
            nShow: SW_SHOWNORMAL.0,
            ..Default::default()
        };
        menu.InvokeCommand(&mut info as *mut CMINVOKECOMMANDINFOEX as *mut CMINVOKECOMMANDINFO)?;
        Ok(())
    }
}

/// 针对某个应用的启动方式。
enum LaunchPlan {
    /// 直接 Shell 打开真实文件。
    ShellExecute(String),
    /// 通过 AppUserModelID 激活。
    Activate(String),
    /// 走 Shell 默认动词。
    DefaultVerb,
    /// 无可用方式。
    Unsupported,
}

fn plan_for(id: &str) -> LaunchPlan {
    // 用户手动添加的图标：id 本身就是文件路径
    if std::path::Path::new(id).exists() {
        return LaunchPlan::ShellExecute(id.to_string());
    }
    let target = cached_target(id);
    if !target.is_empty() && std::path::Path::new(&target).exists() {
        return LaunchPlan::ShellExecute(target);
    }
    if looks_like_aumid(id) {
        return LaunchPlan::Activate(id.to_string());
    }
    if !target.is_empty() && target != id {
        return LaunchPlan::Activate(target);
    }
    if !id.is_empty() {
        return LaunchPlan::DefaultVerb;
    }
    LaunchPlan::Unsupported
}

/// 启动应用。
///
/// AppsFolder 中的条目未必对应真实文件路径，因此按可靠性依次尝试多种方式。
pub fn launch_app(id: String) -> Result<()> {
    let _com = ComScope::new();

    match plan_for(&id) {
        LaunchPlan::ShellExecute(path) => {
            if shell_execute(&path).is_ok() {
                return Ok(());
            }
            if invoke_default_verb(&id).is_ok() {
                return Ok(());
            }
        }
        LaunchPlan::Activate(aumid) => {
            if activate_aumid(&aumid).is_ok() {
                return Ok(());
            }
            let target = cached_target(&id);
            let second = if aumid == id { target } else { id.clone() };
            if !second.is_empty() && second != aumid && activate_aumid(&second).is_ok() {
                return Ok(());
            }
            if invoke_default_verb(&id).is_ok() {
                return Ok(());
            }
        }
        LaunchPlan::DefaultVerb => {
            if invoke_default_verb(&id).is_ok() {
                return Ok(());
            }
        }
        LaunchPlan::Unsupported => {}
    }

    // 最后再试几个通用兜底
    let target = cached_target(&id);
    for candidate in [
        format!("shell:AppsFolder\\{id}"),
        target.clone(),
        id.clone(),
    ] {
        if candidate.is_empty() {
            continue;
        }
        if shell_execute(&candidate).is_ok() {
            return Ok(());
        }
    }

    Err(anyhow!("无法启动应用：{id}"))
}

/// 诊断用：返回该应用会采用的启动方式，便于在 UI 中排查问题。
pub fn launch_plan(id: String) -> String {
    match plan_for(&id) {
        LaunchPlan::ShellExecute(path) => format!("shell:{path}"),
        LaunchPlan::Activate(aumid) => format!("aumid:{aumid}"),
        LaunchPlan::DefaultVerb => "default-verb".to_string(),
        LaunchPlan::Unsupported => "unsupported".to_string(),
    }
}

/// 在资源管理器中定位该应用的可执行文件 / 快捷方式。
pub fn reveal_in_explorer(id: String) -> Result<()> {
    let _com = ComScope::new();
    let target = cached_target(&id);
    if target.is_empty() || !std::path::Path::new(&target).exists() {
        return Err(anyhow!("该应用没有可定位的文件路径：{id}"));
    }
    let args = format!("/select,\"{target}\"");
    unsafe {
        let mut exe: Vec<u16> = "explorer.exe".encode_utf16().chain(std::iter::once(0)).collect();
        let mut verb: Vec<u16> = "open".encode_utf16().chain(std::iter::once(0)).collect();
        let mut params: Vec<u16> = args.encode_utf16().chain(std::iter::once(0)).collect();
        let result = ShellExecuteW(
            None,
            PCWSTR(verb.as_mut_ptr()),
            PCWSTR(exe.as_mut_ptr()),
            PCWSTR(params.as_mut_ptr()),
            PCWSTR::null(),
            SW_RESTORE,
        );
        if result.0 as isize <= 32 {
            return Err(anyhow!("无法打开资源管理器，错误码 {}", result.0 as isize));
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// 桌面壁纸
// ---------------------------------------------------------------------------

/// 返回当前桌面壁纸的文件路径（不可用时返回空串）。
pub fn desktop_wallpaper() -> String {
    unsafe {
        let mut buf = vec![0u16; 32768];
        let ok = SystemParametersInfoW(
            SPI_GETDESKWALLPAPER,
            buf.len() as u32,
            Some(buf.as_mut_ptr() as *mut c_void),
            Default::default(),
        );
        if ok.is_err() {
            return String::new();
        }
        let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        if end == 0 {
            return String::new();
        }
        String::from_utf16_lossy(&buf[..end])
    }
}

// ---------------------------------------------------------------------------
// 无边框全屏
// ---------------------------------------------------------------------------

static MAIN_HWND: Mutex<isize> = Mutex::new(0);
static ORIGINAL_STYLE: Mutex<isize> = Mutex::new(0);

unsafe extern "system" fn find_flutter_window(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let mut pid: u32 = 0;
    GetWindowThreadProcessId(hwnd, Some(&mut pid));
    if pid == GetCurrentProcessId() {
        let mut buf = [0u16; 512];
        let n = GetClassNameW(hwnd, &mut buf);
        if n > 0 {
            let class = String::from_utf16_lossy(&buf[..n as usize]);
            if class.contains("FLUTTER") {
                *(lparam.0 as *mut isize) = hwnd.0 as isize;
                return BOOL(0); // 找到了，停止枚举
            }
        }
    }
    BOOL(1)
}

fn main_window() -> Result<HWND> {
    let cached = *MAIN_HWND.lock().unwrap();
    if cached != 0 {
        return Ok(HWND(cached as *mut c_void));
    }
    let mut found: isize = 0;
    unsafe {
        let _ = EnumWindows(Some(find_flutter_window), LPARAM(&mut found as *mut isize as isize));
    }
    if found == 0 {
        return Err(anyhow!("未找到 Flutter 窗口"));
    }
    *MAIN_HWND.lock().unwrap() = found;
    Ok(HWND(found as *mut c_void))
}

/// 无边框全屏（覆盖任务栏并置于最前），`enabled = false` 时还原。
pub fn set_fullscreen(enabled: bool) -> Result<()> {
    let hwnd = main_window()?;
    unsafe {
        if enabled {
            let style = GetWindowLongPtrW(hwnd, GWL_STYLE);
            *ORIGINAL_STYLE.lock().unwrap() = style;

            let remove = (WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU).0
                as isize;
            let new_style = (style & !remove) | WS_POPUP.0 as isize;
            SetWindowLongPtrW(hwnd, GWL_STYLE, new_style);

            // 同时移出 Alt+Tab / 任务栏，避免启动台被误切换
            let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex & !(WS_EX_TOOLWINDOW.0 as isize));

            let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            let mut mi = MONITORINFO {
                cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                ..Default::default()
            };
            if GetMonitorInfoW(monitor, &mut mi).as_bool() {
                let r = mi.rcMonitor;
                SetWindowPos(
                    hwnd,
                    Some(HWND_TOPMOST),
                    r.left,
                    r.top,
                    r.right - r.left,
                    r.bottom - r.top,
                    SWP_FRAMECHANGED | SWP_SHOWWINDOW,
                )?;
            } else {
                let _ = ShowWindow(hwnd, SW_MAXIMIZE);
            }
            let _ = BringWindowToTop(hwnd);
            let _ = SetForegroundWindow(hwnd);
        } else {
            let style = *ORIGINAL_STYLE.lock().unwrap();
            if style != 0 {
                SetWindowLongPtrW(hwnd, GWL_STYLE, style);
            }
            SetWindowPos(
                hwnd,
                Some(HWND_NOTOPMOST),
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED,
            )?;
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
    }
    Ok(())
}

/// 退出全屏并恢复成居中的普通窗口（设置页用）。
///
/// 与 `set_fullscreen(false)` 的区别：这里会把窗口尺寸真正还原成给定值，
/// 否则窗口会保持「显示器大小 + 标题栏」，底部的按钮可能被挤到屏幕外。
pub fn set_windowed(width: i32, height: i32) -> Result<()> {
    let hwnd = main_window()?;
    unsafe {
        let style = *ORIGINAL_STYLE.lock().unwrap();
        if style != 0 {
            SetWindowLongPtrW(hwnd, GWL_STYLE, style);
        }
        let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        let mut mi = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        let (left, top) = if GetMonitorInfoW(monitor, &mut mi).as_bool() {
            let work = mi.rcWork; // 工作区，避开任务栏
            (
                work.left + ((work.right - work.left) - width) / 2,
                work.top + ((work.bottom - work.top) - height) / 2,
            )
        } else {
            (80, 60)
        };
        SetWindowPos(
            hwnd,
            Some(HWND_NOTOPMOST),
            left,
            top,
            width,
            height,
            SWP_FRAMECHANGED | SWP_SHOWWINDOW,
        )?;
        let _ = SetForegroundWindow(hwnd);
    }
    Ok(())
}

/// 让窗口重新获得前台焦点（用于从最小化恢复）。
pub fn focus_window() -> Result<()> {
    let hwnd = main_window()?;
    unsafe {
        let _ = SetForegroundWindow(hwnd);
        let _ = BringWindowToTop(hwnd);
    }
    Ok(())
}

/// 隐藏窗口，进程留在后台以便热启动。
pub fn hide_window() -> Result<()> {
    let hwnd = main_window()?;
    unsafe {
        let _ = ShowWindow(hwnd, SW_HIDE);
    }
    Ok(())
}

/// 显示并置前窗口（热启动）。
pub fn show_window() -> Result<()> {
    let hwnd = main_window()?;
    unsafe {
        let _ = ShowWindow(hwnd, SW_SHOW);
        let _ = ShowWindow(hwnd, SW_RESTORE);
        let _ = BringWindowToTop(hwnd);
        let _ = SetForegroundWindow(hwnd);
    }
    set_fullscreen(true)
}

/// 窗口当前是否可见（用于判断是否从托盘被重新呼出）。
pub fn is_window_visible() -> bool {
    match main_window() {
        Ok(hwnd) => unsafe { IsWindowVisible(hwnd).as_bool() },
        Err(_) => false,
    }
}

/// 真正退出进程。
pub fn quit_app() -> Result<()> {
    let hwnd = main_window()?;
    unsafe {
        let _ = PostMessageW(Some(hwnd), WM_CLOSE, Default::default(), Default::default());
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// 目录
// ---------------------------------------------------------------------------

/// 弹出系统「打开文件」对话框，返回用户选中的可执行文件 / 快捷方式路径。
///
/// 用户取消时返回空列表。
pub fn pick_files() -> Result<Vec<String>> {
    let _com = ComScope::new();
    unsafe {
        let dialog: IFileOpenDialog = CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER)?;

        let mut options = dialog.GetOptions()?;
        options |= FOS_FILEMUSTEXIST | FOS_ALLOWMULTISELECT | FOS_ALLNONSTORAGEITEMS
            | FOS_PATHMUSTEXIST;
        dialog.SetOptions(options)?;
        dialog.SetTitle(w!("选择要添加到启动台的应用"))?;

        let filters = [COMDLG_FILTERSPEC {
            pszName: w!("应用程序"),
            pszSpec: w!("*.exe;*.lnk;*.bat;*.cmd;*.url;*.msc"),
        }];
        dialog.SetFileTypes(&filters)?;

        // 用户取消时 Show 返回 ERROR_CANCELLED
        if dialog.Show(None).is_err() {
            return Ok(Vec::new());
        }

        let items = dialog.GetResults()?;
        let count = items.GetCount()?;
        let mut paths = Vec::with_capacity(count as usize);
        for index in 0..count {
            let item: IShellItem = items.GetItemAt(index)?;
            let name = item_display_name(&item, SIGDN_FILESYSPATH);
            if !name.is_empty() {
                paths.push(name);
            }
        }
        Ok(paths)
    }
}

/// 返回用于缓存图标/布局的本地目录（`%LOCALAPPDATA%\\WindowsLauncherPad`），不存在则创建。
pub fn data_dir() -> String {
    unsafe {
        match SHGetKnownFolderPath(&FOLDERID_LocalAppData, KF_FLAG_CREATE, None) {
            Ok(pw) => {
                let base = pw.to_string().unwrap_or_default();
                co_free(pw.0 as *const c_void);
                let dir = format!("{base}\\WindowsLauncherPad");
                let _ = std::fs::create_dir_all(&dir);
                dir
            }
            Err(_) => {
                let dir = std::env::temp_dir().join("WindowsLauncherPad");
                let _ = std::fs::create_dir_all(&dir);
                dir.to_string_lossy().to_string()
            }
        }
    }
}

/// 当前显示器主屏尺寸（物理像素），用于窗口初始化。
pub fn primary_screen_size() -> (i32, i32) {
    unsafe {
        let hwnd = HWND::default();
        let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY);
        let mut mi = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if GetMonitorInfoW(monitor, &mut mi).as_bool() {
            let r = mi.rcMonitor;
            (r.right - r.left, r.bottom - r.top)
        } else {
            (1920, 1080)
        }
    }
}
