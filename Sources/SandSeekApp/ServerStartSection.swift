import AppKit
import SandSeekAppLogic
import SandSeekCore
import SwiftUI
import UniformTypeIdentifiers

/// "Start server" and "Stop server" on the model server card, and the choice
/// of the program and the model they use. The file dialogs live here, in the
/// app; the logic only gets the paths (`ResearchServerLaunchController`).
struct ServerStartSection: View {
    let server: ResearchServerController
    let launch: ResearchServerLaunchController
    /// True while a question runs or is being prepared: the server stays as it
    /// is, so the question does not lose it.
    let questionBusy: Bool
    /// True while "Stop everything" runs: Start server and Stop server wait.
    let stoppingEverything: Bool

    private var type: ResearchServerType { server.serverType }
    private var blocker: String? { launch.startBlocker(for: server) }

    var body: some View {
        if type.canStart {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("Start it from SandSeek").font(.subheadline.weight(.semibold))
                chosenRow(
                    label: programLabel,
                    path: launch.programs[type], placeholder: "not chosen",
                    button: "Choose program…", action: chooseProgram)
                if type == .ollama {
                    Text("Starting and stopping Ollama is experimental.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // Resolved first: `/usr/local/bin/ollama` (made by the app) and the
                    // Homebrew cask's `ollama` are links into Ollama.app.
                    if let program = launch.programs[type],
                       ResearchServerLaunchPlan.isInsideApp(
                           URL(fileURLWithPath: program).resolvingSymlinksInPath().path) {
                        Text(ResearchServerLaunchPlan.ollamaAppNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if type == .tuff {
                    chosenRow(
                        label: "Models folder (optional)", path: launch.models[type],
                        placeholder: "TUFF's own folder", button: "Choose models folder…",
                        action: chooseModel)
                    foundModels
                    if launch.models[type] != nil {
                        Button("Use TUFF's own folder") { launch.chooseModel("", for: type) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(launch.state.isBusy || launch.owned != nil)
                    }
                } else {
                    chosenRow(
                        label: "Model", path: launch.models[type], placeholder: "not chosen",
                        button: "Choose model…", action: chooseModel)
                    foundModels
                }
                if let problem = launch.choiceProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                controls
                status
            }
            // Looks when the card appears, and again when another server type,
            // program (TUFF: the clone's `scratch`) or llama.cpp model (listed
            // in the menu) is chosen.
            .task(id: foundKey) {
                await launch.refreshFound(for: type)
            }
        }
    }

    private var foundKey: String {
        let model = type == .llamacpp ? launch.models[type] ?? "" : ""
        return "\(type)|\(launch.programs[type] ?? "")|\(model)"
    }

    /// "Models on this Mac": the models already on disk, found by
    /// `refreshFound`. A pick does what the file dialog does. Ollama lists
    /// its own models after Check, so it shows nothing here.
    @ViewBuilder
    private var foundModels: some View {
        let isEmpty = type == .tuff ? launch.foundTUFF.isEmpty : launch.foundGGUF.isEmpty
        HStack(spacing: 10) {
            if !isEmpty {
                Menu("Models on this Mac") {
                    if type == .tuff {
                        ForEach(launch.foundTUFF) { folder in
                            Button("\((folder.path as NSString).abbreviatingWithTildeInPath): "
                                + folder.models.joined(separator: ", ")) {
                                launch.chooseModel(folder.path, for: .tuff)
                            }
                        }
                    } else {
                        ForEach(launch.foundGGUF) { file in
                            Button("\(file.name) (\(Self.sizeText(file.size)))") {
                                launch.chooseModel(file.path, for: .llamacpp)
                            }
                        }
                    }
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(launch.state.isBusy || launch.owned != nil)
            } else if launch.isLookingForModels {
                ProgressView().controlSize(.small)
            } else {
                Text(type == .tuff
                    ? "No models found in the usual folders. Use Choose models folder…"
                    : "No models found in the usual folders. Use Choose model…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Look again") { Task { await launch.refreshFound(for: type) } }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(launch.isLookingForModels)
        }
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var programLabel: String {
        switch type {
        case .tuff: "TUFFServer"
        case .llamacpp: "llama-server"
        case .ollama: "ollama"
        case .lmstudio: "program"
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("Start server") { Task { await launch.start(using: server) } }
                .disabled(questionBusy || stoppingEverything || launch.state.isBusy || blocker != nil)
                .help("Starts the program above on 127.0.0.1. SandSeek stops it again when you quit.")
            if let owned = launch.owned {
                Button("Stop server") { Task { await launch.stop(using: server) } }
                    .disabled(questionBusy || stoppingEverything || launch.state == .stopping)
                Text("SandSeek started \(owned.type.displayName) on 127.0.0.1:\(owned.port) "
                    + "(\(owned.path))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(owned.path)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if questionBusy {
            Text("The server is busy with your question. Start and Stop wait until it is done.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let blocker, launch.state != .starting {
            Text(blocker)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        switch launch.state {
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(type == .ollama
                    ? "Starting Ollama."
                    : "Starting the server. Loading the model can take minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .stopping:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Stopping the server…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !launch.logTail.isEmpty {
                Text(launch.logTail)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        case .idle, .running:
            if launch.owned?.adopted == true {
                Text("This server was left running when SandSeek last closed unexpectedly. "
                    + "It stops when SandSeek quits.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chosenRow(label: String, path: String?, placeholder: String, button: String,
                           action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(path ?? placeholder)
                .font(.caption.monospaced())
                .foregroundStyle(path == nil ? Color.secondary : Color.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(path ?? placeholder)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button(button, action: action)
                .controlSize(.small)
                .disabled(launch.state.isBusy || launch.owned != nil)
        }
    }

    // MARK: - File dialogs

    private func chooseProgram() {
        let message: String
        var start: URL?
        switch type {
        case .tuff:
            message = "Choose TUFFServer, tuff or TUFF.app. SandSeek starts the TUFFServer beside it."
        case .ollama:
            message = "Choose ollama (for example the Homebrew one) or Ollama.app."
            // Opens in the Homebrew folder when the program is there.
            start = ResearchServerLaunchPlan.ollamaSuggestion()
                .map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        case .llamacpp, .lmstudio:
            message = "Choose llama-server."
        }
        guard let path = pick(files: true, start: start, hidden: true, message: message) else { return }
        launch.chooseProgram(path, for: type)
    }

    private func chooseModel() {
        if type == .tuff {
            // A TUFF built from a clone keeps its models in <clone>/scratch. The
            // dialog opens there if it exists; nothing is chosen for the person.
            let hint = launch.programs[type]
                .flatMap { ResearchServerLaunchPlan.cloneModelsHint(forProgram: $0) }
                .flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
            guard let path = pick(files: false, start: hint,
                                  message: "Choose the folder with TUFF's models.")
            else { return }
            launch.chooseModel(path, for: type)
        } else {
            let gguf = UTType(filenameExtension: "gguf").map { [$0] }
            guard let path = pick(files: true, types: gguf, message: "Choose a .gguf model file.")
            else { return }
            launch.chooseModel(path, for: type)
        }
    }

    /// An open panel for one file or one folder. A TUFF.app is a package,
    /// which the panel offers as a file.
    private func pick(files: Bool, types: [UTType]? = nil, start: URL? = nil,
                      hidden: Bool = false, message: String) -> String? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = files
        panel.canChooseDirectories = !files
        panel.allowsMultipleSelection = false
        if let types { panel.allowedContentTypes = types }
        if let start { panel.directoryURL = start }
        // A TUFF built from a clone is in `.build`, which the panel hides.
        panel.showsHiddenFiles = hidden
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
