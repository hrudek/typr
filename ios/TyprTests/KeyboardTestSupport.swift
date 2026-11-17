import Foundation
@testable import Typr

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

nonisolated enum EvaluationSample {
    #if TYPR_RESEARCH
    static let isFull = true
    #else
    static let isFull = false
    #endif

    static func includes(_ index: Int, every stride: Int) -> Bool { isFull || index % stride == 0 }
}

@MainActor
extension FullKeyboardEngine {
    func acceptOwnedFixtureSuggestion(_ suggestion: KeyboardSuggestion) {
        var owned = suggestion
        owned.ownership = suggestionOwnership
        acceptSuggestion(owned)
    }
}
