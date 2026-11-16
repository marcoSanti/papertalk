// The Linux Edit metadata sheet: one field per value, save writes the paper's metadata.

#if os(Linux)
import Foundation
import SwiftCrossUI

/// The Edit paper sheet: title, filename, DOI and the authors/affiliations lists, with a
/// Save button that writes them through the shared store (macOS Sheets.EditMetaSheet).
struct EditMetaSheet: View {
    var bridge: StoreBridge
    let paper: Paper
    /// The form starts from the paper's current values.
    @State var form: MetadataForm

    init(bridge: StoreBridge, paper: Paper) {
        self.bridge = bridge
        self.paper = paper
        _form = State(wrappedValue: MetadataForm(paper))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CoverView(bridge: bridge, paperId: paper.id, width: 36, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Edit paper")).font(.title3).fontWeight(.semibold)
                    Text(paper.filename ?? paper.displayTitle)
                        .font(.caption).foregroundColor(.gray)
                }
                Spacer()
            }

            Text(L("Title")).font(.headline)
            TextField(L("Title"), text: $form.title)
            Text(L("Filename")).font(.headline)
            TextField(L("Shown in the library list"), text: $form.filename)
            Text(L("DOI")).font(.headline)
            TextField("10.xxxx/xxxxx", text: $form.doi)

            // GTK has single-line text fields, so the lists round-trip as their newline-joined
            // text (the store splits them on save), as the shared MetadataForm describes.
            Text(L("Authors")).font(.headline)
            TextField(L("One per line"), text: $form.authors)
            Text(L("Affiliations")).font(.headline)
            TextField(L("One per line"), text: $form.affiliations)

            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel")) { bridge.store.closeEditing() }
                Button(L("Save")) { save() }
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    /// Save the edited metadata and close the sheet.
    private func save() {
        bridge.store.saveMetadata(paper.id, form)
        bridge.store.closeEditing()
    }
}
#endif