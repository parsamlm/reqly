import ReqlyModel

// Opening, saving and exporting sessions, sending, and copying requests: what the main menu, the
// row's and the details' menus and their shortcuts ask of a window. Each does nothing yet, and is
// filled in with the dialogs and the composer it opens.

extension MainWindow {
    /// New Request, with the live window shown: a composer on a new draft.
    func newRequest() {}

    /// Open…: sessions and HAR files, several at once, each in a window of its own, through
    /// ``App/open(_:)``.
    func openFiles() {}

    /// Save Session…: the window's session, to a file you choose.
    func saveSession() {}

    /// Export as HAR…: the window's list, or `selected`, its request chosen, as a row's menu asks.
    func exportHAR(selecting selected: ExchangeID?) {}

    /// Copy URL: the request's URL, as text.
    func copyURL(of summary: ExchangeSummary) {}

    /// Copy as cURL: a curl command that sends the request again.
    func copyCurl(of id: ExchangeID) {}

    /// Copy Response Body: the response's body, as text, an image, or hex.
    func copyResponseBody(of id: ExchangeID) {}

    /// Resend: the request again, through the live session.
    func resend(_ id: ExchangeID) {}

    /// Edit and Resend…: a composer on the request.
    func editAndResend(_ id: ExchangeID) {}
}
