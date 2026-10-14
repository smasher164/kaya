//! An image's natural size read from its header alone (docs/network-images-plan.md
//! N9's 2026-10-13 amendment): a backend that decodes off the UI thread lays
//! the image out at this size before the pixels arrive.

/// JPEG's frame header, PNG's IHDR and GIF's screen descriptor, in pixels.
/// None for anything else.
pub(crate) fn natural(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") && bytes.len() >= 24 {
        let w = u32::from_be_bytes(bytes[16..20].try_into().ok()?);
        let h = u32::from_be_bytes(bytes[20..24].try_into().ok()?);
        return (w > 0 && h > 0).then_some((w, h));
    }
    if bytes.starts_with(b"GIF8") && bytes.len() >= 10 {
        let w = u32::from(u16::from_le_bytes([bytes[6], bytes[7]]));
        let h = u32::from(u16::from_le_bytes([bytes[8], bytes[9]]));
        return (w > 0 && h > 0).then_some((w, h));
    }
    if !bytes.starts_with(&[0xFF, 0xD8]) {
        return None;
    }
    let mut at = 2;
    while at + 9 < bytes.len() {
        if bytes[at] != 0xFF {
            return None;
        }
        let marker = bytes[at + 1];
        if marker == 0xFF {
            at += 1;
            continue;
        }
        let len = usize::from(u16::from_be_bytes([bytes[at + 2], bytes[at + 3]]));
        if matches!(marker, 0xC0..=0xCF) && !matches!(marker, 0xC4 | 0xC8 | 0xCC) {
            let h = u32::from(u16::from_be_bytes([bytes[at + 5], bytes[at + 6]]));
            let w = u32::from(u16::from_be_bytes([bytes[at + 7], bytes[at + 8]]));
            return (w > 0 && h > 0).then_some((w, h));
        }
        at += 2 + len;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::natural;

    #[test]
    fn a_header_names_its_natural_size() {
        let jpeg = [
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x02, 0x58, 0x03, 0x20, 0x03,
        ];
        assert_eq!(natural(&jpeg), Some((800, 600)));
        assert_eq!(natural(b"not a picture"), None);
        let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        png.extend(320u32.to_be_bytes());
        png.extend(200u32.to_be_bytes());
        assert_eq!(natural(&png), Some((320, 200)));
        assert_eq!(natural(b"GIF89a\x40\x01\xc8\x00"), Some((320, 200)));
    }
}
