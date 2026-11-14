import ReqlyModel

// The Rules window and the rules made from a request: what Show Rules, Add Rule ▸ and the rule
// kinds' switches ask. Each does nothing yet, and is filled in with the Rules window.

extension MainWindow {
    /// Show Rules, with the live window shown: the Rules window.
    func showRules() {}

    /// Add Rule ▸ `kind`, on `summary`'s request: a new rule of that kind that matches it, in the
    /// live session, with the live window shown, from whichever window's session the request is
    /// in.
    func addRule(_ kind: RuleKind, for summary: ExchangeSummary) {}
}

extension App {
    /// A rule kind was turned on or off from the Rules menu or its shortcut. Turning on a kind
    /// with no rules opens the Rules window on it, but for Slow Network, as on the Mac.
    func ruleKindSwitched(_ kind: RuleKind, isOn: Bool) {}
}
