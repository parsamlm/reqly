extension MainWindow {
    /// Set Up HTTPS…: says what Reqly will do, with each place it found, then makes Reqly's
    /// certificate, adds it to the places you choose, and shows how each went.
    func setUpHTTPS() {
        // It's open already, over the window.
        guard SetUpDialog.showing == nil else { return }
        guard model.session != nil else {
            toast("Reqly can set up HTTPS once its session is open.")
            return
        }
        SetUpDialog(https: model.https).present(over: window)
    }
}
