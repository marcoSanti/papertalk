import Foundation
import ImageFormats

/// Cover PNG bytes (from the Python pdf service) → an image SwiftCrossUI can show.
enum Covers {
    static func image(_ png: Data) -> ImageFormats.Image<RGBA>? {
        try? ImageFormats.Image<RGBA>.load(from: Array(png), as: .png)
    }
}
