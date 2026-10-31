import AppSetup
import CoreInterface
import Foundation

/// `reqly --remove-certificate`: removes Reqly's certificate for your account, with no window, for
/// scripts or before uninstalling Reqly: from your browsers, Firefox and the computer's list,
/// which asks for an administrator's password, and its key from your keyring or its file. With
/// `--root-stand-in`, only the stand-in file goes. Says how it went, and returns the exit status.
func removeCertificateFromCommandLine(options: Options) -> Int32 {
    let rootFile = options.rootStandIn ?? AppFolders(options: options).rootFile.path
    let removal = RootRemoval.remove(
        rootFile: rootFile, standIn: options.rootStandIn != nil, system: options.systemParts)
    switch removal {
    case .removed:
        print("Removed Reqly's certificate.")
        return 0
    case .nothing:
        print("There's no certificate to remove.")
        return 0
    case .declined:
        FileHandle.standardError.write(Data("Reqly's certificate stays: you closed the password dialog.\n".utf8))
        return 1
    case .failed:
        FileHandle.standardError.write(Data("Reqly couldn't remove its certificate.\n".utf8))
        return 1
    }
}
