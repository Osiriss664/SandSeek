import AppKit
import SandSeekAppLogic
import SandSeekCore
import SwiftUI

/// The two presets, which can be changed, and the safety rules, which cannot.
struct SettingsScreen: View {
    @Bindable var presets: ResearchPresetStore
    let server: ResearchServerController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(
                    title: "Settings",
                    subtitle: "What each mode asks of the model, and the rules that are always on.")
                PresetEditor(id: .quick, preset: $presets.quick)
                PresetEditor(id: .thorough, preset: $presets.thorough)
                if server.needsPromptBudget {
                    PromptBudgetCard(presets: presets)
                }
                SecurityTable()
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// One preset's numbers, within the ranges the `sandseek` command accepts.
private struct PresetEditor: View {
    let id: ResearchPresetID
    @Binding var preset: ResearchPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(id.title).font(.headline)
                Spacer()
                Button("Restore Defaults") { preset = .defaults(for: id) }
                    .buttonStyle(.link)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Stepper(value: $preset.maxSteps, in: ResearchOptions.maxStepsRange) {
                        Text("Steps: \(preset.maxSteps)").font(.body.monospacedDigit())
                    }
                    .help("How many search and read rounds the model may take before it must answer.")
                    Stepper(value: $preset.minimumPages, in: ResearchOptions.minimumPagesRange) {
                        Text("Pages to read: \(preset.minimumPages)").font(.body.monospacedDigit())
                    }
                    .help("The model is asked to read at least this many pages, and the research opens top results to reach it.")
                }
                GridRow {
                    Stepper(value: $preset.searchResults, in: ResearchOptions.searchResultsRange) {
                        Text("Results per search: \(preset.searchResults)").font(.body.monospacedDigit())
                    }
                    Stepper(value: $preset.toolCallsPerStep, in: ResearchOptions.toolCallsRange) {
                        Text("Tool calls per step: \(preset.toolCallsPerStep)").font(.body.monospacedDigit())
                    }
                    .help("Searches and page reads the model may ask for in one step.")
                }
                GridRow {
                    Stepper(value: $preset.pageCharacters, in: ResearchOptions.pageCharactersRange, step: 500) {
                        Text("Page text per read: \(preset.pageCharacters) characters").font(.body.monospacedDigit())
                    }
                    Stepper(value: $preset.tokensPerStep, in: ResearchOptions.maxTokensRange, step: 256) {
                        Text("Tokens per step: \(preset.tokensPerStep)").font(.body.monospacedDigit())
                    }
                    .help("What the model may write per step, unless thinking is turned on. 2,048 is the sandseek command's default.")
                }
                GridRow {
                    Stepper(value: $preset.tokensPerStepWithThinking, in: ResearchOptions.maxTokensRange, step: 256) {
                        Text("Tokens per step, thinking on: \(preset.tokensPerStepWithThinking)").font(.body.monospacedDigit())
                    }
                    .help("Used when thinking is turned on here; the reasoning shares the limit.")
                    Stepper(value: $preset.stepLimitMinutes, in: ResearchOptions.stepTimeoutMinutesRange) {
                        Text("Step time limit: \(preset.stepLimitMinutes) min").font(.body.monospacedDigit())
                    }
                    .help("A step that takes longer is asked again without thinking.")
                }
                GridRow {
                    Stepper(value: $preset.thinkingLimitMinutes, in: ResearchOptions.thinkingMinutesRange) {
                        Text("Thinking time limit: \(preset.thinkingLimitMinutes) min").font(.body.monospacedDigit())
                    }
                    .help("A step with thinking on that takes longer is asked again without thinking, which stays off for the rest of the question.")
                    Picker("Thinking", selection: $preset.thinking) {
                        ForEach(ResearchThinkingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .fixedSize()
                    .help("Server default sends no thinking setting, as the sandseek command does. On and Off ask the model explicitly. Thinking is shown with the progress and never added to the report.")
                }
                GridRow {
                    Toggle("Open top results when too few pages are read", isOn: $preset.autoOpenPages)
                    Toggle("Ask the model to search, read and look wider", isOn: $preset.nudges)
                }
                GridRow {
                    Toggle("Rewrite answers that cite unread pages", isOn: $preset.rewriteAnswers)
                        .help("Also keeps the check of figures against the pages on.")
                }
            }
        }
        .cardStyle()
    }
}

/// How much prompt a llama.cpp server that does not say its context size
/// gets. Shown only then.
private struct PromptBudgetCard: View {
    @Bindable var presets: ResearchPresetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt budget").font(.headline)
            Text("The llama.cpp server did not say how large its context window is. Older results are shortened once the conversation passes this budget. Set it below the context size you started llama-server with (-c).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Prompt budget", selection: $presets.llamaPromptBudget) {
                Text("Small default (\(ResearchOptions.fallbackBudgetCharacters.formatted()) characters)")
                    .tag(Int?.none)
                ForEach([8_000, 16_000, 32_000, 46_000, 64_000], id: \.self) { size in
                    Text("\(size.formatted()) characters").tag(Int?.some(size))
                }
            }
            .fixedSize()
        }
        .cardStyle()
    }
}

/// The rules that protect the Mac. They are shown, not editable.
private struct SecurityTable: View {
    private let rules: [(title: String, text: String)] = [
        ("Two tools only",
         "The model can search the web and read a page. It gets no other tool: no files, no shell, no code."),
        ("Firewall in the VM",
         "The sandbox is a Linux VM with its own firewall. It can reach public web addresses, and on this Mac only the DNS port when it uses the Mac's DNS. It cannot reach this Mac or your local network."),
        ("No root in the sandbox",
         "The web server in the sandbox runs without privileges, in a VM that has none of your folders."),
        ("Checked before every question",
         "SandSeek checks the firewall and the privileges from outside the VM before each question. If the check fails, no question is sent."),
        ("Links need your confirmation",
         "A link from an answer opens in your browser only after you confirm the full address."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                Text("Safety rules").font(.headline)
                Spacer()
                Text("Always on. They cannot be changed here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.title).font(.callout.weight(.semibold))
                        Text(rule.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .cardStyle()
    }
}
