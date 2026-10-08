import AppKit
import SwiftUI

/// What Reqly tells about itself: its version, where to learn more, its license, and the
/// open-source code it includes.
enum AppInfo {
    static let website = URL(string: "https://reqly.net")!
    static let sourceCode = URL(string: "https://github.com/parsamlm/reqly")!
    static let sponsor = URL(string: "https://github.com/sponsors/parsamlm")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 The Reqly Authors"
    }

    /// The license's full text, as the app carries it.
    static var licenseText: String? {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Help ▸ Reqly Help: the website, the version, the license, and the licenses of the open-source
/// code inside Reqly.
struct HelpWindow: View {
    @State private var isShowingLicense = false
    @State private var isShowingOpenSourceLicenses = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .accessibilityHidden(true)
                Text("Reqly")
                    .font(.title2.weight(.semibold))
                Text("Version \(AppInfo.version) (\(AppInfo.build))")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("An open-source inspector for what your apps send and receive.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Website").foregroundStyle(.secondary)
                    Link("reqly.net", destination: AppInfo.website)
                }
                GridRow {
                    Text("Source code").foregroundStyle(.secondary)
                    Link("github.com/parsamlm/reqly", destination: AppInfo.sourceCode)
                }
                GridRow {
                    Text("License").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("MIT License")
                        HStack(spacing: 8) {
                            Button("View License") {
                                isShowingLicense = true
                            }
                            Button("Open Source Licenses") {
                                isShowingOpenSourceLicenses = true
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))

            VStack(spacing: 4) {
                Text(AppInfo.copyright)
                Text("The Reqly name, icon and wordmark aren't covered by the license.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(width: 420)
        .sheet(isPresented: $isShowingLicense) {
            LicenseSheet()
        }
        .sheet(isPresented: $isShowingOpenSourceLicenses) {
            OpenSourceLicensesSheet()
        }
    }
}

/// The MIT License, in full.
private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MIT License")
                .font(.headline)
            ScrollView {
                Text(AppInfo.licenseText ?? "Reqly couldn't find its license text. It's the MIT License.")
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 260)
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
