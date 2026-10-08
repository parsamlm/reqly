import ReqlyModel
import SwiftUI

/// Slow network: the speed and delay to slow traffic down to, and the hosts it applies to.
struct SlowNetworkPane: View {
    @Environment(RulesModel.self) private var rules
    @State private var newHost = ""

    private static let custom = "Custom"

    var body: some View {
        Form {
            if let problem = rules.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Section {
                KindSwitch(kind: .slowNetwork)
            }
            Section {
                Picker("Profile", selection: profileName) {
                    ForEach(NetworkProfile.presets, id: \.name) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                    Divider()
                    Text(Self.custom).tag(Self.custom)
                }
                LabeledContent("Download") {
                    NumberField(value: kilobits(\.downloadBytesPerSecond), unit: "kbit/s", placeholder: "No limit")
                }
                LabeledContent("Upload") {
                    NumberField(value: kilobits(\.uploadBytesPerSecond), unit: "kbit/s", placeholder: "No limit")
                }
                LabeledContent("Latency") {
                    NumberField(value: latency, unit: "ms", placeholder: "None")
                }
                LabeledContent("Packet loss") {
                    DecimalField(value: packetLoss, unit: "%", placeholder: "None")
                }
            } header: {
                Text("Network")
            } footer: {
                Text(
                    "Latency is the time a round trip to the server takes, and opening a connection takes one too. Each lost packet holds the connection up for a round trip."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Section {
                if rules.network.hosts.isEmpty {
                    Text("Every host")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(rules.network.hosts.enumerated()), id: \.offset) { index, host in
                    HStack {
                        Text(host)
                            .font(.body.monospaced())
                        Spacer()
                        Button("Remove \(host)", systemImage: "minus.circle") {
                            rules.network.hosts.remove(at: index)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
                HStack {
                    TextField("Add a Host", text: $newHost, prompt: Text("api.weatherly.dev or *.weatherly.dev"))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .onSubmit(addHost)
                    Button("Add", action: addHost)
                        .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Hosts")
            } footer: {
                Text(
                    "With no hosts listed, every host is slowed down. Changes apply to new connections, and Reqly closes the encrypted connections a change affects, so apps reconnect over the new network."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addHost() {
        let host = newHost.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty else { return }
        if !rules.network.hosts.contains(host) {
            rules.network.hosts.append(host)
        }
        newHost = ""
    }

    /// Picking a preset sets all its numbers. Picking Custom keeps the numbers as they are.
    private var profileName: Binding<String> {
        Binding(
            get: { rules.network.profile.name },
            set: { name in
                if let preset = NetworkProfile.presets.first(where: { $0.name == name }) {
                    rules.network.profile = preset
                } else {
                    rules.network.profile.name = Self.custom
                }
            }
        )
    }

    /// Changing a number makes the profile a custom one.
    private func setCustom(_ change: (inout NetworkProfile) -> Void) {
        var profile = rules.network.profile
        change(&profile)
        guard profile != rules.network.profile else { return }
        profile.name = Self.custom
        rules.network.profile = profile
    }

    /// A speed in kilobits a second, as networks are usually described, for one in bytes.
    private func kilobits(_ speed: WritableKeyPath<NetworkProfile, Int?>) -> Binding<Int?> {
        Binding(
            get: { rules.network.profile[keyPath: speed].map { $0 * 8 / 1000 } },
            set: { kilobits in
                setCustom { $0[keyPath: speed] = kilobits.flatMap { $0 > 0 ? $0 * 1000 / 8 : nil } }
            }
        )
    }

    private var latency: Binding<Int?> {
        Binding(
            get: { rules.network.profile.latency > 0 ? rules.network.profile.latency : nil },
            set: { latency in setCustom { $0.latency = max(latency ?? 0, 0) } }
        )
    }

    private var packetLoss: Binding<Double?> {
        Binding(
            get: { rules.network.profile.packetLoss > 0 ? rules.network.profile.packetLoss * 100 : nil },
            set: { percent in setCustom { $0.packetLoss = min(max(percent ?? 0, 0), 100) / 100 } }
        )
    }
}

/// A whole number with its unit after it. Empty means no number, such as no speed limit.
private struct NumberField: View {
    @Binding var value: Int?
    let unit: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            TextField(unit, value: $value, format: .number, prompt: Text(placeholder))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
    }
}

/// The same, for a number that can have a fraction, such as a percentage.
private struct DecimalField: View {
    @Binding var value: Double?
    let unit: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            TextField(
                unit, value: $value, format: .number.precision(.fractionLength(0...1)), prompt: Text(placeholder)
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
    }
}
