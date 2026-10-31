import Foundation
import LinuxSystem
import Testing

@Suite struct LinuxFoldersTests {
    @Test func followsTheXDGFolders() {
        let set = LinuxFolders(environment: ["HOME": "/home/ana", "XDG_STATE_HOME": "/s", "XDG_DATA_HOME": "/d"])
        #expect(set.state.path == "/s/reqly")
        #expect(set.data.path == "/d/reqly")
        #expect(set.proxyRestoreFile.path == "/s/reqly/ProxyRestore.json")
        #expect(set.rootFile.path == "/d/reqly/Certificate.dat")
        #expect(set.secretsFile.path == "/d/reqly/Secrets.json")
        // Relative paths don't count.
        let unset = LinuxFolders(environment: ["HOME": "/home/ana", "XDG_STATE_HOME": "state"])
        #expect(unset.state.path == "/home/ana/.local/state/reqly")
        #expect(unset.data.path == "/home/ana/.local/share/reqly")
    }
}
