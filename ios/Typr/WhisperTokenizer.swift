import Foundation
import WhisperKit

/// The token lookups Typr's Whisper tokenizer needs. WhisperKit's `TokenizerWrapper` provides
/// them; tests use a small dictionary so special-token resolution runs without model files.
protocol WhisperTokenLookup: Sendable {
    func encode(text: String) -> [Int]
    func decode(tokens: [Int]) -> String
    func convertTokenToId(_ token: String) -> Int?
    func convertIdToToken(_ id: Int) -> String?
}

extension TokenizerWrapper: WhisperTokenLookup {}

nonisolated enum WhisperTokenizerError: ModelFileCheckError, Equatable {
    case unresolvedToken(String)

    var errorDescription: String? {
        switch self {
        case .unresolvedToken(let token):
            "The Whisper tokenizer on this iPhone is damaged (missing \(token)). Download Whisper again."
        }
    }
}

/// Typr's `WhisperTokenizer`, because WhisperKit 1.1.1's `WhisperTokenizerWrapper.init` is internal.
/// It mirrors that wrapper's special-token table, with two differences: a token that does not
/// resolve exactly is a local error (upstream silently uses pre-V3 default IDs, off by one for
/// V3's vocabulary, and the BPE lookup returns `<|endoftext|>` for unknown strings), and the
/// whitespace token is the byte-level space `Ġ` (OpenAI's `encode(" ")`, 220), which upstream's
/// `" "` lookup never finds. Word splitting is only used for word timestamps, which Typr disables;
/// it is a minimal, non-crashing split, not upstream's.
final class TyprWhisperTokenizer: WhisperTokenizer, @unchecked Sendable {
    /// Byte-level BPE's visible form of a space.
    static let byteLevelSpace = "\u{0120}"

    private let lookup: any WhisperTokenLookup
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(lookup: any WhisperTokenLookup) throws {
        self.lookup = lookup
        func id(_ token: String) throws -> Int {
            guard let id = lookup.convertTokenToId(token), lookup.convertIdToToken(id) == token else {
                throw WhisperTokenizerError.unresolvedToken(token == Self.byteLevelSpace ? "space" : token)
            }
            return id
        }
        let endToken = try id("<|endoftext|>")
        let specialTokens = SpecialTokens(
            endToken: endToken,
            englishToken: try id("<|en|>"),
            noSpeechToken: try id("<|nospeech|>"),
            noTimestampsToken: try id("<|notimestamps|>"),
            specialTokenBegin: endToken,
            startOfPreviousToken: try id("<|startofprev|>"),
            startOfTranscriptToken: try id("<|startoftranscript|>"),
            timeTokenBegin: try id("<|0.00|>"),
            transcribeToken: try id("<|transcribe|>"),
            translateToken: try id("<|translate|>"),
            whitespaceToken: try id(Self.byteLevelSpace)
        )
        self.specialTokens = specialTokens
        allLanguageTokens = Set(
            Constants.languages.values.compactMap { code -> Int? in
                let token = "<|\(code)|>"
                guard let id = lookup.convertTokenToId(token), lookup.convertIdToToken(id) == token else { return nil }
                return id
            }
            .filter { $0 > specialTokens.specialTokenBegin }
        )
        // Typr dictates German and English; both must be real language tokens.
        for code in ["de", "en"] {
            let token = try id("<|\(code)|>")
            if !allLanguageTokens.contains(token) {
                throw WhisperTokenizerError.unresolvedToken("<|\(code)|>")
            }
        }
    }

    /// Parses `config.json`, `tokenizer.json` and `tokenizer_config.json` from `folder` only.
    /// `AutoTokenizerWrapper.from(modelFolder:)` never downloads; `from(pretrained:)` and
    /// `ModelUtilities.loadTokenizer` can, so Typr never calls them.
    static func load(from folder: URL) async throws -> TyprWhisperTokenizer {
        let wrapper = try await AutoTokenizerWrapper.from(modelFolder: folder)
        return try TyprWhisperTokenizer(lookup: wrapper)
    }

    func encode(text: String) -> [Int] { lookup.encode(text: text) }
    func decode(tokens: [Int]) -> String { lookup.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { lookup.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { lookup.convertIdToToken(id) }

    /// One word per text token, special tokens dropped; never crashes on any input.
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let text = tokenIds.filter { $0 < specialTokens.specialTokenBegin }
        return (text.map { lookup.decode(tokens: [$0]) }, text.map { [$0] })
    }
}

/// Parses the downloaded tokenizer locally (no network) and resolves Whisper's special tokens.
/// Production: `WhisperKitTokenizerChecker` (`TyprWhisperTokenizer.load(from:)`).
protocol WhisperTokenizerChecking: Sendable {
    func check(tokenizerFolder: URL) async throws
}

/// Production tokenizer check for the installer: a full local parse plus special-token resolution.
struct WhisperKitTokenizerChecker: WhisperTokenizerChecking {
    func check(tokenizerFolder: URL) async throws {
        _ = try await TyprWhisperTokenizer.load(from: tokenizerFolder)
    }
}

typealias WhisperModelInstaller = ModelInstaller<WhisperModelSpec>

extension ModelInstaller where Spec == WhisperModelSpec {
    /// Whisper's checked files are its tokenizer.
    convenience init(
        store: WhisperModelStore,
        downloader: any ModelFileDownloading,
        tokenizerChecker: any WhisperTokenizerChecking,
        availableCapacity: (() -> Int64?)? = nil
    ) {
        self.init(store: store, downloader: downloader,
                  checkFiles: { try await tokenizerChecker.check(tokenizerFolder: store.tokenizerFolder) },
                  availableCapacity: availableCapacity)
    }
}
