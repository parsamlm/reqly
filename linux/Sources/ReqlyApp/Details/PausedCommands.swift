import ReqlyModel

extension MainWindow {
    /// Show, in a toast or the notification, as a breakpoint holds a request or a response: its
    /// row selected, once it shows, with the details, and their paused editor, over the list when
    /// they don't fit beside it.
    func showPaused(_ id: ExchangeID) {
        list.selectOnceShown(id) { [weak self] selected in
            if selected {
                self?.openDetails()
            }
        }
    }
}
