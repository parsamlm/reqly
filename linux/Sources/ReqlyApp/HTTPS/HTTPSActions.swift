extension MainWindow {
    /// Set Up HTTPS…: says what Reqly will do, with each place it found, then makes Reqly's
    /// certificate, adds it to the places you choose, and shows how each went.
    func setUpHTTPS() {
        guard model.session != nil else {
            toast("Reqly can set up HTTPS once its session is open.")
            return
        }
        guard model.https.isAvailable else {
            toast(HTTPSModel.unavailableReason)
            return
        }
        showSetUp()
    }
}
