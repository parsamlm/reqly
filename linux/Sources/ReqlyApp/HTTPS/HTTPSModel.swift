import CoreInterface

/// HTTPS decryption, as the Mac app's HTTPS model keeps it: Reqly's certificate, and the hosts to
/// decrypt, which your settings keep. The session decrypts only while the certificate is trusted,
/// and only the hosts on the list; everything else passes through untouched.
@MainActor
final class HTTPSModel {
    private unowned let app: AppModel
    /// Whether HTTPS is set up, and the hosts to decrypt, as the session last said.
    private(set) var state: HTTPSState?
    /// Why the session couldn't say.
    private(set) var problem: String?

    init(app: AppModel) {
        self.app = app
    }

    /// Hands the session the hosts you saved, and reads whether HTTPS is set up, as the session
    /// opens.
    func load() async {
        guard let session = app.session else { return }
        do {
            state = try await session.setDecryptedHosts(app.settings.decryptedHosts)
            problem = nil
        } catch {
            problem = error.message
        }
        app.changed()
    }
}
