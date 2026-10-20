#if os(Linux)
import Foundation
import SwiftCrossUI

/// Who should speak: rename each speaker and pick (and hear) their voice
/// before the script is written (macOS CastSheet). The import waits on it.
struct CastSheet: View {
    var bridge: StoreBridge
    let paperTitle: String
    @State var form: CastForm

    init(bridge: StoreBridge, prompt: AppStore.CastPrompt) {
        self.bridge = bridge
        paperTitle = prompt.paperTitle
        _form = State(wrappedValue: CastForm(proposals: prompt.proposals, authors: prompt.authors,
                                             authorGenders: prompt.authorGenders))
    }

    var body: some View {
        let store = bridge.store
        VStack(alignment: .leading, spacing: 12) {
            Text("Who should speak?").font(.title2)
            Text(paperTitle).foregroundColor(.gray).lineLimit(1)
            ForEach(form.rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.role.uppercased()).font(.caption).foregroundColor(.gray)
                    HStack(spacing: 8) {
                        TextField(form.authorPlaceholder(row) ?? "Name",
                                  text: Binding(get: { row.name }, set: { form.rename(row.id, to: $0) }))
                        Picker(of: PickerOption.genders, selection: Binding(
                            get: { PickerOption.genders.first { $0.value == row.gender } },
                            set: { if let g = $0 { form.setGender(row.id, g.value) } }))
                    }
                    HStack(spacing: 8) {
                        Picker(of: PickerOption.voices, selection: Binding(
                            get: { PickerOption.voices.first { $0.value == row.voice } },
                            set: { if let v = $0 { form.setVoice(row.id, v.value) } }))
                        Button("Hear") { store.player.previewVoice(row.voice) }
                    }
                }
                .padding(.vertical, 4)
            }
            Text(form.note.text).foregroundColor(.gray)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel import") { store.cancelCast() }
                Button(CastForm.scriptOnlyTitle) { store.resolveCast(form.cast, voiceAudio: false) }
                    .disabled(!form.canConfirm)
                Button("Use these voices") { store.resolveCast(form.cast) }
                    .disabled(!form.canConfirm)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
#endif
