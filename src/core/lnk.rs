// Windows 快捷方式（.lnk）解析：目标、参数、图标
// 从 Python 版移植：链接头、LinkInfo、ShellItemIDList 三处都能给路径
use encoding_rs::GBK;
use std::path::Path;

fn decode_ansi(raw: &[u8]) -> String {
    match crate::core::loc::ansi_encoding() {
        "gbk" => GBK.decode(raw).0.into_owned(),
        // 其余代码页少见；latin-1 逐字节保真
        _ => raw.iter().map(|b| *b as char).collect(),
    }
}

fn read_utf16_cstring(data: &[u8], offset: usize) -> String {
    let mut end = offset;
    while end + 1 < data.len() && !(data[end] == 0 && data[end + 1] == 0) {
        end += 2;
    }
    let slice: Vec<u16> = data[offset..end.min(data.len())]
        .chunks_exact(2)
        .map(|c| u16::from_le_bytes([c[0], c[1]]))
        .collect();
    String::from_utf16_lossy(&slice)
}

fn read_lnk_string(data: &[u8], offset: &mut usize, unicode: bool) -> String {
    if *offset + 2 > data.len() {
        return String::new();
    }
    let length = u16::from_le_bytes([data[*offset], data[*offset + 1]]) as usize;
    *offset += 2;
    if unicode {
        let size = length * 2;
        let end = (*offset + size).min(data.len());
        let slice: Vec<u16> = data[*offset..end]
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        *offset += size;
        String::from_utf16_lossy(&slice).trim_end_matches('\0').to_string()
    } else {
        let end = (*offset + length).min(data.len());
        let text = decode_ansi(&data[*offset..end]).trim_end_matches('\0').to_string();
        *offset += length;
        text
    }
}

fn join_lnk_path(base: &str, suffix: &str) -> String {
    if !suffix.is_empty()
        && !base.is_empty()
        && !base.to_lowercase().ends_with(&suffix.to_lowercase())
    {
        return format!("{}\\{}", base.trim_end_matches(['\\', '/']), suffix.trim_start_matches(['\\', '/']));
    }
    base.to_string()
}

/// 文件项在扩展块里保留的 unicode 名：块尾倒数第二、三字节是它到块尾的偏移
fn lnk_item_long_name(item: &[u8]) -> String {
    if item.len() < 20 {
        return String::new();
    }
    let start = u16::from_le_bytes([item[item.len() - 2], item[item.len() - 1]]) as usize;
    if !(14..item.len() - 4).contains(&start)
        || start + u16::from_le_bytes([item[start], item[start + 1]]) as usize != item.len()
    {
        return String::new();
    }
    let end = item.len() - 4;
    if item[end] != 0 || item[end + 1] != 0 {
        return String::new();
    }
    let mut begin = end;
    while begin >= start + 10 && !(item[begin - 2] == 0 && item[begin - 1] == 0) {
        begin -= 2;
    }
    let slice: Vec<u16> = item[begin..end]
        .chunks_exact(2)
        .map(|c| u16::from_le_bytes([c[0], c[1]]))
        .collect();
    String::from_utf16_lossy(&slice)
}

/// 目标路径按 ShellItemIDList 拼：盘符、各级文件夹与文件都取 unicode 名
fn parse_lnk_id_list(id_list: &[u8]) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut offset = 0;
    while offset + 3 <= id_list.len() {
        let size = u16::from_le_bytes([id_list[offset], id_list[offset + 1]]) as usize;
        if size < 3 || offset + size > id_list.len() {
            break;
        }
        let item = &id_list[offset..offset + size];
        offset += size;
        let kind = item[2] & 0x70;
        if kind == 0x10 && parts.is_empty() {
            continue; // 我的电脑
        }
        if kind == 0x20 && parts.is_empty() {
            // 盘符，"C:\"
            let drive: Vec<u8> = item[3..].split(|b| *b == 0).next().unwrap_or(&[]).to_vec();
            parts.push(
                String::from_utf8_lossy(&drive)
                    .trim_end_matches('\\')
                    .to_string(),
            );
        } else if kind == 0x30 && !parts.is_empty() {
            let name = lnk_item_long_name(item);
            let name = if name.is_empty() {
                decode_ansi(item.get(14..).unwrap_or(&[]).split(|b| *b == 0).next().unwrap_or(&[]))
            } else {
                name
            };
            if name.is_empty() {
                return String::new();
            }
            parts.push(name);
        } else {
            return String::new();
        }
    }
    if parts.len() > 1 {
        parts.join("\\")
    } else {
        String::new()
    }
}

#[derive(Default, Debug, Clone)]
pub struct LnkInfo {
    pub target: String,
    pub args: String,
    pub icon: String,
    pub icon_index: i32,
    pub workdir: String,
    pub comment: String,
    pub relative_path: String,
}

const STRINGS: &[(u32, &str)] = &[
    (0x04, "comment"),
    (0x08, "relative_path"),
    (0x10, "workdir"),
    (0x20, "args"),
    (0x40, "icon"),
];

pub fn parse_lnk(path: &Path) -> LnkInfo {
    let Ok(data) = std::fs::read(path) else {
        return LnkInfo::default();
    };
    parse_lnk_bytes(&data)
}

pub fn parse_lnk_bytes(data: &[u8]) -> LnkInfo {
    let mut info = LnkInfo::default();
    if data.len() < 0x4C || &data[..4] != b"L\0\0\0" {
        return info;
    }
    let read_u32 = |offset: usize| -> u32 {
        if offset + 4 <= data.len() {
            u32::from_le_bytes([data[offset], data[offset + 1], data[offset + 2], data[offset + 3]])
        } else {
            0
        }
    };
    let read_u16 = |offset: usize| -> usize {
        if offset + 2 <= data.len() {
            u16::from_le_bytes([data[offset], data[offset + 1]]) as usize
        } else {
            0
        }
    };
    let read_i32 = |offset: usize| -> i32 { read_u32(offset) as i32 };
    let flags = read_u32(0x14);
    let is_unicode = flags & 0x80 != 0;
    let mut offset = 0x4Cusize;
    info.icon_index = read_i32(0x38);
    let mut id_list: &[u8] = &[];
    let mut ansi_target = String::new();
    let mut unicode_target = String::new();

    if flags & 0x01 != 0 {
        if offset + 2 > data.len() {
            return info;
        }
        let id_list_size = read_u16(offset);
        id_list = data
            .get(offset + 2..offset + 2 + id_list_size)
            .unwrap_or(&[]);
        offset += 2 + id_list_size;
    }

    if flags & 0x02 != 0 {
        if offset + 4 > data.len() {
            return info;
        }
        let link_info_size = read_u32(offset) as usize;
        let link_info = data.get(offset..offset + link_info_size).unwrap_or(&[]);
        if link_info.len() >= 0x1C {
            let header_size = read_u32_in(link_info, 4);
            let local_base_offset = read_u32_in(link_info, 16) as usize;
            let suffix_offset = read_u32_in(link_info, 24) as usize;
            let local_base = cstring(link_info, local_base_offset);
            let suffix = cstring(link_info, suffix_offset);
            // latin-1 只保字节，等下面按代码页或 ID 列表再解
            ansi_target = join_lnk_path(&latin1(&local_base), &latin1(&suffix));
            if header_size >= 0x24 && link_info.len() >= 0x24 {
                let base_u_offset = read_u32_in(link_info, 28) as usize;
                let suffix_u_offset = read_u32_in(link_info, 32) as usize;
                let unicode_base = if base_u_offset != 0 && base_u_offset < link_info.len() {
                    read_utf16_cstring(link_info, base_u_offset)
                } else {
                    String::new()
                };
                let unicode_suffix = if suffix_u_offset != 0 && suffix_u_offset < link_info.len() {
                    read_utf16_cstring(link_info, suffix_u_offset)
                } else {
                    String::new()
                };
                unicode_target = join_lnk_path(&unicode_base, &unicode_suffix);
            }
        }
        offset += link_info_size;
    }

    // Wine 写的 LinkInfo 只有 ANSI 代码页，不一定是 locale 的；ID 列表全是 unicode
    let target = if !unicode_target.is_empty() || ansi_target.is_ascii() {
        if unicode_target.is_empty() { ansi_target.clone() } else { unicode_target }
    } else {
        let from_id_list = parse_lnk_id_list(id_list);
        if from_id_list.is_empty() {
            let raw: Vec<u8> = ansi_target.chars().map(|c| c as u8).collect();
            decode_ansi(&raw)
        } else {
            from_id_list
        }
    };
    if !target.is_empty() {
        info.target = target;
    }

    for (flag, key) in STRINGS {
        if flags & flag == 0 {
            continue;
        }
        let value = read_lnk_string(data, &mut offset, is_unicode);
        if value.is_empty() {
            continue;
        }
        match *key {
            "comment" => info.comment = value,
            "relative_path" => info.relative_path = value,
            "workdir" => info.workdir = value,
            "args" => info.args = value,
            "icon" => info.icon = value,
            _ => {}
        }
    }
    info
}

fn read_u32_in(data: &[u8], offset: usize) -> u32 {
    if offset + 4 <= data.len() {
        u32::from_le_bytes([data[offset], data[offset + 1], data[offset + 2], data[offset + 3]])
    } else {
        0
    }
}

fn cstring(data: &[u8], offset: usize) -> Vec<u8> {
    if offset >= data.len() {
        return Vec::new();
    }
    data[offset..].split(|b| *b == 0).next().unwrap_or(&[]).to_vec()
}

fn latin1(bytes: &[u8]) -> String {
    bytes.iter().map(|b| *b as char).collect()
}
