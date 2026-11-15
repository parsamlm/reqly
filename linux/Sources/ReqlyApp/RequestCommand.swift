import ReqlyModel

/// What the Mac's Request menu does to a request, which a row's menu, the details' menu and the
/// window's shortcuts offer: the copies, Export as HAR… (the row's menu only), Resend, Edit and
/// Resend…, and Add Rule ▸ with each kind but Slow Network.
enum RequestCommand: Hashable, Sendable {
    case copyURL, copyCurl, copyResponseBody, exportHAR, resend, editAndResend
    case addRule(RuleKind)

    /// The kinds Add Rule offers, in the Mac's order.
    static let ruleKinds: [RuleKind] = [.breakpoint, .mapLocal, .mapRemote, .rewrite, .block, .script]

    /// The commands of a row's menu, in its order: the copies and Export as HAR…, then Resend and
    /// Edit and Resend…, then Add Rule ▸'s kinds.
    static let rowCommands: [RequestCommand] =
        [.copyURL, .copyCurl, .copyResponseBody, .exportHAR, .resend, .editAndResend] + ruleKinds.map(addRule)

    /// The details' menu's: the same, without Export as HAR…, which acts on a list.
    static let detailsCommands = rowCommands.filter { $0 != .exportHAR }

    /// The command's action's name, after `row.` or `details.`.
    var actionName: String {
        switch self {
        case .copyURL: "copy-url"
        case .copyCurl: "copy-curl"
        case .copyResponseBody: "copy-response-body"
        case .exportHAR: "export-har"
        case .resend: "resend"
        case .editAndResend: "edit-and-resend"
        case .addRule(let kind): "add-\(kind.actionName)"
        }
    }

    /// The entry's words, as on the Mac.
    var title: String {
        switch self {
        case .copyURL: "Copy URL"
        case .copyCurl: "Copy as cURL"
        case .copyResponseBody: "Copy Response Body"
        case .exportHAR: "Export as HAR…"
        case .resend: "Resend"
        case .editAndResend: "Edit and Resend…"
        case .addRule(let kind): kind.addRuleTitle
        }
    }

    /// Whether it works on `summary`'s request. An encrypted connection has only its URL and a Block
    /// rule, as on the Mac; Copy Response Body needs a response.
    func isAvailable(for summary: ExchangeSummary) -> Bool {
        if summary.kind == .tunnel {
            return self == .copyURL || self == .addRule(.block)
        }
        switch self {
        case .copyResponseBody: return summary.status != nil
        case .addRule(.slowNetwork): return false
        default: return true
        }
    }
}

extension RuleKind {
    /// The kind's entry in Add Rule ▸.
    var addRuleTitle: String {
        switch self {
        case .breakpoint: "Breakpoint…"
        case .mapLocal: "Map Local…"
        case .mapRemote: "Map Remote…"
        case .rewrite: "Rewrite…"
        case .block: "Block…"
        case .script: "Script…"
        case .slowNetwork: "Slow Network…"
        }
    }

    /// The kind's name, as the Rules menu and the Rules window have it.
    var title: String {
        switch self {
        case .breakpoint: "Breakpoints"
        case .mapLocal: "Map Local"
        case .mapRemote: "Map Remote"
        case .rewrite: "Rewrite"
        case .block: "Block"
        case .script: "Scripts"
        case .slowNetwork: "Slow Network"
        }
    }
}
