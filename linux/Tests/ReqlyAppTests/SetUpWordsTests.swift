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

    /// With its key gone from your keyring, as after you reset it, or its file gone, the key isn't
    /// kept: the key's row says the keyring will ask, as at a first setup, and so does the first
    /// line, not the administrator's password, which comes once the new key is kept.
    @Test func asksForANewKeyringWhenTheKeyIsGone() {
        let password = "Setting up HTTPS. Linux asks for an administrator's password…"
        for place in [KeyPlace.keyring, .file] {
            #expect(HTTPSModel.KeyStatus(place: place, isMissing: true, couldRead: true) == .new)
            #expect(HTTPSModel.KeyStatus(place: place, isMissing: true, couldRead: false) == .new)
        }
        #expect(HTTPSModel.KeyStatus(place: nil, isMissing: false, couldRead: true) == .new)
        #expect(HTTPSModel.KeyStatus.new.asksTheKeyring)
        #expect(
            SetUpDialog.keyText(key: .new, kept: "Not in your keyring any more", keyring: .needsNewKeyring)
                == "Linux will ask you to choose a password for a new keyring, which keeps Reqly's key. If you close "
                + "it, Reqly keeps the key in a file only you can read.")
        #expect(
            SetUpDialog.startText(keyring: .needsNewKeyring, key: .new, trustsComputer: true)
                == "Setting up HTTPS. Linux asks you to choose a password for a new keyring…")
        #expect(
            SetUpDialog.startText(keyring: .locked, key: .new, trustsComputer: false)
                == "Setting up HTTPS. Linux asks for your keyring's password…")
        #expect(SetUpDialog.startText(keyring: nil, key: .new, trustsComputer: true) == password)
    }

    /// A key kept where the record says, and read, asks nothing: the row says where it is, and the
    /// first line names the administrator's password, whatever the keyring's state.
    @Test func asksNothingForAKeyThatsKept() {
        let password = "Setting up HTTPS. Linux asks for an administrator's password…"
        #expect(HTTPSModel.KeyStatus(place: .keyring, isMissing: false, couldRead: true) == .kept)
        // A file Reqly couldn't read asks nothing either: setting up only fails the same way.
        #expect(HTTPSModel.KeyStatus(place: .file, isMissing: false, couldRead: false) == .kept)
        #expect(!HTTPSModel.KeyStatus.kept.asksTheKeyring)
        #expect(
            SetUpDialog.keyText(key: .kept, kept: "In your keyring", keyring: .needsNewKeyring) == "In your keyring")
        #expect(SetUpDialog.startText(keyring: .needsNewKeyring, key: .kept, trustsComputer: true) == password)
        #expect(SetUpDialog.startText(keyring: .locked, key: .kept, trustsComputer: false) == "Setting up HTTPS…")
    }

    /// A key your keyring has, locked, after you closed the question that unlocks it as Reqly
    /// opened: setting up reads it, which asks for your keyring's password, so the row and the
    /// first line say so, not the administrator's password. Unlocked since, it asks nothing.
    @Test func asksForTheKeyringsPasswordWhenTheKeyIsLocked() {
        let password = "Setting up HTTPS. Linux asks for an administrator's password…"
        let status = HTTPSModel.KeyStatus(place: .keyring, isMissing: false, couldRead: false)
        #expect(status == .unread && status.asksTheKeyring)
        #expect(
            SetUpDialog.keyText(key: .unread, kept: "In your keyring", keyring: .locked)
                == "In your keyring. Linux will ask for your keyring's password, to read Reqly's key.")
        #expect(
            SetUpDialog.startText(keyring: .locked, key: .unread, trustsComputer: true)
                == "Setting up HTTPS. Linux asks for your keyring's password…")
        #expect(SetUpDialog.keyText(key: .unread, kept: "In your keyring", keyring: .ready) == "In your keyring")
        #expect(SetUpDialog.startText(keyring: .ready, key: .unread, trustsComputer: true) == password)
    }
}
