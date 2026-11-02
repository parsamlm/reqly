import Testing

@testable import ReqlyApp

@Suite struct RemovalWordsTests {
    /// Remove Certificate…'s question says what goes: the certificate Reqly decrypts with, and its
    /// key; or, once the key has gone from your keyring, only the old certificate, since Reqly
    /// decrypts with it no more; then Chromium's reminder while its own list trusts it.
    @Test func saysWhatGoes() {
        let reminder = "Chromium keeps the copy you imported in its own settings: delete it there afterwards."
        #expect(
            HTTPSPage.removalQuestion(isStandIn: false, isKeyGone: false, reminder: nil)
                == "Reqly stops decrypting HTTPS, and removes its certificate from your browsers, this computer's list "
                + "and its key. Removing it from the computer's list asks for an administrator's password. You can "
                + "set up HTTPS again at any time.")
        let keyGone = HTTPSPage.removalQuestion(isStandIn: false, isKeyGone: true, reminder: reminder)
        #expect(
            keyGone
                == "Reqly's key isn't in your keyring any more, so Reqly removes its old certificate from your "
                + "browsers and this computer's list. Removing it from the computer's list asks for an "
                + "administrator's password. \(reminder) You can set up HTTPS again at any time.")
        #expect(!keyGone.contains("stops decrypting") && !keyGone.contains("its key."))
        #expect(
            HTTPSPage.removalQuestion(isStandIn: true, isKeyGone: false, reminder: reminder)
                == "Reqly stops decrypting HTTPS, and removes this test run's certificate. Nothing on this computer "
                + "changes. You can set up HTTPS again at any time.")
    }
}
