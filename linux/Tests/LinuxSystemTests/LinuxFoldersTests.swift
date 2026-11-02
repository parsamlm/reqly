import Foundation
import LinuxSystem
import Testing

@Suite struct LinuxFoldersTests {
    @Test func followsTheXDGFolders() {
        let set = LinuxFolders(environment: [
            "HOME": "/home/ana", "XDG_CONFIG_HOME": "/c", "XDG_STATE_HOME": "/s", "XDG_DATA_HOME": "/d",
        ])
        #expect(set.config.path == "/c/reqly")
        #expect(set.state.path == "/s/reqly")
        #expect(set.data.path == "/d/reqly")
        #expect(set.proxyRestoreFile.path == "/s/reqly/ProxyRestore.json")
        #expect(set.rootFile.path == "/d/reqly/Certificate.dat")
        #expect(set.secretsFile.path == "/d/reqly/Secrets.json")
        // Relative and empty paths don't count.
        let unset = LinuxFolders(environment: ["HOME": "/home/ana", "XDG_STATE_HOME": "state", "XDG_CONFIG_HOME": ""])
        #expect(unset.config.path == "/home/ana/.config/reqly")
        #expect(unset.state.path == "/home/ana/.local/state/reqly")
        #expect(unset.data.path == "/home/ana/.local/share/reqly")
    }
}
