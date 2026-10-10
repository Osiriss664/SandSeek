import Foundation

/// The model families the research loop has rules for. Only Gemma 4 differs
/// today: it is the one family that does not keep its reasoning in the
/// history (see `ResearchChatClient.keepsReasoning`).
public enum ResearchModelFamily: String, Equatable, Sendable {
    case gemma4
    case qwen36
    case gptOss = "gpt-oss"
    case minimaxM2 = "minimax-m2"
    case qwen4Exp = "qwen4-exp"
}

/// One model TUFF ships, with the names a user may type and the family it
/// belongs to. Copied from TUFF's model catalog (selector, aliases, API model
/// id and family only); a model that is not listed here is treated by the
/// name-based rules in `ResearchChatClient.keepsReasoning`.
public struct ResearchKnownModel: Equatable, Sendable {
    /// The short name `--model` takes, such as `qwen36`.
    public let selector: String
    public let aliases: [String]
    /// The id the server lists in `/v1/models`.
    public let apiModelID: String
    public let family: ResearchModelFamily

    public init(selector: String,
                aliases: [String] = [],
                apiModelID: String,
                family: ResearchModelFamily) {
        self.selector = selector
        self.aliases = aliases
        self.apiModelID = apiModelID
        self.family = family
    }
}

/// The table of known models, in the order TUFF's catalog lists them (the
/// first match wins).
public enum ResearchModelTable {
    public static let all: [ResearchKnownModel] = [
        ResearchKnownModel(
            selector: "gemma4-e2b", aliases: ["e2b"],
            apiModelID: "gemma-4-e2b-it", family: .gemma4),
        ResearchKnownModel(
            selector: "gemma4-e4b", aliases: ["e4b"],
            apiModelID: "gemma-4-e4b-it", family: .gemma4),
        ResearchKnownModel(
            selector: "gemma4-12b-qat", aliases: ["12b", "12b-qat"],
            apiModelID: "gemma-4-12b-it-qat", family: .gemma4),
        ResearchKnownModel(
            selector: "gemma4",
            apiModelID: "gemma-4-26b-a4b-it", family: .gemma4),
        ResearchKnownModel(
            selector: "qwen36",
            apiModelID: "qwen3.6-35b-a3b", family: .qwen36),
        ResearchKnownModel(
            selector: "gpt-oss-20b", aliases: ["gpt-oss"],
            apiModelID: "gpt-oss-20b", family: .gptOss),
        ResearchKnownModel(
            selector: "gpt-oss-120b",
            apiModelID: "gpt-oss-120b", family: .gptOss),
        ResearchKnownModel(
            selector: "minimax-m2.7", aliases: ["minimax", "m2.7"],
            apiModelID: "minimax-m2.7", family: .minimaxM2),
        ResearchKnownModel(
            selector: "qwen38-flash-next", aliases: ["flash-next", "qwen-flash"],
            apiModelID: "qwen3.8-flash-next", family: .qwen4Exp),
    ]

    /// The first known model whose selector, API model id or alias equals
    /// `name`, ignoring case.
    public static func model(matching name: String) -> ResearchKnownModel? {
        let lowered = name.lowercased()
        return all.first {
            $0.selector.lowercased() == lowered || $0.apiModelID.lowercased() == lowered
                || $0.aliases.contains { $0.lowercased() == lowered }
        }
    }

    /// The API model ids of the models whose selector is exactly `selector`
    /// (case-sensitive, like the server's own lookup).
    public static func apiModelIDs(forSelector selector: String) -> [String] {
        all.filter { $0.selector == selector }.map(\.apiModelID)
    }
}
