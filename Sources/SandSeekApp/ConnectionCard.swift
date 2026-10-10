import AppKit
import SandSeekAppLogic
import SwiftUI

/// The model server: which kind, where it listens, whether it answers, which
/// models it lists, and how to start one. SandSeek never starts or stops a
/// model server; it only connects to one that runs.
struct ConnectionCard: View {
    let server: ResearchServerController
    /// What is typed in the address field. It is taken over on Return or
    /// Check, so a half-typed address is not looked at.
    @State private var draft: String
    @State private var copied = false

    init(server: ResearchServerController) {
        self.server = server
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
                TextField("127.0.0.1:8080", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(commitAddress)
                    .accessibilityLabel("Server address")
                Button("Check") {
                    commitAddress()
                    Task { await server.check() }
                }
                .disabled(server.state.isBusy || draftProblem != nil)
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
            }
            detail
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
        return text
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
                    .help("The command holds the key SandSeek sends; paste it into Terminal only.")
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
