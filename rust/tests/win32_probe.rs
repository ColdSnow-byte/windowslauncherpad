//! Win32 底层能力的冒烟测试：验证应用枚举、图标提取、壁纸读取在真实系统上可用。
//!
//! 运行：`cargo test -- --nocapture`

use windowslauncherpad_rust::api::launcher::{
    data_dir, desktop_wallpaper, launch_plan, list_apps, load_icon, AppKind,
};

#[test]
fn enumerate_and_extract_icons() {
    let apps = list_apps().expect("list_apps 应能成功");
    println!("枚举到 {} 个应用：", apps.len());
    for a in apps.iter().take(20) {
        println!("  [{:?}] {}\n        id = {}", a.kind, a.name, a.id);
    }
    assert!(!apps.is_empty(), "应至少枚举到一个应用");

    let mut ok = 0usize;
    for a in apps.iter() {
        match load_icon(a.id.clone()) {
            Ok(icon) => {
                assert!(icon.width > 0 && icon.height > 0, "图标尺寸应大于 0");
                assert_eq!(
                    icon.rgba.len(),
                    (icon.width * icon.height * 4) as usize,
                    "RGBA 缓冲区长度应匹配尺寸"
                );
                ok += 1;
            }
            Err(e) => println!("  图标提取失败：{} -> {e:?}", a.name),
        }
    }
    println!("图标提取成功 {ok}/{}", apps.len());
    assert!(
        ok * 100 >= apps.len() * 95,
        "图标提取成功率应不低于 95%（实际 {ok}/{}）",
        apps.len()
    );

    // 启动目标解析：Win32 应用应能还原成真实存在的文件路径
    let win32: Vec<_> = apps
        .iter()
        .filter(|a| matches!(a.kind, AppKind::Win32))
        .collect();
    let resolvable = win32
        .iter()
        .filter(|a| std::path::Path::new(&a.target).exists())
        .count();
    println!("Win32 启动路径可解析 {resolvable}/{}", win32.len());
    assert!(!win32.is_empty(), "应存在 Win32 应用");
    assert!(
        resolvable * 10 >= win32.len() * 9,
        "Win32 启动路径解析率应不低于 90%（实际 {resolvable}/{}）",
        win32.len()
    );

    let uwp = apps
        .iter()
        .filter(|a| matches!(a.kind, AppKind::Uwp))
        .count();
    println!("UWP / 打包应用 {uwp} 个");

    // 每个应用都应至少有一种可用的启动方式
    let mut unsupported = Vec::new();
    for a in apps.iter() {
        let plan = launch_plan(a.id.clone());
        if plan == "unsupported" {
            unsupported.push(a.name.clone());
        }
    }
    println!("示例启动方式：{} -> {}", apps[0].name, launch_plan(apps[0].id.clone()));
    assert!(
        unsupported.is_empty(),
        "以下应用没有可用启动方式：{unsupported:?}"
    );
}

#[test]
fn wallpaper_and_data_dir_are_usable() {
    let wp = desktop_wallpaper();
    println!("壁纸路径 = {wp}");
    if !wp.is_empty() {
        assert!(std::path::Path::new(&wp).exists(), "壁纸文件应存在");
    }

    let dir = data_dir();
    println!("数据目录 = {dir}");
    assert!(!dir.is_empty(), "数据目录不应为空");
    assert!(std::path::Path::new(&dir).exists(), "数据目录应已创建");
}
