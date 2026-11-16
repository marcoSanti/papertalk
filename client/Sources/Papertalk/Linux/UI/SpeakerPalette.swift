// A stable colour per name (speaker, author), mirroring macOS Color.stable(for:), so an
// avatar or capsule keeps its hue across panes and redraws.

#if os(Linux)
import Foundation
import SwiftCrossUI

/// Maps a name to one of a fixed palette, deterministically, so each speaker or author keeps
/// their colour everywhere the app shows them. macOS gets the same from `Color.stable(for:)`.
enum SpeakerPalette {
    /// Colours that read on both light and dark GTK themes.
    private static let palette: [Color] = [
        .red, .orange, .green, .blue, .purple, .pink, .teal, .indigo, .yellow, .brown,
    ]

    /// A stable colour for `name`, the same every call.
    static func color(for name: String) -> Color {
        var hash = 0
        for scalar in name.unicodeScalars {
            hash = (hash &* 31 &+ Int(scalar.value)) & 0x7fff_ffff
        }
        return palette[hash % palette.count]
    }
}
#endif