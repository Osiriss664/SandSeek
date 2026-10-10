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

/// The values behind one of the two presets. Everything here can be changed
/// in Settings, within the ranges the command line accepts. The limits that
/// protect the Mac (the two tools, the sandbox's firewall, fetch limits and
/// the check before every question) are not here: they are fixed.
public struct ResearchPreset: Codable, Equatable, Sendable {
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
    /// Tokens per step with thinking off.
    public var tokensPerStep: Int
    /// Tokens per step with thinking on (reasoning shares the limit).
    public var tokensPerStepWithThinking: Int
    /// Minutes one step may take before it is asked again.
    public var stepLimitMinutes: Int
    /// Minutes a step with thinking on may take before thinking is turned off.
    public var thinkingLimitMinutes: Int
    /// Whether the model thinks (and the thinking is shown with the progress).
    public var thinking: Bool
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
                thinking: Bool, autoOpenPages: Bool = true, nudges: Bool = true,
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
    /// (8 steps, 3 pages at least, 5 results per search), thinking off.
    public static let quick = ResearchPreset(
        maxSteps: 8, minimumPages: 3, searchResults: 5, thinking: false)

    /// The default thorough preset: 30 steps, 10 pages at least, 8 results per
    /// search, thinking on.
    ///
    /// NOT TESTED YET. These values come from the app mockup. They are
    /// measured in Abschnitt 2c (a run on TUFF with Qwen and thinking, and one
    /// on llama.cpp) and fixed afterwards.
    public static let thorough = ResearchPreset(
        maxSteps: 30, minimumPages: 10, searchResults: 8, thinking: true)

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
            showThinking: preset.thinking,
            maxSteps: preset.maxSteps,
            pageCharacters: preset.pageCharacters,
            thinking: preset.thinking,
            maxTokensLimit: preset.thinking ? preset.tokensPerStepWithThinking : preset.tokensPerStep,
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

/// The two presets as the person has set them, kept between launches.
@MainActor @Observable
public final class ResearchPresetStore {
    static let key = "ResearchPresets"

    private struct Stored: Codable {
        var quick: ResearchPreset
        var thorough: ResearchPreset
    }

    /// The two presets can be edited in place (Settings binds to them); a
    /// change is clamped and saved at once.
    public var quick: ResearchPreset {
        didSet { settle(quick, as: .quick) }
    }
    public var thorough: ResearchPreset {
        didSet { settle(thorough, as: .thorough) }
    }
    private let defaults: any ResearchSettingsStore

    public init(defaults: any ResearchSettingsStore) {
        self.defaults = defaults
        if let text = defaults.savedString(forKey: Self.key),
           let stored = try? JSONDecoder().decode(Stored.self, from: Data(text.utf8)) {
            quick = stored.quick.clamped()
            thorough = stored.thorough.clamped()
        } else {
            quick = .quick
            thorough = .thorough
        }
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

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Stored(quick: quick, thorough: thorough)) else { return }
        defaults.save(String(decoding: data, as: UTF8.self), forKey: Self.key)
    }
}
