// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

@MainActor
enum WebCredentialPrompt {
    static func confirmSave(username: String, origin: String, window: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString(
            "passwords.webCredential.savePrompt.title",
            value: "Save this password?",
            comment: "Web password manager - Title asking whether to save a submitted website login"
        )
        alert.informativeText = String(
            format: NSLocalizedString(
                "passwords.webCredential.savePrompt.message",
                value: "Save the password for %@ on %@ in macOS Keychain? Touch ID or your Mac login password will be required to fill it.",
                comment: "Web password manager - Save confirmation; placeholders are the username and website origin"
            ),
            username,
            origin
        )
        alert.addButton(withTitle: NSLocalizedString(
            "passwords.webCredential.savePrompt.saveButton",
            value: "Save Password",
            comment: "Web password manager - Button confirming that a website password should be saved"
        ))
        alert.addButton(withTitle: NSLocalizedString(
            "passwords.webCredential.savePrompt.cancelButton",
            value: "Not Now",
            comment: "Web password manager - Button declining to save a website password"
        ))
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func choose(
        from descriptors: [WebCredentialDescriptor],
        origin: String,
        window: NSWindow?
    ) -> WebCredentialDescriptor? {
        guard descriptors.count > 1 else { return descriptors.first }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString(
            "passwords.webCredential.choosePrompt.title",
            value: "Choose a saved login",
            comment: "Web password manager - Title shown when several saved accounts match a website"
        )
        alert.informativeText = String(
            format: NSLocalizedString(
                "passwords.webCredential.choosePrompt.message",
                value: "Choose the account to fill on %@. Touch ID or your Mac login password will be required.",
                comment: "Web password manager - Account chooser explanation; placeholder is the website origin"
            ),
            origin
        )
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        popup.addItems(withTitles: descriptors.map(\.username))
        alert.accessoryView = popup
        alert.addButton(withTitle: NSLocalizedString(
            "passwords.webCredential.choosePrompt.continueButton",
            value: "Continue",
            comment: "Web password manager - Button continuing from saved-account selection to Touch ID"
        ))
        alert.addButton(withTitle: NSLocalizedString(
            "passwords.webCredential.choosePrompt.cancelButton",
            value: "Cancel",
            comment: "Web password manager - Button cancelling saved-account selection"
        ))
        guard alert.runModal() == .alertFirstButtonReturn,
              descriptors.indices.contains(popup.indexOfSelectedItem) else {
            return nil
        }
        return descriptors[popup.indexOfSelectedItem]
    }

    static func showError(_ error: Error, window: NSWindow?) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
