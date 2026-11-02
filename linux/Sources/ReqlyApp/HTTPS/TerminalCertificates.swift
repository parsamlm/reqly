import LinuxDesktop

/// Reqly's certificate files for a terminal set up for Reqly: `Reqly CA.pem`, which Node adds to
/// its own list, and the computer's list with it added, which the other tools read in place of
/// theirs. Nil until HTTPS is set up and both files are there, and for a test run's stand-in
/// certificate, which has neither.
@MainActor
func terminalCertificates() -> TerminalSetup.Certificates? {
    HTTPSModel.current?.terminalCertificates
}
