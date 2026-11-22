// The small actions views forward: a view asks, and only the store changes the app's state.

import Foundation

extension AppStore {
    /// Ask before deleting a paper.
    func requestDelete(_ p: Paper) { pendingConfirmation = .delete(p) }
    /// Ask before deleting a paper's audio.
    func requestDeleteAudio(_ p: Paper) { pendingConfirmation = .deleteAudio(p) }
    /// The confirmation was dismissed: nothing happens.
    func cancelConfirmation() { pendingConfirmation = nil }
    /// Close the update alert.
    func dismissUpdateAlert() { updateAlert = nil }
    /// Open the Edit paper sheet.
    func beginEditing(_ p: Paper) { editingPaper = p }
    /// Open the New Library sheet.
    func beginNewLibrary() { editingLibrary = LibraryForm() }
    /// Open the Edit Library sheet.
    func beginEditingLibrary(_ library: Library) { editingLibrary = LibraryForm(library) }
    /// Show one status only.
    func setStatusFilter(_ value: String) { statusFilter = value }
    /// Empty the search field.
    func clearSearch() { search = "" }
    /// Close the import sheet.
    func closeImport() { showUpload = false }
    /// Show a page of the Settings sheet.
    func showSettingsPage(_ page: SettingsPage) { settingsPage = page }
    /// No suggestion is picked (the tab changed).
    func clearSuggestionSelection() { selectedSuggestionId = nil }

    /// The mail page's form as saved, without the last test's result.
    func openMailForm() -> MailSettingsForm {
        mailTestResult = nil
        return MailSettingsForm(mail, password: mailPassword())
    }
}
