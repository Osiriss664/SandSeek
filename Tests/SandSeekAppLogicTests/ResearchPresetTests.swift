import Foundation
import Testing
@testable import SandSeekAppLogic
@testable import SandSeekCore

@Suite @MainActor struct ResearchPresetTests {
    @Test func theQuickPresetIsTheLoopsDefaults() {
        let quick = ResearchPreset.quick
        #expect(quick.maxSteps == 8)
        #expect(quick.minimumPages == 3)
        #expect(quick.searchResults == 5)
        #expect(quick.toolCallsPerStep == 4)
        #expect(quick.pageCharacters == 3_000)
        #expect(quick.tokensPerStep == 2_048)
        #expect(quick.tokensPerStepWithThinking == 8_192)
        #expect(quick.stepLimitMinutes == 30)
        #expect(quick.thinkingLimitMinutes == 3)
        #expect(quick.autoOpenPages && quick.nudges && quick.rewriteAnswers)
        #expect(!quick.thinking)

        let options = ResearchOptions()
        #expect(quick.maxSteps == options.maxSteps)
        #expect(quick.minimumPages == options.minimumPagesRead)
        #expect(quick.searchResults == options.searchResults)
        #expect(quick.toolCallsPerStep == options.maxToolCallsPerTurn)
    }

    @Test func theThoroughPresetHasTheMockupsValues() {
        let thorough = ResearchPreset.thorough
        #expect(thorough.maxSteps == 30)
        #expect(thorough.minimumPages == 10)
        #expect(thorough.searchResults == 8)
        #expect(thorough.toolCallsPerStep == 4)
        #expect(thorough.pageCharacters == 3_000)
        #expect(thorough.tokensPerStep == 2_048)
        #expect(thorough.tokensPerStepWithThinking == 8_192)
        #expect(thorough.stepLimitMinutes == 30)
        #expect(thorough.thinkingLimitMinutes == 3)
        #expect(thorough.autoOpenPages && thorough.nudges && thorough.rewriteAnswers)
        #expect(thorough.thinking)
        // Every default is inside the ranges, so none is changed by clamping.
        #expect(thorough.clamped() == thorough)
        #expect(ResearchPreset.quick.clamped() == ResearchPreset.quick)
    }

    @Test func aPresetBecomesRunSettingsWithoutLosingValues() {
        let quick = ResearchPreset.quick.runSettings(model: "m")
        #expect(quick.model == "m")
        #expect(quick.options.maxSteps == 8)
        #expect(quick.options.minimumPagesRead == 3)
        #expect(quick.options.searchResults == 5)
        #expect(quick.options.maxToolCallsPerTurn == 4)
        #expect(quick.options.pageSliceCharacters == 3_000)
        #expect(quick.options.autoOpenPages && quick.options.nudges)
        #expect(quick.options.reviseUnreadCitations)
        #expect(quick.options.thinkingMinutes == 3)
        #expect(quick.enableThinking == false)
        #expect(quick.maxTokens == 2_048)
        #expect(quick.stepTimeout == 1_800)

        let thorough = ResearchPreset.thorough.runSettings(model: "m")
        #expect(thorough.options.maxSteps == 30)
        // Ten pages: the range was widened for this, not clamped to six.
        #expect(thorough.options.minimumPagesRead == 10)
        #expect(thorough.options.searchResults == 8)
        #expect(thorough.enableThinking == true)
        #expect(thorough.showThinking)
        #expect(thorough.maxTokens == 8_192)
        #expect(thorough.stepTimeout == 1_800)
    }

    @Test func valuesOutsideTheRangesAreClamped() {
        var wild = ResearchPreset.quick
        wild.maxSteps = 500
        wild.minimumPages = 99
        wild.searchResults = 0
        wild.toolCallsPerStep = 50
        wild.pageCharacters = 10
        wild.tokensPerStep = 1
        wild.tokensPerStepWithThinking = 1_000_000
        wild.stepLimitMinutes = 0
        wild.thinkingLimitMinutes = 500
        let clamped = wild.clamped()
        #expect(clamped.maxSteps == 100)
        #expect(clamped.minimumPages == 12)
        #expect(clamped.searchResults == 1)
        #expect(clamped.toolCallsPerStep == 8)
        #expect(clamped.pageCharacters == 500)
        #expect(clamped.tokensPerStep == 64)
        #expect(clamped.tokensPerStepWithThinking == 32_768)
        #expect(clamped.stepLimitMinutes == 1)
        #expect(clamped.thinkingLimitMinutes == 60)
    }

    @Test func editedPresetsAreKeptAndCanBeReset() {
        let settings = MemorySettings()
        let store = ResearchPresetStore(defaults: settings)
        #expect(store.quick == .quick)
        #expect(store.thorough == .thorough)

        store.update(.thorough) { $0.maxSteps = 12; $0.thinking = false }
        store.update(.quick) { $0.searchResults = 7 }
        #expect(store.preset(.thorough).maxSteps == 12)

        let reopened = ResearchPresetStore(defaults: settings)
        #expect(reopened.thorough.maxSteps == 12)
        #expect(!reopened.thorough.thinking)
        #expect(reopened.quick.searchResults == 7)
        // The other values of each stay at their defaults.
        #expect(reopened.thorough.minimumPages == 10)
        #expect(reopened.quick.maxSteps == 8)

        reopened.reset(.thorough)
        #expect(reopened.thorough == .thorough)
        #expect(ResearchPresetStore(defaults: settings).thorough == .thorough)
        #expect(ResearchPresetStore(defaults: settings).quick.searchResults == 7)
    }

    @Test func aTypedValueIsClampedBeforeItIsSaved() {
        let settings = MemorySettings()
        let store = ResearchPresetStore(defaults: settings)
        store.update(.quick) { $0.maxSteps = 5_000 }
        #expect(store.quick.maxSteps == 100)
        #expect(ResearchPresetStore(defaults: settings).quick.maxSteps == 100)
    }

    @Test func settingAPresetDirectlyClampsAndSavesLikeSettingsDoes() {
        let settings = MemorySettings()
        let store = ResearchPresetStore(defaults: settings)
        // Settings binds to the properties themselves.
        store.thorough.minimumPages = 40
        store.thorough.toolCallsPerStep = 6
        #expect(store.thorough.minimumPages == 12)
        let reopened = ResearchPresetStore(defaults: settings)
        #expect(reopened.thorough.minimumPages == 12)
        #expect(reopened.thorough.toolCallsPerStep == 6)
        #expect(reopened.quick == .quick)
    }

    @Test func unreadableStoredPresetsFallBackToTheDefaults() {
        let settings = MemorySettings()
        settings.save("{not json", forKey: ResearchPresetStore.key)
        let store = ResearchPresetStore(defaults: settings)
        #expect(store.quick == .quick)
        #expect(store.thorough == .thorough)
    }

    @Test func thePresetsAreNamedForThePicker() {
        #expect(ResearchPresetID.allCases == [.quick, .thorough])
        #expect(ResearchPresetID.quick.title == "Quick answer")
        #expect(ResearchPresetID.thorough.title == "Thorough")
        #expect(ResearchPreset.defaults(for: .quick) == .quick)
        #expect(ResearchPreset.defaults(for: .thorough) == .thorough)
    }
}
