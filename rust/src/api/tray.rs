//! 后台常驻：系统托盘图标 + 全局热键。
//!
//! 启动台被收起时只是隐藏窗口，进程继续留在托盘里，因此再次呼出无需重新扫描应用，
//! 图标也已经在内存/磁盘缓存中，可以做到「秒开」。

use std::sync::atomic::{AtomicIsize, AtomicU64, Ordering};

use anyhow::Result;
use windows::core::w;
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::SystemInformation::GetTickCount64;
use windows::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{VK_LSHIFT, VK_RSHIFT};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CallNextHookEx, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu,
    DestroyWindow, DispatchMessageW, GetCursorPos, GetMessageW, LoadIconW, PostQuitMessage,
    RegisterClassW, SetForegroundWindow, SetWindowsHookExW, TrackPopupMenu, TranslateMessage,
    UnhookWindowsHookEx, IDI_APPLICATION, KBDLLHOOKSTRUCT, MF_STRING, MSG, TPM_BOTTOMALIGN,
    TPM_RIGHTBUTTON,
    WH_KEYBOARD_LL, WINDOW_EX_STYLE, WINDOW_STYLE, WM_APP, WM_COMMAND, WM_DESTROY, WM_KEYUP,
    WM_LBUTTONUP, WM_RBUTTONUP, WM_SYSKEYUP, WNDCLASSW,
};

use super::launcher;

const TRAY_UID: u32 = 1;
const WM_TRAYICON: u32 = WM_APP + 1;
const CMD_SHOW: usize = 1;
const CMD_QUIT: usize = 2;

/// 双击 Shift 的最大间隔（毫秒）。
const DOUBLE_TAP_MS: u64 = 420;

static TRAY_HWND: AtomicIsize = AtomicIsize::new(0);
static LAST_SHIFT_UP: AtomicU64 = AtomicU64::new(0);

/// 低级键盘钩子：识别「双击 Shift」呼出启动台。
///
/// 钩子回调会阻塞系统输入，因此这里只做时间判断，
/// 真正的显示动作丢到独立线程执行。
unsafe extern "system" fn keyboard_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 && (wparam.0 as u32 == WM_KEYUP || wparam.0 as u32 == WM_SYSKEYUP) {
        let kb = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
        let vk = VK_LSHIFT.0 as u32;
        if kb.vkCode == vk || kb.vkCode == VK_RSHIFT.0 as u32 {
            let now = unsafe { GetTickCount64() };
            let last = LAST_SHIFT_UP.swap(now, Ordering::SeqCst);
            if last != 0 && now.saturating_sub(last) <= DOUBLE_TAP_MS {
                LAST_SHIFT_UP.store(0, Ordering::SeqCst);
                std::thread::spawn(|| {
                    let _ = launcher::show_window();
                });
            }
        }
    }
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

unsafe extern "system" fn wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_TRAYICON => {
            match lparam.0 as u32 {
                // 左键单击：呼出启动台
                WM_LBUTTONUP => {
                    let _ = launcher::show_window();
                }
                // 右键：弹出菜单
                WM_RBUTTONUP => unsafe {
                    let mut point = POINT::default();
                    let _ = GetCursorPos(&mut point);
                    if let Ok(menu) = CreatePopupMenu() {
                        let _ = AppendMenuW(menu, MF_STRING, CMD_SHOW, w!("显示启动台"));
                        let _ = AppendMenuW(menu, MF_STRING, CMD_QUIT, w!("退出"));
                        // 必须先置前，否则菜单不会自动消失
                        let _ = SetForegroundWindow(hwnd);
                        let _ = TrackPopupMenu(
                            menu,
                            TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
                            point.x,
                            point.y,
                            Some(0),
                            hwnd,
                            None,
                        );
                        let _ = DestroyMenu(menu);
                    }
                },
                _ => {}
            }
            LRESULT(0)
        }
        WM_COMMAND => {
            match wparam.0 & 0xFFFF {
                CMD_SHOW => {
                    let _ = launcher::show_window();
                }
                CMD_QUIT => {
                    let _ = launcher::quit_app();
                }
                _ => {}
            }
            LRESULT(0)
        }
        WM_DESTROY => unsafe {
            PostQuitMessage(0);
            LRESULT(0)
        },
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

/// 启动后台托盘与全局热键（`Ctrl+Alt+Space` 呼出）。重复调用是安全的。
pub fn init_tray() -> Result<()> {
    if TRAY_HWND.load(Ordering::SeqCst) != 0 {
        return Ok(());
    }
    std::thread::Builder::new()
        .name("launcher-tray".to_string())
        .spawn(|| {
            if let Err(e) = tray_thread() {
                eprintln!("[tray] 初始化失败: {e:?}");
            }
        })?;
    Ok(())
}

fn tray_thread() -> Result<()> {
    unsafe {
        let hmodule = GetModuleHandleW(None)?;
        let hinstance = HINSTANCE(hmodule.0);
        let class_name = w!("WindowsLauncherPadTray");

        let wc = WNDCLASSW {
            lpfnWndProc: Some(wnd_proc),
            hInstance: hinstance,
            lpszClassName: class_name,
            ..Default::default()
        };
        RegisterClassW(&wc);

        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class_name,
            w!("启动台"),
            WINDOW_STYLE(0),
            0,
            0,
            0,
            0,
            None,
            None,
            Some(hinstance),
            None,
        )?;
        TRAY_HWND.store(hwnd.0 as isize, Ordering::SeqCst);

        // ── 托盘图标 ──────────────────────────────────────────────────────────
        let hicon = LoadIconW(None, IDI_APPLICATION)?;
        let mut nid = NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: hwnd,
            uID: TRAY_UID,
            uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
            uCallbackMessage: WM_TRAYICON,
            hIcon: hicon,
            ..Default::default()
        };
        let tip: Vec<u16> = "启动台 · 双击 Shift 呼出"
            .encode_utf16()
            .collect();
        let tip_slots = nid.szTip.len() - 1;
        for (index, ch) in tip.iter().take(tip_slots).enumerate() {
            nid.szTip[index] = *ch;
        }
        let _ = Shell_NotifyIconW(NIM_ADD, &nid);

        // ── 全局呼出热键：双击 Shift ──────────────────────────────────────────
        let hook = SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), Some(hinstance), 0);
        if hook.is_err() {
            eprintln!("[tray] 键盘钩子安装失败，双击 Shift 呼出不可用");
        }

        // ── 消息循环 ──────────────────────────────────────────────────────────
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        if let Ok(h) = hook {
            let _ = UnhookWindowsHookEx(h);
        }
        let _ = Shell_NotifyIconW(NIM_DELETE, &nid);
        let _ = DestroyWindow(hwnd);
    }
    Ok(())
}
