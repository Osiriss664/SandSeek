import Foundation
import Testing
@testable import SandSeekCore

@Suite struct ResearchAPIKeyFileTests {
    private func file(_ text: String) throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandSeekKeyFile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("key")
        try Data(text.utf8).write(to: url)
        return url.path
    }

    @Test func theFileBecomesABearerHeaderValue() throws {
        #expect(try ResearchAPIKeyFile.authorization(atPath: file("abc123\n")) == "Bearer abc123")
        #expect(try ResearchAPIKeyFile.authorization(atPath: file("  abc123  \n\n")) == "Bearer abc123")
    }

    @Test func aMissingEmptyOrOddFileIsRefusedWithoutQuotingTheKey() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandSeekNoSuchKey-\(UUID().uuidString)").path
        #expect(throws: ResearchArgumentError.self) {
            _ = try ResearchAPIKeyFile.authorization(atPath: missing)
        }
        #expect(throws: ResearchArgumentError.self) {
            _ = try ResearchAPIKeyFile.authorization(atPath: file("  \n"))
        }
        #expect(throws: ResearchArgumentError.self) {
            _ = try ResearchAPIKeyFile.authorization(atPath: file(String(repeating: "k", count: 5_000)))
        }
        // Two words, or a control character, would not be one header value.
        let secret = "two words"
        do {
            _ = try ResearchAPIKeyFile.authorization(atPath: file(secret))
            Issue.record("a key with a space was accepted")
        } catch {
            #expect(!String(describing: error).contains(secret))
        }
        #expect(throws: ResearchArgumentError.self) {
            _ = try ResearchAPIKeyFile.authorization(atPath: file("abc\u{7}def"))
        }
    }

    @Test func theOptionIsParsedAndAppearsInTheHelp() throws {
        let parsed = try ResearchArguments.parse(
            ["--server-type", "llamacpp", "--api-key-file", "/tmp/key", "q"], environment: [:])
        #expect(parsed.apiKeyFile == "/tmp/key")
        #expect(try ResearchArguments.parse(["q"], environment: [:]).apiKeyFile == nil)
        #expect(ResearchArguments.usage.contains("--api-key-file"))
        #expect(throws: ResearchArgumentError.self) {
            _ = try ResearchArguments.parse(["q", "--api-key-file"], environment: [:])
        }
        // There is no option that takes the key itself.
        #expect(throws: ResearchArgumentError.self) {
            _ = try ResearchArguments.parse(["q", "--api-key", "secret"], environment: [:])
        }
    }
}
