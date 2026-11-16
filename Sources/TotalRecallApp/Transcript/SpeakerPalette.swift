import AppKit
import AppSupport

/// The colors speakers are told apart by in a transcript: blues for your microphone, you and anyone sharing it; anything
/// but blue for everyone else. Chosen to be told apart with a red-blue color deficiency, where shades of one hue blur:
/// the colors differ in lightness as much as in hue, the blues most of all, and the first ten of the others, enough for
/// most calls, are the most distinct; the next ten are lighter or darker relatives of theirs. Each has a darker version
/// for light mode and a lighter one for dark mode, so names stay readable on either.
enum SpeakerPalette {
    /// Light mode, dark mode, as RGB hex.
    private static let yours: [(UInt32, UInt32)] = [
        (0x0A60D8, 0x4AA3FF),  // blue
        (0x007EA7, 0x5AD2FA),  // sky
        (0x4A3AC6, 0x9D8CFF),  // indigo
        (0x123A7A, 0xB4CEFF),  // navy, pale in dark mode
    ]

    private static let theirs: [(UInt32, UInt32)] = [
        (0xC96A00, 0xFFA94D),  // orange
        (0x1E8A3C, 0x5ED07F),  // green
        (0xB3348B, 0xF27DCB),  // magenta
        (0x8C7A00, 0xF0D94A),  // yellow
        (0x8B5A2B, 0xD9A06A),  // brown
        (0xCC2F27, 0xFF6F61),  // red
        (0x00806F, 0x4FD1BE),  // teal green
        (0x7A3DB8, 0xC69CFF),  // purple
        (0x666666, 0xB3B3B3),  // gray
        (0xC2557E, 0xFF9EC4),  // pink
        (0x5F8A00, 0xB5E35A),  // lime
        (0xA67100, 0xFFCF5A),  // gold
        (0x8A1F45, 0xE4849F),  // maroon
        (0x6B6A2A, 0xCFC983),  // olive
        (0xD4573A, 0xFF9C82),  // coral
        (0x2C6A3A, 0x93D3A0),  // forest
        (0x8B3F87, 0xDDA2D8),  // plum
        (0x94744A, 0xE6C796),  // tan
        (0x7A6E64, 0xC9BCB1),  // warm gray
        (0xB24A5E, 0xF4A3B1),  // rose
    ]

    private static let colors: [TranscriptLine.Side: [NSColor]] = [
        .you: yours.map(dynamic),
        .them: theirs.map(dynamic),
        .unknown: [.secondaryLabelColor],
    ]

    /// The color of `side`'s speaker `number`, as `SpeakerColors` numbers them; past the last, they start over.
    static func color(_ side: TranscriptLine.Side, _ number: Int) -> NSColor {
        let colors = colors[side] ?? [.secondaryLabelColor]
        return colors[number % colors.count]
    }

    private static func dynamic(_ pair: (light: UInt32, dark: UInt32)) -> NSColor {
        NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? pair.dark : pair.light)
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
            green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
