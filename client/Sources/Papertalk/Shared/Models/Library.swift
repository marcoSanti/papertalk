// A library: a user-made folder of papers, with its own icon, saved in `libraries.json`.
// A paper is in at most one library (`Paper.library`), and mind maps connect within it.

import Foundation

/// A folder of papers the user named and gave an icon.
struct Library: Identifiable, Codable, Equatable, Hashable {
    /// A UUID, stored on its papers as `Paper.library`.
    var id: String
    var name: String
    /// An SF Symbol name (see `LibraryForm.icons`).
    var icon: String
    /// Its papers' mind maps also connect to papers outside it.
    var connectsAcross: Bool

    /// Whether two papers' mind maps may be connected: same library (or both in none), unless
    /// either one's library connects across. Ids of deleted libraries count as none.
    static func linkable(_ a: Paper, _ b: Paper, in libraries: [Library]) -> Bool {
        let known = Dictionary(uniqueKeysWithValues: libraries.map { ($0.id, $0) })
        let la = a.library.flatMap { known[$0] }, lb = b.library.flatMap { known[$0] }
        return la?.id == lb?.id || la?.connectsAcross == true || lb?.connectsAcross == true
    }
}
