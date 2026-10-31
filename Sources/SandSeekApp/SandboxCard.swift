import SandSeekAppLogic
import SwiftUI

/// The web sandbox: a fresh Linux VM that fetches pages and cannot see this
/// Mac. The card starts and stops it and runs its security check.
struct SandboxCard: View {
    let workspace: ResearchWorkspace
    /// Whether the card shows only its title row. Kept by the window, which
    /// also folds it on its own when the sandbox is ready.
    @Binding var folded: Bool

    private var sandbox: ResearchSandboxController { workspace.sandbox }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FoldingCardHeader(
                icon: "shippingbox.and.arrow.backward", title: "Web sandbox",
                subject: "web sandbox", badge: badge, summaryText: summaryText,
                folded: $folded,
                summary: { signedSummary },
                accessory: {
                    if sandbox.state.isBusy || sandbox.isRunningSelfTest {
                        ProgressView().controlSize(.small)
                    }
                    HelpPopoverButton(label: "About the web sandbox") { helpText }
                })
            if !folded { details }
        }
        .cardStyle()
    }

    /// Everything under the title row; hidden while the card is folded.
    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(detailColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sandbox.state == .ready, let notice = sandbox.kernelNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sandbox.files?.origin == .checkout {
                Text("Using the files in \(SandboxResources.overrideVariable), not the copy that came with the app.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if sandbox.state == .off {
                    Button("Start Sandbox") { Task { await sandbox.start() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(workspace.isStoppingEverything)
                } else {
                    Button("Stop Sandbox") { Task { await workspace.stopSandbox() } }
                        .disabled(sandbox.state.isBusy || workspace.isStoppingEverything)
                        .help("Stops the question that is running, and the sandbox.")
                }
                Button("Security check") { Task { await sandbox.runSelfTest() } }
                    .disabled(sandbox.state != .ready || sandbox.isRunningSelfTest
                              || workspace.isStoppingEverything)
                    .help("Checks from outside the VM that the sandbox cannot reach this Mac or your local network, and can still reach the web.")
            }
            if let result = sandbox.selfTest {
                ResearchSelfTestView(result: result)
            }
        }
    }

    private var badge: (label: String, color: Color) {
        if sandbox.state == .ready {
            switch sandbox.protection {
            case .verified:
                // A failed security check is never hidden behind "Ready".
                return sandbox.securityCheckFailed ? ("Check failed", .red) : ("Ready", .green)
            case .checking, .unknown: return ("Checking", .orange)
            case .notVerified: return ("Not verified", .red)
            }
        }
        switch sandbox.state {
        case .off: return ("Off", .secondary)
        case .preparing: return ("Preparing", .orange)
        case .starting: return ("Starting", .orange)
        case .stopping: return ("Stopping", .orange)
        case .ready: return ("Ready", .green)
        case .failed: return ("Problem", .red)
        }
    }

    /// The summary as text: "Signed \u{00B7} checked 14:05" (only when the
    /// sandbox is verified), "Security check failed", or "Check failed" when
    /// the sandbox stopped passing its signed health check.
    private var summaryText: String? {
        let checked = checkSummaryText
        guard sandbox.kernelNotice != nil else { return checked }
        return [checked, "Older Linux kernel"].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private var checkSummaryText: String? {
        if sandbox.securityCheckFailed { return "Security check failed" }
        if sandbox.showsSignedSeal, let checked = sandbox.lastSignedCheck {
            return "Signed \u{00B7} " + ResearchSandboxController.checkedLabel(for: checked)
        }
        if sandbox.lastCheckFailure != nil { return "Check failed" }
        return nil
    }

    /// After the badge, also on the folded row: "Signed" with a checkmark and
    /// the time of the last signed health check (only while the sandbox is
    /// verified), a red "Security check failed", or, if the signed health
    /// check failed, a plain "Check failed". An orange "Older Linux kernel"
    /// follows when the kernel warning is set.
    @ViewBuilder
    private var signedSummary: some View {
        if sandbox.securityCheckFailed {
            Label("Security check failed", systemImage: "xmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        } else if sandbox.showsSignedSeal, let checked = sandbox.lastSignedCheck {
            Label {
                Text("\(Text("Signed").fontWeight(.semibold)) \u{00B7} \(ResearchSandboxController.checkedLabel(for: checked))")
                    .font(.caption)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
            }
            .foregroundStyle(.green)
            .help("The sandbox answered the last health check with a signature that only it can make.")
        } else if sandbox.lastCheckFailure != nil {
            Label("Check failed", systemImage: "xmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        }
        if sandbox.kernelNotice != nil {
            Label("Older Linux kernel", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .help("The sandbox\u{2019}s Linux kernel is older than the one Apple container recommends. Open the card to see how to update it.")
        }
    }

    /// The short line under the title row; nil when the badge says it all.
    private var detail: String? {
        if let failure = sandbox.lastCheckFailure, sandbox.state == .off { return failure }
        switch sandbox.state {
        case .failed(let message):
            return message
        case .preparing:
            if let note = sandbox.restartNote { return note + "\u{2026}" }
            return "Building the sandbox image. The first time takes a few minutes."
        case .starting:
            if let note = sandbox.restartNote { return note + "\u{2026}" }
            return "Starting a fresh Linux VM\u{2026}"
        case .stopping:
            return "Stopping the VM\u{2026}"
        case .ready:
            let leftOver = sandbox.adoptedFromLastRun
                ? " It was left running when SandSeek last closed unexpectedly; it stops when SandSeek quits." : ""
            switch sandbox.protection {
            case .verified:
                return "Ready on 127.0.0.1:\(sandbox.baseURL.port ?? ResearchSandboxController.port), with no Mac folders."
                    + leftOver
            case .checking, .unknown:
                return "Checking the sandbox\u{2019}s firewall and privileges\u{2026}" + leftOver
            case .notVerified(let message):
                return "Not verified: " + message + " Questions stay off until the check passes."
            }
        case .off:
            return nil
        }
    }

    private var detailColor: Color {
        if sandbox.state == .off && sandbox.lastCheckFailure != nil { return .red }
        return .secondary
    }

    /// The longer explanations, kept out of the card itself.
    @ViewBuilder
    private var helpText: some View {
        HelpParagraph(text: "A fresh Linux VM in Apple container fetches pages. It cannot see your files.")
        HelpParagraph(text: "When it is ready, its firewall is on and its web server runs without privileges. "
            + "It can reach public web addresses, and on this Mac only the DNS port when it "
            + "uses the Mac\u{2019}s DNS.")
        HelpParagraph(text: "\u{201C}Signed\u{201D} means the sandbox answered SandSeek\u{2019}s last health check "
            + "with a signature only it can make, so it is the SandSeek sandbox and not another program on its port.")
    }
}

struct ResearchSelfTestView: View {
    let result: ResearchSelfTestResult
    /// Open when something failed; a result that passed starts folded.
    @State private var showsChecks: Bool

    init(result: ResearchSelfTestResult) {
        self.result = result
        _showsChecks = State(initialValue: !result.passed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showsChecks.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showsChecks ? 90 : 0))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Label(result.passed ? "All safety checks passed" : "Some safety checks failed",
                          systemImage: result.passed ? "checkmark.shield" : "exclamationmark.shield")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(result.passed ? Color.green : Color.red)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showsChecks ? "Hide the checks" : "Show the checks")
            if showsChecks {
                ForEach(result.checks) { check in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(for: check.outcome))
                            .foregroundStyle(color(for: check.outcome))
                        Text(check.text)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !result.summary.isEmpty {
                    Text(result.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func symbol(for outcome: ResearchSelfTestCheck.Outcome) -> String {
        switch outcome {
        case .passed: "checkmark.circle"
        case .failed: "xmark.circle"
        case .warning: "exclamationmark.circle"
        }
    }

    private func color(for outcome: ResearchSelfTestCheck.Outcome) -> Color {
        switch outcome {
        case .passed: .green
        case .failed: .red
        case .warning: .orange
        }
    }
}

