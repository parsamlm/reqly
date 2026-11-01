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

    /// With its key gone from your keyring, as after you reset it, the key isn't kept: the key's
    /// row says the keyring will ask, as at a first setup, and so does the first line, not the
    /// administrator's password, which comes once the new key is kept.
    @Test func asksForANewKeyringWhenTheKeyIsGone() {
        let password = "Setting up HTTPS. Linux asks for an administrator's password…"
        #expect(
            SetUpDialog.keyText(kept: nil, keyring: .needsNewKeyring)
                == "Linux will ask you to choose a password for a new keyring, which keeps Reqly's key. If you close "
                + "it, Reqly keeps the key in a file only you can read.")
        #expect(SetUpDialog.keyText(kept: "In your keyring", keyring: .needsNewKeyring) == "In your keyring")
        #expect(
            SetUpDialog.startText(keyring: .needsNewKeyring, keyIsKept: false, trustsComputer: true)
                == "Setting up HTTPS. Linux asks you to choose a password for a new keyring…")
        #expect(
            SetUpDialog.startText(keyring: .locked, keyIsKept: false, trustsComputer: false)
                == "Setting up HTTPS. Linux asks for your keyring's password…")
        #expect(SetUpDialog.startText(keyring: .needsNewKeyring, keyIsKept: true, trustsComputer: true) == password)
        #expect(SetUpDialog.startText(keyring: nil, keyIsKept: false, trustsComputer: true) == password)
    }
}
