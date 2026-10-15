#if os(Linux)
import Foundation
import SwiftCrossUI

/// The bottom bar: player and import progress (filled in by the next step).
struct PlayerBar: View {
    @State var bridge: StoreBridge

    var body: some View {
        if let toast = bridge.store.toast {
            Text(toast).padding(8)
        }
    }
}
#endif
