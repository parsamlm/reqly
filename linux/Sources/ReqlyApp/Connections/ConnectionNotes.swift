extension AppModel {
    /// The connections' status notes: " · Via proxy.example.com:8080" while the upstream proxy is
    /// on, and " · 1 reverse proxy" while reverse proxies listen. None yet: they're filled in with
    /// Settings › Connections.
    var connectionsNotes: [StatusNote] { [] }
}
