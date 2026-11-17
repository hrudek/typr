import Foundation
@testable import Typr

/// Bundled keyboard resources, parsed once per test process. Both are immutable value types.
nonisolated enum BundledKeyboardData {
    static let lexicons: [SpatialWordDecoder.Language: SpatialWordLexicon]? = {
        var sources: [SpatialWordDecoder.Language: SpatialWordLexicon] = [:]
        for language in SpatialWordDecoder.Language.allCases {
            guard let url = Bundle.main.url(forResource: "keyboard-\(language.rawValue)",
                                            withExtension: "words", subdirectory: "WordData"),
                  let data = try? Data(contentsOf: url),
                  let lexicon = SpatialWordLexicon(data: data) else { return nil }
            sources[language] = lexicon
        }
        return sources
    }()

    static let contextModel: KeyboardContextModel? = {
        let packs = ["de", "en"].map { lang in
            Bundle.main.url(forResource: "keyboard-\(lang)", withExtension: "tbg", subdirectory: "WordData")
                .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }.flatMap(KeyboardContextModel.Pack.init)
        }
        return KeyboardContextModel(de: packs[0], en: packs[1])
    }()
}

/// Routine simulator runs check every `stride`-th evaluation fixture; the research target
/// (`ios/research.yml`) checks all of them.
nonisolated enum EvaluationSample {
    #if TYPR_RESEARCH
    static let isFull = true
    #else
    static let isFull = false
    #endif

    static func includes(_ index: Int, every stride: Int) -> Bool { isFull || index % stride == 0 }
}

/// Older transaction tests inject explicit strip choices rather than waiting for real dictionary
/// output. Bind those fixture choices to the CURRENT field exactly as a freshly rendered chip is.
@MainActor
extension FullKeyboardEngine {
    func acceptOwnedFixtureSuggestion(_ suggestion: KeyboardSuggestion) {
        var owned = suggestion
        owned.ownership = suggestionOwnership
        acceptSuggestion(owned)
    }
}
