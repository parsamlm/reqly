import LinuxTrust
import Testing

@testable import ReqlyApp

@Suite struct SetUpWordsTests {
    /// Set Up's progress line names the question Linux asks at each step: the keyring's while the
    /// key is kept, then the administrator's password for the computer's list.
    @Test func namesTheQuestionOfEachStep() {
        let password = "Setting up HTTPS. Linux asks for an administrator's password…"
        #expect(
            SetUpDialog.progressText(keyring: .needsNewKeyring, keyKept: false, trustsComputer: true)
                == "Setting up HTTPS. Linux asks you to choose a password for a new keyring…")
        #expect(
            SetUpDialog.progressText(keyring: .locked, keyKept: false, trustsComputer: true)
                == "Setting up HTTPS. Linux asks for your keyring's password…")
        #expect(SetUpDialog.progressText(keyring: .needsNewKeyring, keyKept: true, trustsComputer: true) == password)
        #expect(SetUpDialog.progressText(keyring: .ready, keyKept: false, trustsComputer: true) == password)
        #expect(SetUpDialog.progressText(keyring: nil, keyKept: false, trustsComputer: false) == "Setting up HTTPS…")
        #expect(SetUpDialog.progressText(keyring: .locked, keyKept: true, trustsComputer: false) == "Setting up HTTPS…")
    }
}
