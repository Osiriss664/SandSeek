import SandSeekAppLogic
import SwiftUI

/// The web sandbox: a fresh Linux VM that fetches pages and cannot see this
/// Mac. The card starts and stops it and runs its security check.
struct SandboxCard: View {
    let workspace: ResearchWorkspace

    private var sandbox: ResearchSandboxController { workspace.sandbox }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.and.arrow.backward")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Web sandbox").font(.headline)
                StatusBadge(label: badge.label, color: badge.color)
                if sandbox.state.isBusy || sandbox.isRunningSelfTest {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
                } else {
                    Button("Stop Sandbox") { Task { await workspace.stopSandbox() } }
                        .disabled(sandbox.state.isBusy)
                        .help("Stops the question that is running, and the sandbox if SandSeek started it.")
                }
                Button("Security check") { Task { await sandbox.runSelfTest() } }
                    .disabled(sandbox.state != .ready || sandbox.isRunningSelfTest)
                    .help("Checks from outside the VM that the sandbox cannot reach this Mac or your local network, and can still reach the web.")
            }
            if let result = sandbox.selfTest {
                ResearchSelfTestView(result: result)
            }
        }
        .cardStyle()
    }

    private var badge: (label: String, color: Color) {
        if sandbox.state == .ready {
            switch sandbox.protection {
            case .verified: return ("Ready", .green)
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

    private var detail: String {
        switch sandbox.state {
        case .failed(let message):
            return message
        case .preparing:
            if let note = sandbox.restartNote { return note + "…" }
            return "Building the sandbox image. The first time takes a few minutes."
        case .starting:
            if let note = sandbox.restartNote { return note + "…" }
            return "Starting a fresh Linux VM…"
        case .stopping:
            return "Stopping the VM…"
        case .ready:
            let leftOver = sandbox.adoptedFromLastRun
                ? " It was left running when SandSeek last closed unexpectedly; it stops when SandSeek quits." : ""
            switch sandbox.protection {
            case .verified:
                return "Ready on 127.0.0.1:\(ResearchSandboxController.port), with no Mac folders. "
                    + "Checked: its firewall is on and the web server runs without privileges. "
                    + "It can reach public web addresses, and on this Mac only the DNS port when it "
                    + "uses the Mac's DNS." + leftOver
            case .checking, .unknown:
                return "Checking the sandbox's firewall and privileges…" + leftOver
            case .notVerified(let message):
                return "Not verified: " + message + " Questions stay off until the check passes."
            }
        case .off:
            return "A fresh Linux VM in Apple container fetches pages. It cannot see your files."
        }
    }
}

struct ResearchSelfTestView: View {
    let result: ResearchSelfTestResult
    @State private var showsChecks = true

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

