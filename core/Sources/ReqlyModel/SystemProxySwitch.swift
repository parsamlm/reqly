/// Points the computer's proxy at Reqly while it captures, and puts it back afterwards. On the
/// Mac, the SystemProxy module does it through Reqly's helper; tests use a stand-in.
public protocol SystemProxySwitch: Sendable {
    func enable(port: Int) async throws
    func disable() async throws
}
