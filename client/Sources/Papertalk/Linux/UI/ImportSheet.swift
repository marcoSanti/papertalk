// The Linux import sheet (New episode), over the shared `ImportForm`.

#if os(Linux)
import Foundation
import SwiftCrossUI

/// New episode: pick a PDF and a depth, then start the import (macOS UploadSheet).
struct ImportSheet: View {
    var bridge: StoreBridge
    @State var form = ImportForm()
    @Environment(\.chooseFile) var chooseFile

    var body: some View {
        let store = bridge.store
        let depth = Binding<PickerOption<Depth>?>(
            get: { PickerOption.depths.first { $0.value == form.depth } },
            set: { if let option = $0 { form.depth = option.value } })
        VStack(alignment: .leading, spacing: 12) {
            Text(ImportForm.heading).font(.title2)
            Text(ImportForm.subheading).foregroundColor(.gray)
            HStack(spacing: 8) {
                Button(form.chooseButtonTitle) {
                    Task {
                        if let url = await chooseFile(title: L("Choose a PDF")) { load(url) }
                    }
                }
                Text(form.fileLabel)
                Text(form.fileSizeLabel ?? "").foregroundColor(.gray)
            }
            HStack(spacing: 8) {
                Text(L("Depth"))
                Picker(of: PickerOption.depths, selection: depth)
            }
            if form.depth == .custom {
                TextField(L("Describe the depth you want…"), text: $form.depthNote)
            }
            if form.showsLengthSlider {
                HStack(spacing: 8) {
                    Text(L("Length"))
                    Slider(value: $form.summaryMinutes, in: ImportForm.lengthRange)
                    Text(form.lengthLabel)
                }
            }
            if form.showsLanguageToggle {
                Toggle(ImportForm.languageToggleTitle, isOn: $form.writeInAppLanguage)
                Text(ImportForm.languageToggleHelp).font(.caption).foregroundColor(.gray)
            }
            if form.showsNoLLMWarning(llmBaseURL: store.llm.baseUrl) {
                Text(ImportForm.noLLMWarning).foregroundColor(.orange)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel")) { store.showUpload = false }
                Button(L("Start episode")) {
                    if let s = form.submission {
                        store.upload(s.data, filename: s.filename, depth: s.depth, depthNote: s.depthNote,
                                     targetMinutes: s.targetMinutes, scriptLanguage: s.scriptLanguage)
                        store.showUpload = false
                    }
                }
                .disabled(!form.canStart)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            // A PDF given on the command line (or "Open with") arrives pre-chosen.
            if let url = store.pendingUploadURL {
                store.pendingUploadURL = nil
                load(url)
            }
        }
    }

    /// Read the chosen PDF into the form (a toast if it can't be read).
    private func load(_ url: URL) {
        do { form.setFile(name: url.lastPathComponent, data: try PDFFile.read(url)) }
        catch { bridge.store.show(error.localizedDescription) }
    }
}
#endif
