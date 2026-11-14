import Foundation
import ReqlyModel
import Testing

@testable import ReqlyApp

@Suite struct FrameWordsTests {
    /// The Rules button says which kinds are on, in the menu's order, as its icon shows one is.
    @Test func namesTheRulesButtonByTheKindsOn() {
        #expect(RulesMenu.name(kindsOn: []) == "Rules")
        #expect(RulesMenu.name(kindsOn: [.breakpoint]) == "Rules, Breakpoints on")
        #expect(RulesMenu.name(kindsOn: [.slowNetwork, .breakpoint]) == "Rules, Breakpoints and Slow Network on")
        #expect(
            RulesMenu.name(kindsOn: [.script, .mapLocal, .slowNetwork])
                == "Rules, Map Local, Scripts and Slow Network on")
    }

    /// An encrypted connection has only Copy URL and a Block rule, as on the Mac; Copy Response
    /// Body needs a response; Slow Network isn't a rule Add Rule makes.
    @Test func offersTheRequestMenusCommandsAsTheMacDoes() {
        let readable = RowTextTests.summary()
        #expect(RequestCommand.rowCommands.allSatisfy { $0.isAvailable(for: readable) })
        let waiting = RowTextTests.summary(status: nil, state: .waiting)
        #expect(!RequestCommand.copyResponseBody.isAvailable(for: waiting))
        #expect(RequestCommand.resend.isAvailable(for: waiting) && RequestCommand.copyCurl.isAvailable(for: waiting))
        let tunnel = RowTextTests.summary(kind: .tunnel, scheme: "https", status: nil)
        #expect(RequestCommand.rowCommands.filter { $0.isAvailable(for: tunnel) } == [.copyURL, .addRule(.block)])
        #expect(!RequestCommand.addRule(.slowNetwork).isAvailable(for: readable))
        #expect(!RequestCommand.ruleKinds.contains(.slowNetwork))
        #expect(!RequestCommand.detailsCommands.contains(.exportHAR))
        #expect(
            RequestCommand.rowCommands.map(\.title).prefix(6) == [
                "Copy URL", "Copy as cURL", "Copy Response Body", "Export as HAR…", "Resend", "Edit and Resend…",
            ])
        let names = RequestCommand.rowCommands.map(\.actionName)
        #expect(Set(names).count == names.count)
        #expect(names.contains("add-breakpoints") && names.contains("add-scripts"))
    }

    /// Keyboard Shortcuts lists every key once, the plan's among them, each with a name.
    @Test func listsEachShortcutOnce() {
        let items = ShortcutList.sections.flatMap(\.items)
        let keys = items.flatMap { $0.keys.split(separator: " ").map(String.init) }
        #expect(Set(keys).count == keys.count)
        #expect(items.allSatisfy { !$0.title.isEmpty })
        for planned in [
            "<Control>n", "<Control>o", "<Control>s", "<Shift><Control>e", "<Control>w", "<Shift><Control>c",
            "<Control><Alt>c", "<Shift><Control>b", "<Shift><Control>t", "<Control><Alt>Return", "<Control><Alt>r",
            "<Shift><Control>d", "<Control>question", "<Control>q", "<Control>comma",
        ] {
            #expect(keys.contains(planned), "Keyboard Shortcuts has no \(planned)")
        }
        #expect(RuleKind.allCases.compactMap(\.accelerator) == ["<Shift><Control>b", "<Shift><Control>t"])
        let pages = ShortcutList.pages(lines: 15)
        #expect(pages.flatMap { $0 } == ShortcutList.sections)
        #expect(
            pages.map { $0.map(\.title) } == [["General", "Sessions", "Traffic"], ["Requests", "Rules and Devices"]])
    }
}
