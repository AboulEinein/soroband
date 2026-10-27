//! Text for the terminal.

/// `name` with control characters replaced, so a process or network name cannot drive the
/// terminal.
pub fn printable(name: &str) -> String {
    name.chars()
        .map(|c| if c.is_control() { '\u{FFFD}' } else { c })
        .collect()
}

pub fn size(bytes: u64) -> String {
    #[allow(clippy::cast_precision_loss)]
    let b = bytes as f64;
    match bytes {
        0..1_000 => format!("{bytes} B"),
        1_000..1_000_000 => format!("{:.1} KB", b / 1e3),
        1_000_000..1_000_000_000 => format!("{:.2} MB", b / 1e6),
        _ => format!("{:.2} GB", b / 1e9),
    }
}

#[cfg(test)]
mod tests {
    use super::printable;

    #[test]
    fn table_replaces_control_characters_in_names() {
        assert_eq!(
            printable("evil\u{1b}]0;title\u{7}\u{9b}2J"),
            "evil\u{FFFD}]0;title\u{FFFD}\u{FFFD}2J"
        );
    }
}
