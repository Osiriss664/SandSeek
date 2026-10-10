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
        // Thinking is left to the server, as the command does by default.
        #expect(quick.thinking == .serverDefault)

        let options = ResearchOptions()
        #expect(quick.maxSteps == options.maxSteps)
        #expect(quick.minimumPages == options.minimumPagesRead)
        #expect(quick.searchResults == options.searchResults)
        #expect(quick.toolCallsPerStep == options.maxToolCallsPerTurn)
    }

    @Test func theThoroughPresetHasTheMockupsValuesExceptForThePageCount() {
        let thorough = ResearchPreset.thorough
        #expect(thorough.maxSteps == 30)
        // The mockup said 10; 6 is what the top-up that opens results can reach.
        #expect(thorough.minimumPages == 6)
        #expect(thorough.searchResults == 8)
        #expect(thorough.toolCallsPerStep == 4)
        #expect(thorough.pageCharacters == 3_000)
        #expect(thorough.tokensPerStep == 2_048)
        #expect(thorough.tokensPerStepWithThinking == 8_192)
        #expect(thorough.stepLimitMinutes == 30)
        #expect(thorough.thinkingLimitMinutes == 3)
        #expect(thorough.autoOpenPages && thorough.nudges && thorough.rewriteAnswers)
        #expect(thorough.thinking == .serverDefault)
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
        // No thinking field is sent: neither true nor false.
        #expect(quick.enableThinking == nil)
        #expect(quick.maxTokens == 2_048)
        #expect(quick.stepTimeout == 1_800)

        let thorough = ResearchPreset.thorough.runSettings(model: "m")
        #expect(thorough.options.maxSteps == 30)
        #expect(thorough.options.minimumPagesRead == 6)
        #expect(thorough.options.searchResults == 8)
        #expect(thorough.enableThinking == nil)
        #expect(thorough.maxTokens == 2_048)
        #expect(thorough.stepTimeout == 1_800)

        // Thinking turned on in Settings is sent, with its own token limit.
        var on = ResearchPreset.thorough
        on.thinking = .on
        #expect(on.runSettings(model: "m").enableThinking == true)
        #expect(on.runSettings(model: "m").maxTokens == 8_192)
        on.thinking = .off
        #expect(on.runSettings(model: "m").enableThinking == false)
        #expect(on.runSettings(model: "m").maxTokens == 2_048)
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

        store.update(.thorough) { $0.maxSteps = 12; $0.thinking = .off }
        store.update(.quick) { $0.searchResults = 7 }
        #expect(store.preset(.thorough).maxSteps == 12)

        let reopened = ResearchPresetStore(defaults: settings)
        #expect(reopened.thorough.maxSteps == 12)
        #expect(reopened.thorough.thinking == .off)
        #expect(reopened.quick.searchResults == 7)
        // The other values of each stay at their defaults.
        #expect(reopened.thorough.minimumPages == 6)
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

    @Test func onlyValuesThatDifferFromTheDefaultsAreStored() throws {
        let settings = MemorySettings()
        let store = ResearchPresetStore(defaults: settings)
        store.update(.quick) { $0.searchResults = 7 }
        let text = try #require(settings.savedString(forKey: ResearchPresetStore.key))
        let stored = try #require(try JSONSerialization.jsonObject(
            with: Data(text.utf8)) as? [String: Any])
        #expect(stored["version"] as? Int == 1)
        #expect(stored["thorough"] == nil)
        let quick = try #require(stored["quick"] as? [String: Any])
        #expect(quick.keys.sorted() == ["searchResults"])
        #expect(quick["searchResults"] as? Int == 7)

        // Back to the defaults: nothing differs, so nothing is stored.
        store.reset(.quick)
        let after = try #require(settings.savedString(forKey: ResearchPresetStore.key))
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(after.utf8)) as? [String: Any])
        #expect(object["quick"] == nil && object["thorough"] == nil)
    }

    @Test func aChangedDefaultReachesEveryoneWhoDidNotChangeThatValue() {
        // A stored preset that touched one value only, from an older version
        // that did not know most fields (and one that it knew and we dropped).
        let settings = MemorySettings()
        settings.save(
            #"{"version":0,"quick":{"nudges":false,"oldField":5},"thorough":{"maxSteps":12}}"#,
            forKey: ResearchPresetStore.key)
        let store = ResearchPresetStore(defaults: settings)
        #expect(!store.quick.nudges)
        #expect(store.quick.maxSteps == ResearchPreset.quick.maxSteps)
        #expect(store.thorough.maxSteps == 12)
        // Every other Thorough value is the current default.
        var expected = ResearchPreset.thorough
        expected.maxSteps = 12
        #expect(store.thorough == expected)
    }

    @Test func aValueThatCannotBeReadFallsBackToItsDefaultAndKeepsTheRest() {
        let settings = MemorySettings()
        settings.save(
            #"{"quick":{"maxSteps":"many","thinking":"sometimes","nudges":false}}"#,
            forKey: ResearchPresetStore.key)
        let store = ResearchPresetStore(defaults: settings)
        #expect(store.quick.maxSteps == ResearchPreset.quick.maxSteps)
        #expect(store.quick.thinking == .serverDefault)
        #expect(!store.quick.nudges)
    }

    @Test func thePromptBudgetIsKeptAndClamped() {
        let settings = MemorySettings()
        let store = ResearchPresetStore(defaults: settings)
        #expect(store.llamaPromptBudget == nil)
        store.llamaPromptBudget = 32_000
        #expect(ResearchPresetStore(defaults: settings).llamaPromptBudget == 32_000)
        store.llamaPromptBudget = 5
        #expect(store.llamaPromptBudget == ResearchOptions.contextCharactersRange.lowerBound)
        store.llamaPromptBudget = nil
        #expect(ResearchPresetStore(defaults: settings).llamaPromptBudget == nil)
    }

    @Test func theThinkingModesAreNamedForThePicker() {
        #expect(ResearchThinkingMode.allCases == [.serverDefault, .on, .off])
        #expect(ResearchThinkingMode.serverDefault.title == "Server default")
        #expect(ResearchThinkingMode.serverDefault.enabled == nil)
        #expect(ResearchThinkingMode.on.enabled == true)
        #expect(ResearchThinkingMode.off.enabled == false)
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
