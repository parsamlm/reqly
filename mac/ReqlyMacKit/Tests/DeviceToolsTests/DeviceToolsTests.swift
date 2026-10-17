import Foundation
import Testing

@testable import DeviceTools

@Suite struct DeviceToolsTests {
    @Test func readsTheRunningSimulators() throws {
        let json = """
            {"devices": {
              "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
                {"udid": "540A509F-6929-46AA-8C7B-4F06A17B446B", "name": "iPhone 17 Pro", "state": "Booted", "isAvailable": true},
                {"udid": "11111111-2222-3333-4444-555555555555", "name": "iPhone Air", "state": "Shutdown", "isAvailable": true}
              ],
              "com.apple.CoreSimulator.SimRuntime.watchOS-26-4": []
            }}
            """
        #expect(
            try Simulators.parse(Data(json.utf8)) == [
                Simulator(id: "540A509F-6929-46AA-8C7B-4F06A17B446B", name: "iPhone 17 Pro", runtime: "iOS 26.4")
            ])
        #expect(Simulators.runtimeName("com.apple.CoreSimulator.SimRuntime.visionOS-26-0") == "visionOS 26.0")
    }
}
