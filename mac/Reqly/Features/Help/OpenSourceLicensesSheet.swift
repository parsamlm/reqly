import SwiftUI

/// An open-source package whose code is inside Reqly, with its license and notices in full.
struct OpenSourcePackage: Decodable, Identifiable {
    /// A license, or a notice that a license asks to keep with the code. The title is the file it
    /// comes from, or the code it covers.
    struct Notice: Decodable {
        let title: String
        let text: String
    }

    let name: String
    let version: String
    let url: URL
    let license: String
    let notices: [Notice]

    var id: String { name }
}

extension AppInfo {
    /// The open-source packages inside Reqly, from `Acknowledgements.json`, which
    /// `tools/acknowledgements.py` writes.
    static let openSourcePackages: [OpenSourcePackage] = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(Acknowledgements.self, from: data)
        else { return [] }
        return file.packages
    }()

    private struct Acknowledgements: Decodable {
        let packages: [OpenSourcePackage]
    }
}

/// The licenses of the open-source packages inside Reqly, in full: the packages on the left, and
/// the chosen one's license and notices on the right.
struct OpenSourceLicensesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = AppInfo.openSourcePackages.first?.id

    private let packages = AppInfo.openSourcePackages

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Open Source Licenses")
                    .font(.headline)
                Text("Reqly includes code from these open-source packages, each under its own license.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if packages.isEmpty {
                Text("Reqly couldn't find its list of open-source licenses.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 0) {
                    List(packages, selection: choice) { package in
                        HStack {
                            Text(package.name)
                            Spacer()
                            Text(package.version)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .scrollContentBackground(.hidden)
                    .frame(width: 200)
                    Divider()
                    if let package = packages.first(where: { $0.id == chosen }) {
                        ScrollView {
                            PackageLicense(package: package)
                                .padding(16)
                        }
                        // Each package starts at the top.
                        .id(package.id)
                    }
                }
                .frame(height: 320)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            }
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        // License files wrap at about 80 characters. The text column fits that, so their lines
        // don't wrap a second time.
        .frame(width: 760)
    }

    /// The list always has a package chosen.
    private var choice: Binding<OpenSourcePackage.ID?> {
        Binding(
            get: { chosen },
            set: { if let id = $0 { chosen = id } }
        )
    }
}

/// One package's version and link, then its license and notices.
private struct PackageLicense: View {
    let package: OpenSourcePackage

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(package.name)
                    .font(.headline)
                Text("Version \(package.version) · \(package.license)")
                    .foregroundStyle(.secondary)
                Link((package.url.host() ?? "") + package.url.path(), destination: package.url)
            }
            ForEach(package.notices, id: \.title) { notice in
                VStack(alignment: .leading, spacing: 6) {
                    Text(notice.title)
                        .fontWeight(.semibold)
                    Text(notice.text)
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
