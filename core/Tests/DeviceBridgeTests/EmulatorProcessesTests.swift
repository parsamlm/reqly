import DeviceBridge
import ReqlyModel
import Testing

@Suite struct EmulatorProcessesTests {
    let pixel = Device(id: "emulator:Pixel_9", kind: .emulator, name: "Pixel 9")
    let anyEmulator = Device(id: "emulator:Android Emulator", kind: .emulator, name: "Android Emulator")

    @Test func findsTheEmulatorOnTheMacAndOnWindows() {
        let programs = [
            "/Users/me/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64",
            #"C:\Users\me\AppData\Local\Android\Sdk\emulator\qemu\windows-x86_64\qemu-system-x86_64.exe"#,
            // Windows doesn't tell names apart by case.
            #"C:\Android\Sdk\emulator\qemu\windows-x86_64\QEMU-System-x86_64.EXE"#,
        ]
        for program in programs {
            let device = EmulatorProcesses.device(
                ofProgram: program, arguments: { [program, "-avd", "Pixel_9", "-no-snapshot"] }, emulators: { [] })
            #expect(device == pixel, "\(program)")
        }
        // Launched as `emulator @Pixel_9`, and when its arguments can't be read.
        let qemu = programs[1]
        let launched = EmulatorProcesses.device(ofProgram: qemu, arguments: { [qemu, "@Pixel_9"] }, emulators: { [] })
        #expect(launched == pixel)
        #expect(EmulatorProcesses.device(ofProgram: qemu, arguments: { nil }, emulators: { [] }) == anyEmulator)
    }

    @Test func creditsTheEmulatorsWiFiToTheOneThatRuns() {
        let qemu = #"C:\Android\Sdk\emulator\qemu\windows-x86_64\qemu-system-x86_64.exe"#
        let running = [qemu, "-avd", "Pixel_9"]
        for netsimd in ["/Users/me/Library/Android/sdk/emulator/netsimd", #"C:\Android\Sdk\emulator\netsimd.exe"#] {
            func device(_ emulators: [[String]]) -> Device? {
                EmulatorProcesses.device(ofProgram: netsimd, arguments: { [netsimd] }, emulators: { emulators })
            }
            #expect(device([running]) == pixel)
            // Two instances of one virtual device are one device.
            #expect(device([running, running + ["-read-only"]]) == pixel)
            // With two emulators, it isn't clear which one the traffic is for.
            #expect(device([running, [qemu, "-avd", "Medium_Phone"]]) == anyEmulator)
            #expect(device([]) == anyEmulator)
        }
    }

    @Test func leavesTheComputersOwnProgramsAlone() {
        for program in [
            "/usr/bin/curl", #"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"#,
            #"C:\Users\me\AppData\Local\Android\Sdk\platform-tools\adb.exe"#,
        ] {
            let device = EmulatorProcesses.device(
                ofProgram: program,
                arguments: {
                    Issue.record("Read the arguments of \(program)")
                    return nil
                },
                emulators: {
                    Issue.record("Looked for emulators for \(program)")
                    return []
                })
            #expect(device == nil)
        }
    }

    @Test func namesVirtualDevicesReadably() {
        #expect(EmulatorProcesses.readableName("Pixel_10_Pro_XL") == "Pixel 10 Pro XL")
        #expect(EmulatorProcesses.virtualDevice(in: ["qemu-system-x86_64", "-avd"]) == nil)
        #expect(EmulatorProcesses.emulator(named: nil) == anyEmulator)
    }
}
