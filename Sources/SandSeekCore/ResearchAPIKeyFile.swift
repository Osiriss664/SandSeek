import Foundation

/// Reads the key of a model server that asks for one (llama-server started
/// with `--api-key-file`) from a file, so the key never appears on a command
/// line. The key goes into one `Authorization: Bearer` header of requests to
/// the model server, whose address is already limited to this Mac's loopback
/// interface. It is never printed, put into an error message or saved.
public enum ResearchAPIKeyFile {
    /// Longest key file read; a real key is far shorter.
    static let largestFileBytes = 4_096

    /// The `Authorization` header value (`Bearer <key>`) for the key in the
    /// file at `path`. A leading `~` is expanded. The key is the file's text
    /// without the white space around it; it must be printable ASCII with no
    /// white space inside.
    public static func authorization(atPath path: String) throws -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else {
            throw ResearchArgumentError("cannot read the key file \(path)")
        }
        guard data.count <= largestFileBytes else {
            throw ResearchArgumentError("the key file \(path) is too large to be a key")
        }
        let key = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ResearchArgumentError("the key file \(path) is empty")
        }
        guard key.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f }) else {
            throw ResearchArgumentError(
                "the key file \(path) must hold one key of printable characters without spaces")
        }
        return "Bearer " + key
    }
}
