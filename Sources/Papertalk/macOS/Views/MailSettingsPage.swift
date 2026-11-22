// Settings → Suggested Papers on macOS: the daily check and import depth, then the mail account Google Scholar alerts are read from,
// with the steps to set alerts and an app password up, and Test Connection.

#if os(macOS)
import SwiftUI

/// Lays out `MailSettingsForm`; saves like the other pages (on Save and when left).
struct MailSettingsPage: View {
    @EnvironmentObject private var store: AppStore
    @State private var form = MailSettingsForm(MailSettings(), password: "")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(SuggestionsPresentation.windowTitle).font(.title3).fontWeight(.semibold)
                // Bound to the store, which saves them as they change, like the Suggested section did.
                Toggle(SuggestionsPresentation.enableToggle, isOn: $store.suggestionsEnabled)
                    .toggleStyle(.switch)
                Text(SuggestionsPresentation.enableHelp)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CaptionedField(label: SuggestionsPresentation.importDepthLabel) {
                    Picker(SuggestionsPresentation.importDepthLabel, selection: $store.suggestionDepth) {
                        ForEach(SuggestionsPresentation.importDepths(current: store.suggestionDepth)) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text(SuggestionsPresentation.importDepthHelp)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().padding(.vertical, 4)

                Text(MailSettingsForm.title).font(.title3).fontWeight(.semibold)
                Toggle(MailSettingsForm.enableToggle, isOn: $form.enabled)
                    .toggleStyle(.switch)
                Text(MailSettingsForm.intro)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(MailSettingsForm.steps.enumerated()), id: \.offset) { i, step in
                        Label(step, systemImage: "\(i + 1).circle.fill")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .glassCard()

                HStack(alignment: .top, spacing: 10) {
                    CaptionedField(label: MailSettingsForm.serverLabel) {
                        TextField("imap.gmail.com", text: $form.host).textFieldStyle(.roundedBorder)
                    }
                    CaptionedField(label: MailSettingsForm.portLabel) {
                        TextField("993", text: $form.port).textFieldStyle(.roundedBorder).frame(width: 80)
                        if let problem = form.portProblem {
                            Text(problem).font(.caption2).foregroundStyle(.red)
                        }
                    }
                }
                CaptionedField(label: MailSettingsForm.accountLabel) {
                    TextField("me@gmail.com", text: $form.account).textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                }
                CaptionedField(label: MailSettingsForm.passwordLabel) {
                    SecureField("xxxx xxxx xxxx xxxx", text: $form.password).textFieldStyle(.roundedBorder)
                    Text(MailSettingsForm.passwordHelp).font(.caption2).foregroundStyle(.secondary)
                }
                CaptionedField(label: MailSettingsForm.mailboxLabel) {
                    TextField("INBOX", text: $form.mailbox).textFieldStyle(.roundedBorder)
                }
                CaptionedField(label: MailSettingsForm.lookBackLabel) {
                    Picker(MailSettingsForm.lookBackLabel, selection: $form.lookBackDays) {
                        ForEach(MailSettingsForm.lookBackOptions, id: \.days) { Text($0.label).tag($0.days) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text(MailSettingsForm.lookBackHelp)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button(MailSettingsForm.testButton(testing: store.isTestingMail)) {
                        Task { await store.testMailConnection(form) }
                    }
                    .disabled(!form.canTest || store.isTestingMail)
                    if store.isTestingMail { ProgressView().controlSize(.small) }
                    if let result = store.mailTestResult {
                        Text(result).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .onAppear {
            form = store.openMailForm()
        }
        .onDisappear { store.saveMailSettings(form) }
        .onReceive(NotificationCenter.default.publisher(for: .papertalkSaveSettings)) { _ in
            store.saveMailSettings(form)
        }
    }

}
#endif
