import AppKit
import SwiftUI

/// Asks whether to report Reqly's last crash, and shows what the report says.
struct CrashReportWindow: View {
    @Environment(CrashReporter.self) private var crashes
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        crashes.report?.isHelper == true
                            ? "Reqly's helper quit unexpectedly" : "Reqly quit unexpectedly"
                    )
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    if let report = crashes.report {
                        Text(
                            "It happened \(report.date.formatted(date: .abbreviated, time: .shortened)). You can report it on GitHub, so it gets fixed. Reqly opens a new issue in your browser with the details below. Add what you were doing, and attach the full report if you like, then submit it yourself. Nothing is sent until you do."
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let report = crashes.report {
                ScrollView {
                    Text(report.body)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color("CodeBackground"), in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .accessibilityLabel("Crash details")
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([report.file])
                    }
                    .help("Shows the full report, to attach to the issue.")
                    Button("Copy Details") {
                        Pasteboard.copy(report.body)
                    }
                    Spacer()
                    Button("Don't Report", role: .cancel) {
                        crashes.dismiss()
                        dismissWindow(id: "crash-report")
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Report on GitHub…") {
                        crashes.openIssue()
                        dismissWindow(id: "crash-report")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }
}
