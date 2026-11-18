import XCTest
@testable import Typr

/// Synthetic sentences modelled on misrecognitions seen in dictation logs (never real transcripts).
final class TechGlossaryTests: XCTestCase {
    private func fix(_ text: String, protectedKeys: Set<String> = []) -> String {
        TechGlossary.apply(to: text, protectedKeys: protectedKeys).text
    }

    func testUnambiguousGitFormsAreAlwaysFixed() {
        XCTAssertEqual(fix("Erstelle einen Pulrequest"), "Erstelle einen Pull Request")
        XCTAssertEqual(fix("starte ein Pulrigquest und warte"), "starte ein Pull Request und warte")
        XCTAssertEqual(fix("bis der Pul Request fertig ist"), "bis der Pull Request fertig ist")
        XCTAssertEqual(fix("zwei Pulrequests offen"), "zwei Pull Requests offen")
        XCTAssertEqual(fix("bis er gemerd ist"), "bis er gemergt ist")
        XCTAssertEqual(fix("wurde gemerge"), "wurde gemergt")
        XCTAssertEqual(fix("Lösche die Gitub-Bots"), "Lösche die GitHub-Bots")
        XCTAssertEqual(fix("sortiert nach Git-Hub Stars"), "sortiert nach GitHub Stars")
        XCTAssertEqual(fix("auf github"), "auf GitHub")
    }

    func testAgentAndPromptFormsAreFixed() {
        XCTAssertEqual(fix("ein Agent als Orcherator"), "ein Agent als Orchestrator")
        XCTAssertEqual(fix("ein neues Featureflag"), "ein neues Feature Flag")
        XCTAssertEqual(fix("falls der Reviewercom fixe es"), "falls der Reviewer kommt fixe es")
        XCTAssertEqual(fix("vom ReviewAgenten"), "vom Review Agenten")
        XCTAssertEqual(fix("schreib den Promt neu"), "schreib den Prompt neu")
        XCTAssertEqual(fix("nur Beach to Text Apps"), "nur Speech to Text Apps")
    }

    func testPiOnlyDirectlyBeforeAgent() {
        XCTAssertEqual(fix("starte dort einen Pay Agenten"), "starte dort einen pi Agenten")
        XCTAssertEqual(fix("einen weiteren Pay-Agenten"), "einen weiteren pi Agenten")
        XCTAssertEqual(fix("starte dort ein paar Agenten"), "starte dort ein pi Agenten")
        XCTAssertEqual(fix("ein paar Agent mit GPT"), "ein pi Agent mit GPT")
        // "paar" and "Pay" elsewhere stay as they are.
        XCTAssertEqual(fix("ein paar Minuten"), "ein paar Minuten")
        XCTAssertEqual(fix("Pay the bill"), "Pay the bill")
    }

    func testHerdrPaneAsAPhraseAndWithContext() {
        XCTAssertEqual(fix("Öffne eine Hurder Pain"), "Öffne eine herdr pane")
        XCTAssertEqual(fix("in einer neuen Herda Pain"), "in einer neuen herdr pane")
        XCTAssertEqual(fix("in einer Herder-Pain"), "in einer herdr pane")
        XCTAssertEqual(fix("Öffne eine neue Hda Pain"), "Öffne eine neue herdr pane")
        // A lone "Herder" becomes herdr only when the dictation is about panes/agents/tabs.
        XCTAssertEqual(fix("öffne einen Pay Agenten in einem Herder. Nein, besser eine Herda Payne"),
                       "öffne einen pi Agenten in einem herdr. Nein, besser eine herdr pane")
        XCTAssertEqual(fix("Wir lesen heute Herder im Unterricht"), "Wir lesen heute Herder im Unterricht")
        XCTAssertEqual(fix("Das macht mir Pain"), "Das macht mir Pain")
        XCTAssertEqual(fix("Teile das Terminal, die rechte Pain bleibt"), "Teile das Terminal, die rechte pane bleibt")
    }

    func testTyprMisheardFormsAreFixed() {
        for form in ["Typa", "Taipa", "Teipa", "Typar", "Taiper", "Teiper", "Tiper"] {
            XCTAssertEqual(fix("Öffne \(form) und diktiere"), "Öffne Typr und diktiere", form)
        }
        XCTAssertEqual(fix("die typa-Tastatur"), "die Typr-Tastatur")
        XCTAssertEqual(fix("Typa's settings"), "Typr's settings")
    }

    func testTyprRealWordsNeedContext() {
        XCTAssertEqual(fix("Er ist ein schneller Typer"), "Er ist ein schneller Typer")
        XCTAssertEqual(fix("Teste die Typer App"), "Teste die Typr App")
        XCTAssertEqual(fix("Öffne Typa. Der Typer zeigt das Keyboard"), "Öffne Typr. Der Typr zeigt das Keyboard")
        XCTAssertEqual(fix("Der Tipper aus Taipei mag den Typ"), "Der Tipper aus Taipei mag den Typ")
        XCTAssertEqual(fix("Type A in die Typ A App"), "Type A in die Typ A App")
    }

    func testGemerktNeedsAGitContext() {
        XCTAssertEqual(fix("Ich habe mir das gemerkt"), "Ich habe mir das gemerkt")
        XCTAssertEqual(fix("Der PR ist gemerkt"), "Der PR ist gemergt")
        XCTAssertEqual(fix("bis der Pul Request gemerkt ist"), "bis der Pull Request gemergt ist")
        XCTAssertEqual(fix("Der Branch wurde gemerkt"), "Der Branch wurde gemergt")
        XCTAssertEqual(fix("Wir essen Brunch"), "Wir essen Brunch")
        XCTAssertEqual(fix("Lege einen Brunch für den Commit an"), "Lege einen Branch für den Commit an")
    }

    func testUserTermsAndFormsAreProtected() {
        // A user who writes "Pullrequest" on purpose keeps it.
        XCTAssertEqual(fix("Ein Pullrequest", protectedKeys: ["pullrequest"]), "Ein Pullrequest")
        XCTAssertEqual(fix("Ein Pullrequest"), "Ein Pull Request")
    }

    func testReportsReplacementsAndRelevantTerms() {
        var changes: [String] = []
        let result = TechGlossary.apply(to: "Erstelle einen Pulrequest auf Gitub und schau, ob der PR gemerkt ist") { before, after, _ in
            changes.append("\(before)→\(after)")
        }
        XCTAssertEqual(result.text, "Erstelle einen Pull Request auf GitHub und schau, ob der PR gemergt ist")
        XCTAssertEqual(changes, ["Pulrequest→Pull Request", "Gitub→GitHub", "gemerkt→gemergt"])
        XCTAssertEqual(result.terms, ["Pull Request", "PR", "GitHub", "gemergt"])
        // Unlisted phrase fixes are not named to cleanup; their parts are.
        XCTAssertEqual(TechGlossary.apply(to: "Öffne eine Hurder Pain").terms, ["herdr", "pane"])
        XCTAssertEqual(TechGlossary.apply(to: "Ein ganz normaler Satz").terms, [])
    }

    func testListedTermsAreUniqueAndWithinTheHintLimit() {
        let keys = TechGlossary.listedTerms.map(VocabularySpelling.normalizedKey)
        XCTAssertEqual(keys.count, Set(keys).count)
        XCTAssertLessThan(keys.count, DictationVocabulary.maxSpeechHints / 2)
        XCTAssertTrue(TechGlossary.listedTerms.contains("Pull Request"))
        XCTAssertFalse(TechGlossary.listedTerms.contains("Reviewer kommt"))
    }

    /// Every form maps to exactly one spelling: two entries never claim the same misheard form.
    func testNoFormIsClaimedByTwoTerms() {
        var owner: [String: String] = [:]
        for entry in TechGlossary.entries {
            for form in entry.heardAs + entry.heardInContext {
                let key = VocabularySpelling.normalizedKey(form)
                if let other = owner[key] {
                    XCTAssertEqual(other, entry.term, "\(form) is claimed by \(other) and \(entry.term)")
                }
                owner[key] = entry.term
            }
        }
    }
}

final class DictationVocabularyTests: XCTestCase {
    func testUserTermsComeFirstInSpeechHintsAndAreCapped() {
        let vocabulary = DictationVocabulary(userTerms: ["herdr", "GitHub", "Rudek"])
        let hints = vocabulary.speechHints
        XCTAssertEqual(Array(hints.prefix(3)), ["herdr", "GitHub", "Rudek"])
        XCTAssertEqual(hints.filter { $0.lowercased() == "github" }, ["GitHub"])
        XCTAssertTrue(hints.contains("Pull Request"))

        let many = DictationVocabulary(userTerms: (1...100).map { "Term \($0)" })
        XCTAssertEqual(many.speechHints.count, DictationVocabulary.maxSpeechHints)
        XCTAssertEqual(many.speechHints.last, "Term 100")
    }

    func testGlossaryRunsWithoutUserVocabulary() {
        let prepared = DictationVocabulary(userTerms: []).beforeCleanup("Erstelle einen Pulrequest")
        XCTAssertEqual(prepared.text, "Erstelle einen Pull Request")
        XCTAssertEqual(prepared.cleanupTerms, ["Pull Request"])
        XCTAssertEqual(DictationVocabulary(userTerms: []).speechHints, TechGlossary.listedTerms)
    }

    func testUserSoundsLikeWinsOverTheGlossaryAndIsReportedAsCustom() {
        // The user maps "Herder" to their own spelling, overriding the glossary's herdr.
        let vocabulary = DictationVocabulary(userTerms: ["Herdr Tool"], soundsLike: ["herdrtool": ["Herder"]])
        var sources: [String] = []
        let prepared = vocabulary.beforeCleanup("Öffne den Herder und einen Pulrequest") { before, after, _, source in
            sources.append("\(before)→\(after) \(source.rawValue)")
        }
        XCTAssertEqual(prepared.text, "Öffne den Herdr Tool und einen Pull Request")
        XCTAssertEqual(sources, ["Herder→Herdr Tool custom", "Pulrequest→Pull Request built-in"])
        XCTAssertEqual(prepared.cleanupTerms, ["Herdr Tool", "Pull Request"])
    }

    func testUserTermIsNotListedTwiceForCleanup() {
        let prepared = DictationVocabulary(userTerms: ["GitHub"]).beforeCleanup("auf gitub")
        XCTAssertEqual(prepared.text, "auf GitHub")
        XCTAssertEqual(prepared.cleanupTerms, ["GitHub"])
    }

    func testAfterFormattingRestoresOnlyUserSpellings() {
        let vocabulary = DictationVocabulary(userTerms: ["herdr"], soundsLike: ["herdr": ["Hörder"]])
        XCTAssertEqual(vocabulary.afterFormatting("Herdr startet. Hörder auch."), "herdr startet. herdr auch.")
        // The glossary is not re-applied after formatting.
        XCTAssertEqual(DictationVocabulary(userTerms: []).afterFormatting("Ein Pulrequest."), "Ein Pulrequest.")
    }
}

final class TranscriptFormatterLanguageTests: XCTestCase {
    func testGermanKeepsUmAndEr() {
        XCTAssertEqual(TranscriptFormatter.format("Würde das ausreichen, um einen Schluss zu ziehen", style: .polished),
                       "Würde das ausreichen, um einen Schluss zu ziehen.")
        XCTAssertEqual(TranscriptFormatter.format("Können wir uns um 13:00 Uhr treffen", style: .polished),
                       "Können wir uns um 13:00 Uhr treffen.")
        XCTAssertEqual(TranscriptFormatter.format("Setze das bitte komplett um", style: .polished),
                       "Setze das bitte komplett um.")
        XCTAssertEqual(TranscriptFormatter.format("ich sehe nicht, was er wirklich erkannt hat", style: .polished),
                       "Ich sehe nicht, was er wirklich erkannt hat.")
        XCTAssertEqual(TranscriptFormatter.format("Er kommt um acht", style: .veryCasual), "er kommt um acht")
    }

    func testGermanFillersAreStripped() {
        XCTAssertEqual(TranscriptFormatter.format("Äh ich wollte ähm fragen, öhm, ob das geht", style: .polished),
                       "Ich wollte fragen, ob das geht.")
        XCTAssertEqual(TranscriptFormatter.format("hm das ist gut", style: .polished), "Das ist gut.")
    }

    func testEnglishFillersStillStrippedFromEnglish() {
        XCTAssertEqual(TranscriptFormatter.format("um let's ship the build, uh, tonight", style: .polished),
                       "Let's ship the build, tonight.")
        XCTAssertEqual(TranscriptFormatter.format("er I think that is fine", style: .polished), "I think that is fine.")
        XCTAssertTrue(TranscriptFormatter.readsAsEnglish("let's ship the build tonight"))
        XCTAssertFalse(TranscriptFormatter.readsAsEnglish("Erstelle einen Pull Request und warte auf den Reviewer"))
        XCTAssertFalse(TranscriptFormatter.readsAsEnglish("Grüße"))
    }

    func testNoCapitalAfterAbbreviations() {
        XCTAssertEqual(TranscriptFormatter.format("exportiert werden, bzw. in die Zwischenablage kopiert", style: .polished),
                       "Exportiert werden, bzw. in die Zwischenablage kopiert.")
        XCTAssertEqual(TranscriptFormatter.format("zum Beispiel z. B. die Logs, d. h. alle", style: .polished),
                       "Zum Beispiel z. B. die Logs, d. h. alle.")
        XCTAssertEqual(TranscriptFormatter.format("das dauert ca. zehn Minuten", style: .polished),
                       "Das dauert ca. zehn Minuten.")
        XCTAssertEqual(TranscriptFormatter.format("Logs, Daten usw. kommen später", style: .polished),
                       "Logs, Daten usw. kommen später.")
        XCTAssertEqual(TranscriptFormatter.format("z.B. die Logs", style: .polished), "Z.B. die Logs.")
        // Real sentence ends still capitalize, and nothing is lowercased.
        XCTAssertEqual(TranscriptFormatter.format("das ist gut. danach weiter", style: .polished),
                       "Das ist gut. Danach weiter.")
        XCTAssertEqual(TranscriptFormatter.format("am 13. Danach weiter", style: .polished), "Am 13. Danach weiter.")
        XCTAssertEqual(TranscriptFormatter.format("bzw. Das bleibt", style: .polished), "Bzw. Das bleibt.")
    }
}
