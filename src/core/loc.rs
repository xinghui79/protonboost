// 界面语言：与 Python 版一致，按环境变量判断是否中文
use std::sync::OnceLock;

pub fn zh() -> bool {
    static ZH: OnceLock<bool> = OnceLock::new();
    *ZH.get_or_init(|| {
        let value = std::env::var("PROTON_LANG")
            .or_else(|_| std::env::var("LC_ALL"))
            .or_else(|_| std::env::var("LC_MESSAGES"))
            .or_else(|_| std::env::var("LANG"))
            .unwrap_or_default()
            .to_lowercase();
        value.starts_with("zh")
    })
}

/// 快捷方式 ANSI 字符串的代码页，Wine 按 locale 选
pub fn ansi_encoding() -> &'static str {
    let value = std::env::var("LC_ALL")
        .or_else(|_| std::env::var("LC_CTYPE"))
        .or_else(|_| std::env::var("LANG"))
        .unwrap_or_default()
        .to_lowercase();
    for (lang, codepage) in [("zh_tw", "cp950"), ("zh_hk", "cp950"), ("zh", "gbk"), ("ja", "cp932"), ("ko", "cp949")] {
        if value.starts_with(lang) {
            return codepage;
        }
    }
    "cp1252"
}
