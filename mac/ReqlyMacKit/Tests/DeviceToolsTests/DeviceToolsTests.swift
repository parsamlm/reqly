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

    @Test func readsTheAndroidDevices() {
        let output = """
            * daemon not running; starting now at tcp:5037
            * daemon started successfully
            List of devices attached
            emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
            R5CT1234567            unauthorized usb:1-1 transport_id:2

            """
        let devices = AndroidDebugBridge.parseDevices(output)
        #expect(
            devices == [
                AndroidDevice(id: "emulator-5554", state: "device", model: "sdk_gphone64_arm64"),
                AndroidDevice(id: "R5CT1234567", state: "unauthorized"),
            ])
        #expect(devices.map(\.isEmulator) == [true, false])
        #expect(AndroidDebugBridge.proxySetting("10.0.2.2:9090\r\n") == "10.0.2.2:9090")
        #expect(AndroidDebugBridge.proxySetting(":0\n") == nil)
        #expect(AndroidDebugBridge.proxySetting("null\n") == nil)
    }

    @Test func findsAdbWhereTheSDKPutsIt() throws {
        let home = URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(
            AndroidDebugBridge.find(environment: [:], home: home)?.executable.path(percentEncoded: false).hasPrefix(
                home.path(percentEncoded: false)) != true)
        let tools = home.appending(path: "Library/Android/sdk/platform-tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let adb = tools.appending(path: "adb")
        try Data("#!/bin/sh\n".utf8).write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path(percentEncoded: false))
        #expect(AndroidDebugBridge.find(environment: [:], home: home)?.executable == adb)
    }

    @Test func runsATool() async throws {
        let echoed = try await Tool.run(URL(filePath: "/bin/echo"), ["hello"])
        #expect(echoed == "hello\n")
        await #expect(throws: Tool.Failure.self) {
            try await Tool.run(URL(filePath: "/bin/sh"), ["-c", "echo nope >&2; exit 3"])
        }
        // A tool that takes too long is stopped.
        let start = ContinuousClock.now
        await #expect(throws: Tool.Failure.self) {
            try await Tool.run(URL(filePath: "/bin/sleep"), ["10"], timeout: .milliseconds(200))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func writesCertificatesAsPEM() {
        let pem = Data([0x30, 0x82, 0x01, 0x0A]).pemCertificate
        #expect(pem == "-----BEGIN CERTIFICATE-----\nMIIBCg==\n-----END CERTIFICATE-----\n")
    }
}
