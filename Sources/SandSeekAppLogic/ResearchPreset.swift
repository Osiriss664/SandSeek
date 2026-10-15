import Foundation
import Observation
import SandSeekCore

/// The two ways to ask a question: a quick answer, or a thorough one.
public enum ResearchPresetID: String, CaseIterable, Identifiable, Codable, Sendable {
    case quick
    case thorough

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quick: "Quick answer"
        case .thorough: "Thorough"
        }
    }
}

/// Whether a run asks the model to think. The default leaves it to the
/// server and sends no field, which is what the `sandseek` command does
/// without `--thinking`, so a run from the window can be compared with the
/// command's baselines.
public enum ResearchThinkingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case serverDefault
    case on
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .serverDefault: "Server default"
        case .on: "On"
        case .off: "Off"
        }
    }

    /// The `enable_thinking` value to send; nil sends none.
    public var enabled: Bool? {
        switch self {
        case .serverDefault: nil
        case .on: true
        case .off: false
        }
    }
}

/// The values behind one of the two presets. Everything here can be changed
/// in Settings, within the ranges the command line accepts. The limits that
/// protect the Mac (the two tools, the sandbox's firewall, fetch limits and
/// the check before every question) are not here: they are fixed.
public struct ResearchPreset: Equatable, Sendable {
    /// Search and read rounds before the model must answer.
    public var maxSteps: Int
    /// Pages the research should have read; the prompt asks for this many.
    public var minimumPages: Int
    /// Results each search returns.
    public var searchResults: Int
    /// Searches and page reads the model may ask for in one step.
    public var toolCallsPerStep: Int
    /// Characters of page text one read returns.
    public var pageCharacters: Int
    /// Tokens per step unless thinking is turned on. This is the command's
    /// default too (2,048).
    public var tokensPerStep: Int
    /// Tokens per step with thinking turned on (reasoning shares the limit).
    public var tokensPerStepWithThinking: Int
    /// Minutes one step may take before it is asked again.
    public var stepLimitMinutes: Int
    /// Minutes a step with thinking on may take before thinking is turned off.
    public var thinkingLimitMinutes: Int
    /// Thinking left to the server (the default), or turned on or off.
    public var thinking: ResearchThinkingMode
    /// Open top results when too few pages were read.
    public var autoOpenPages: Bool
    /// Ask the model once to search, read and look wider when it answers too early.
    public var nudges: Bool
    /// Ask for a rewrite when the answer cites pages it never read, and keep
    /// the check of figures against the pages on.
    public var rewriteAnswers: Bool

    public init(maxSteps: Int, minimumPages: Int, searchResults: Int,
                toolCallsPerStep: Int = 4, pageCharacters: Int = 3_000,
                tokensPerStep: Int = 2_048, tokensPerStepWithThinking: Int = 8_192,
                stepLimitMinutes: Int = 30, thinkingLimitMinutes: Int = 3,
                thinking: ResearchThinkingMode = .serverDefault, autoOpenPages: Bool = true, nudges: Bool = true,
                rewriteAnswers: Bool = true) {
        self.maxSteps = maxSteps
        self.minimumPages = minimumPages
        self.searchResults = searchResults
        self.toolCallsPerStep = toolCallsPerStep
        self.pageCharacters = pageCharacters
        self.tokensPerStep = tokensPerStep
        self.tokensPerStepWithThinking = tokensPerStepWithThinking
        self.stepLimitMinutes = stepLimitMinutes
        self.thinkingLimitMinutes = thinkingLimitMinutes
        self.thinking = thinking
        self.autoOpenPages = autoOpenPages
        self.nudges = nudges
        self.rewriteAnswers = rewriteAnswers
    }

    /// The default quick preset: today's defaults of the research loop
    /// (8 steps, 3 pages at least, 5 results per search), and thinking left
    /// to the server, so it matches the `sandseek` command's baseline.
    public static let quick = ResearchPreset(
        maxSteps: 8, minimumPages: 3, searchResults: 5)

    /// The default thorough preset: 30 steps, 6 pages at least, 8 results per
    /// search, thinking left to the server.
    ///
    /// NOT TESTED YET. These values come from the app mockup. They are
    /// measured later (a run on TUFF with Qwen and thinking, and one
    /// on llama.cpp) and fixed afterwards. The mockup said 10 pages; 6 is what
    /// the top-up that opens search results can reach (`autoOpenAttempts` is
    /// 6), so a higher number would only be a request to the model. Measuring
    /// will show whether more is worth it.
    public static let thorough = ResearchPreset(
        maxSteps: 30, minimumPages: 6, searchResults: 8)

    public static func defaults(for id: ResearchPresetID) -> ResearchPreset {
        switch id {
        case .quick: .quick
        case .thorough: .thorough
        }
    }

    /// The same preset with every number inside the range the command line
    /// accepts (`ResearchOptions`), so a stored or typed value cannot ask for
    /// something the loop refuses.
    public func clamped() -> ResearchPreset {
        var copy = self
        copy.maxSteps = maxSteps.limited(to: ResearchOptions.maxStepsRange)
        copy.minimumPages = minimumPages.limited(to: ResearchOptions.minimumPagesRange)
        copy.searchResults = searchResults.limited(to: ResearchOptions.searchResultsRange)
        copy.toolCallsPerStep = toolCallsPerStep.limited(to: ResearchOptions.toolCallsRange)
        copy.pageCharacters = pageCharacters.limited(to: ResearchOptions.pageCharactersRange)
        copy.tokensPerStep = tokensPerStep.limited(to: ResearchOptions.maxTokensRange)
        copy.tokensPerStepWithThinking = tokensPerStepWithThinking
            .limited(to: ResearchOptions.maxTokensRange)
        copy.stepLimitMinutes = stepLimitMinutes.limited(to: ResearchOptions.stepTimeoutMinutesRange)
        copy.thinkingLimitMinutes = thinkingLimitMinutes
            .limited(to: ResearchOptions.thinkingMinutesRange)
        return copy
    }

    /// The settings of a run with this preset for `model`.
    public func runSettings(model: String) -> ResearchRunSettings {
        let preset = clamped()
        return ResearchRunSettings(
            model: model,
            // No field is sent unless thinking was turned on or off here.
            showThinking: false,
            maxSteps: preset.maxSteps,
            pageCharacters: preset.pageCharacters,
            thinking: preset.thinking.enabled,
            maxTokensLimit: preset.thinking == .on
                ? preset.tokensPerStepWithThinking : preset.tokensPerStep,
            searchResults: preset.searchResults,
            toolCallsPerTurn: preset.toolCallsPerStep,
            minimumPages: preset.minimumPages,
            autoOpenPages: preset.autoOpenPages,
            nudges: preset.nudges,
            reviseUnreadCitations: preset.rewriteAnswers,
            stepTimeoutMinutes: preset.stepLimitMinutes,
            thinkingMinutes: preset.thinkingLimitMinutes)
    }
}

extension Comparable {
    fileprivate func limited(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// What differs from a preset's defaults. Only these values are stored, so a
/// default that changes in a later version reaches everyone who did not change
/// that value, and a field that is added later does not make stored presets
/// unreadable. A value that cannot be read is skipped and falls back to its
/// default.
struct ResearchPresetChanges: Codable, Equatable {
    var maxSteps: Int?
    var minimumPages: Int?
    var searchResults: Int?
    var toolCallsPerStep: Int?
    var pageCharacters: Int?
    var tokensPerStep: Int?
    var tokensPerStepWithThinking: Int?
    var stepLimitMinutes: Int?
    var thinkingLimitMinutes: Int?
    var thinking: ResearchThinkingMode?
    var autoOpenPages: Bool?
    var nudges: Bool?
    var rewriteAnswers: Bool?

    init() {}

    /// The values of `preset` that are not those of `base`.
    init(_ preset: ResearchPreset, comparedTo base: ResearchPreset) {
        func changed<T: Equatable>(_ new: T, _ old: T) -> T? { new == old ? nil : new }
        maxSteps = changed(preset.maxSteps, base.maxSteps)
        minimumPages = changed(preset.minimumPages, base.minimumPages)
        searchResults = changed(preset.searchResults, base.searchResults)
        toolCallsPerStep = changed(preset.toolCallsPerStep, base.toolCallsPerStep)
        pageCharacters = changed(preset.pageCharacters, base.pageCharacters)
        tokensPerStep = changed(preset.tokensPerStep, base.tokensPerStep)
        tokensPerStepWithThinking = changed(
            preset.tokensPerStepWithThinking, base.tokensPerStepWithThinking)
        stepLimitMinutes = changed(preset.stepLimitMinutes, base.stepLimitMinutes)
        thinkingLimitMinutes = changed(preset.thinkingLimitMinutes, base.thinkingLimitMinutes)
        thinking = changed(preset.thinking, base.thinking)
        autoOpenPages = changed(preset.autoOpenPages, base.autoOpenPages)
        nudges = changed(preset.nudges, base.nudges)
        rewriteAnswers = changed(preset.rewriteAnswers, base.rewriteAnswers)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxSteps = try? container.decodeIfPresent(Int.self, forKey: .maxSteps)
        minimumPages = try? container.decodeIfPresent(Int.self, forKey: .minimumPages)
        searchResults = try? container.decodeIfPresent(Int.self, forKey: .searchResults)
        toolCallsPerStep = try? container.decodeIfPresent(Int.self, forKey: .toolCallsPerStep)
        pageCharacters = try? container.decodeIfPresent(Int.self, forKey: .pageCharacters)
        tokensPerStep = try? container.decodeIfPresent(Int.self, forKey: .tokensPerStep)
        tokensPerStepWithThinking = try? container.decodeIfPresent(
            Int.self, forKey: .tokensPerStepWithThinking)
        stepLimitMinutes = try? container.decodeIfPresent(Int.self, forKey: .stepLimitMinutes)
        thinkingLimitMinutes = try? container.decodeIfPresent(
            Int.self, forKey: .thinkingLimitMinutes)
        thinking = try? container.decodeIfPresent(ResearchThinkingMode.self, forKey: .thinking)
        autoOpenPages = try? container.decodeIfPresent(Bool.self, forKey: .autoOpenPages)
        nudges = try? container.decodeIfPresent(Bool.self, forKey: .nudges)
        rewriteAnswers = try? container.decodeIfPresent(Bool.self, forKey: .rewriteAnswers)
    }

    /// `base` with these values put over it.
    func applied(to base: ResearchPreset) -> ResearchPreset {
        var preset = base
        if let maxSteps { preset.maxSteps = maxSteps }
        if let minimumPages { preset.minimumPages = minimumPages }
        if let searchResults { preset.searchResults = searchResults }
        if let toolCallsPerStep { preset.toolCallsPerStep = toolCallsPerStep }
        if let pageCharacters { preset.pageCharacters = pageCharacters }
        if let tokensPerStep { preset.tokensPerStep = tokensPerStep }
        if let tokensPerStepWithThinking {
            preset.tokensPerStepWithThinking = tokensPerStepWithThinking
        }
        if let stepLimitMinutes { preset.stepLimitMinutes = stepLimitMinutes }
        if let thinkingLimitMinutes { preset.thinkingLimitMinutes = thinkingLimitMinutes }
        if let thinking { preset.thinking = thinking }
        if let autoOpenPages { preset.autoOpenPages = autoOpenPages }
        if let nudges { preset.nudges = nudges }
        if let rewriteAnswers { preset.rewriteAnswers = rewriteAnswers }
        return preset
    }

    var isEmpty: Bool { self == ResearchPresetChanges() }
}

/// The two presets as the person has set them, kept between launches.
@MainActor @Observable
public final class ResearchPresetStore {
    static let key = "ResearchPresets"
    static let budgetKey = "ResearchLlamaPromptBudget"
    /// The format of what `key` holds.
    static let version = 1

    private struct Stored: Codable {
        var version: Int?
        var quick: ResearchPresetChanges?
        var thorough: ResearchPresetChanges?
    }

    /// The two presets can be edited in place (Settings binds to them); a
    /// change is clamped and saved at once.
    public var quick: ResearchPreset {
        didSet { settle(quick, as: .quick) }
    }
    public var thorough: ResearchPreset {
        didSet { settle(thorough, as: .thorough) }
    }
    /// Prompt budget in characters for a llama.cpp server that does not say
    /// how large its context window is; nil takes the small safe default.
    public var llamaPromptBudget: Int? {
        didSet { settleBudget() }
    }
    private let defaults: any ResearchSettingsStore

    public init(defaults: any ResearchSettingsStore) {
        self.defaults = defaults
        var quick = ResearchPreset.quick
        var thorough = ResearchPreset.thorough
        if let text = defaults.savedString(forKey: Self.key),
           let stored = try? JSONDecoder().decode(Stored.self, from: Data(text.utf8)) {
            quick = (stored.quick?.applied(to: .quick) ?? .quick).clamped()
            thorough = (stored.thorough?.applied(to: .thorough) ?? .thorough).clamped()
        }
        self.quick = quick
        self.thorough = thorough
        llamaPromptBudget = defaults.savedString(forKey: Self.budgetKey).flatMap { Int($0) }
            .map { $0.limited(to: ResearchOptions.contextCharactersRange) }
    }

    public func preset(_ id: ResearchPresetID) -> ResearchPreset {
        switch id {
        case .quick: quick
        case .thorough: thorough
        }
    }

    /// Changes one preset; the result is clamped and saved.
    public func update(_ id: ResearchPresetID, _ change: (inout ResearchPreset) -> Void) {
        var value = preset(id)
        change(&value)
        switch id {
        case .quick: quick = value
        case .thorough: thorough = value
        }
    }

    /// Puts one preset back to its default values.
    public func reset(_ id: ResearchPresetID) {
        update(id) { $0 = .defaults(for: id) }
    }

    /// Runs after a preset was set: puts its numbers inside their ranges
    /// (that assignment runs this once more, which then changes nothing), then
    /// saves.
    private func settle(_ value: ResearchPreset, as id: ResearchPresetID) {
        let limited = value.clamped()
        if limited != value {
            switch id {
            case .quick: quick = limited
            case .thorough: thorough = limited
            }
        }
        save()
    }

    private func settleBudget() {
        let limited = llamaPromptBudget.map {
            $0.limited(to: ResearchOptions.contextCharactersRange)
        }
        if limited != llamaPromptBudget {
            llamaPromptBudget = limited
            return
        }
        defaults.save(limited.map(String.init) ?? "", forKey: Self.budgetKey)
    }

    /// Writes only what differs from the defaults.
    private func save() {
        let quickChanges = ResearchPresetChanges(quick, comparedTo: .quick)
        let thoroughChanges = ResearchPresetChanges(thorough, comparedTo: .thorough)
        let stored = Stored(
            version: Self.version,
            quick: quickChanges.isEmpty ? nil : quickChanges,
            thorough: thoroughChanges.isEmpty ? nil : thoroughChanges)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        defaults.save(String(decoding: data, as: UTF8.self), forKey: Self.key)
    }
}
