import AppKit
import SandSeekAppLogic
import SandSeekCore
import SwiftUI

/// The model server: which kind, where it listens, whether it answers, which
/// models it lists, and how to start one. SandSeek never starts or stops a
/// model server; it only connects to one that runs.
struct ConnectionCard: View {
    let server: ResearchServerController
    /// True while a question runs: the type, the address and Check stay as
    /// they are, so the card cannot flip to "Not running" under the run.
    let locked: Bool
    /// The prompt budget set in Settings for a llama.cpp server that does not
    /// say how large its context is.
    let promptBudget: Int?
    /// What is typed in the address field. It is taken over on Return or
    /// Check, so a half-typed address is not looked at.
    @State private var draft: String
    @State private var copied = false

    init(server: ResearchServerController, locked: Bool, promptBudget: Int?) {
        self.server = server
        self.locked = locked
        self.promptBudget = promptBudget
        _draft = State(initialValue: server.addressText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 12) {
                Picker("Server", selection: Binding(
                    get: { server.serverType },
                    set: { server.select($0) })
                ) {
                    ForEach(ResearchServerType.allCases) { type in
                        Text(type.pickerLabel)
                            .tag(type)
                            .disabled(!type.isAvailable)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(locked)
                TextField("127.0.0.1:8080", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(commitAddress)
                    .accessibilityLabel("Server address")
                    .disabled(locked)
                Button("Check") {
                    commitAddress()
                    Task { await server.check() }
                }
                .disabled(locked || server.state.isBusy || draftProblem != nil)
            }
            if let problem = draftProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if draft != (server.serverType.defaultAddress ?? "") {
                Button("Use the default address") {
                    server.restoreDefaultAddress()
                    draft = server.addressText
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(locked)
            }
            if locked {
                Text("The server is busy with your question. It can be changed when the question is done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            detail
            exposureNotice
            if server.serverType == .llamacpp {
                llamaCommand
            }
            Text(ResearchServerController.memoryNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
        .onChange(of: server.addressText) { draft = server.addressText }
    }

    // MARK: - Parts

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Model server").font(.headline)
            StatusBadge(label: badge.label, color: badge.color)
            if server.state.isBusy { ProgressView().controlSize(.small) }
            Spacer()
        }
    }

    private var badge: (label: String, color: Color) {
        switch server.state {
        case .notChecked: ("Not checked", .secondary)
        case .checking: ("Checking", .orange)
        case .ready: ("Connected", .green)
        case .off: ("Not running", .secondary)
        case .problem: ("Problem", .red)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch server.state {
        case .ready:
            Text(readyText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if server.needsPromptBudget {
                Text(budgetText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .problem(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            hint
        case .off:
            if let reason = server.offReason {
                Text("Nothing answers: \(reason)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            hint
        case .notChecked, .checking:
            hint
        }
    }

    /// Whether the server can be reached from the network. Found by Check
    /// only; the periodic look does not touch it.
    @ViewBuilder
    private var exposureNotice: some View {
        switch server.exposure {
        case .reachable(let warning):
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .notReachable(let addresses):
            Text(verbatim: notReachableText(addresses))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking whether the server is reachable from the network…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .notChecked:
            EmptyView()
        }
    }

    private func notReachableText(_ addresses: Int) -> String {
        if addresses == 0 {
            return "This Mac has no network address to try; the server is not reachable from the network."
        }
        let noun = addresses == 1 ? "address" : "addresses"
        return "Not reachable from the network (\(addresses) \(noun) tried)."
    }

    private var hint: some View {
        Text(server.startHint)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var readyText: String {
        var text = server.serverType.displayName
        if let version = server.connection?.version, !version.isEmpty { text += " " + version }
        text += " answers. Models: "
        text += server.models.map(\.displayName).joined(separator: ", ") + "."
        if let window = server.connection?.contextTokens {
            text += " Context window: \(window.formatted()) tokens."
        }
        return text
    }

    private var budgetText: String {
        let characters = promptBudget ?? ResearchOptions.fallbackBudgetCharacters
        let source = promptBudget == nil ? "a small default" : "the budget from Settings"
        return "The server did not say how large its context window is, so questions use "
            + source + " (\(characters.formatted()) characters of prompt). "
            + "Settings has a Prompt budget to change it."
    }

    private var llamaCommand: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let command = server.startCommand {
                if server.state != .ready {
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 10) {
                    Button(copied ? "Copied" : "Copy start command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                    .help("The command names the key file; it holds no key.")
                }
            }
            Text(ResearchServerController.keyNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = server.keyProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Address

    private var draftProblem: String? {
        do {
            _ = try ResearchServerController.parseAddress(draft)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private func commitAddress() {
        server.setAddress(draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
