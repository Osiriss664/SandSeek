import Foundation
import Testing
@testable import SandSeekCore

@Suite("Research model family table")
struct ResearchModelFamilyTests {
    @Test func tableHoldsTheNineKnownModelsWithDistinctSelectors() {
        let selectors = ResearchModelTable.all.map(\.selector)
        #expect(selectors.count == 9)
        #expect(Set(selectors).count == selectors.count)
        let apiIDs = ResearchModelTable.all.map(\.apiModelID)
        #expect(Set(apiIDs).count == apiIDs.count)
    }

    @Test func aSelectorFindsTheModelsApiIDWindow() {
        let windows = ["qwen3.6-35b-a3b": 16_384, "gemma-4-26b-a4b-it": 8_192]
        #expect(ResearchModelTable.apiModelIDs(forSelector: "qwen36") == ["qwen3.6-35b-a3b"])
        #expect(ResearchChatClient.window(for: "qwen36", in: windows) == 16_384)
        #expect(ResearchChatClient.window(for: "gemma4", in: windows) == 8_192)
        // The API id itself still works, and so does a name the list holds.
        #expect(ResearchChatClient.window(for: "qwen3.6-35b-a3b", in: windows) == 16_384)
        // The lookup by selector is exact: an alias or another case is not a selector.
        #expect(ResearchModelTable.apiModelIDs(forSelector: "Qwen36").isEmpty)
        #expect(ResearchModelTable.apiModelIDs(forSelector: "e2b").isEmpty)
        // An unknown name gets the smallest window, or nil when the list is empty.
        #expect(ResearchChatClient.window(for: "default", in: windows) == 8_192)
        #expect(ResearchChatClient.window(for: "qwen36", in: [:]) == nil)
    }

    @Test func gemmaModelsDoNotKeepReasoning() {
        for name in ["gemma4", "gemma4-e2b", "e2b", "gemma4-e4b", "e4b", "gemma4-12b-qat", "12b",
                     "12b-qat", "gemma-4-e2b-it", "gemma-4-e4b-it", "gemma-4-12b-it-qat",
                     "gemma-4-26b-a4b-it", "GEMMA4", "Gemma-4-E2B-IT"] {
            #expect(!ResearchChatClient.keepsReasoning(modelID: name), "\(name)")
        }
        // Names the table does not list fall back to the name rule.
        #expect(!ResearchChatClient.keepsReasoning(modelID: "gemma4-26b-a4b"))
        #expect(!ResearchChatClient.keepsReasoning(modelID: "my-gemma-build"))
    }

    @Test func unknownModelsKeepReasoning() {
        #expect(ResearchChatClient.keepsReasoning(modelID: nil))
        #expect(ResearchChatClient.keepsReasoning(modelID: ""))
        #expect(ResearchChatClient.keepsReasoning(modelID: "default"))
        #expect(ResearchChatClient.keepsReasoning(modelID: "something-else"))
        #expect(ResearchChatClient.keepsReasoning(modelID: "bonsai-8b"))
    }

    @Test func gptOssQwenAndMiniMaxKeepReasoning() {
        for name in ["gpt-oss", "gpt-oss-20b", "gpt-oss-120b", "GPT-OSS-20B", "qwen36",
                     "qwen3.6-35b-a3b", "qwen38-flash-next", "flash-next", "qwen-flash",
                     "qwen3.8-flash-next", "minimax", "m2.7", "minimax-m2.7", "Qwen3-X"] {
            #expect(ResearchChatClient.keepsReasoning(modelID: name), "\(name)")
        }
    }

    @Test func everyTableEntryAnswersByItsFamily() {
        for known in ResearchModelTable.all {
            let expected = known.family != .gemma4
            let names = [known.selector, known.apiModelID] + known.aliases
            for name in names {
                #expect(ResearchChatClient.keepsReasoning(modelID: name) == expected, "\(name)")
                #expect(ResearchChatClient.keepsReasoning(modelID: name.uppercased()) == expected,
                        "\(name)")
                #expect(ResearchModelTable.model(matching: name)?.apiModelID == known.apiModelID,
                        "\(name)")
            }
            #expect(ResearchChatClient.window(for: known.selector, in: [known.apiModelID: 1_234])
                    == 1_234, "\(known.selector)")
        }
    }

    @Test func familiesOfTheNamedModels() {
        #expect(ResearchModelTable.model(matching: "qwen36")?.family == .qwen36)
        #expect(ResearchModelTable.model(matching: "gpt-oss")?.family == .gptOss)
        #expect(ResearchModelTable.model(matching: "minimax")?.family == .minimaxM2)
        #expect(ResearchModelTable.model(matching: "flash-next")?.family == .qwen4Exp)
        #expect(ResearchModelTable.model(matching: "gemma4")?.family == .gemma4)
        #expect(ResearchModelTable.model(matching: "default") == nil)
    }
}
