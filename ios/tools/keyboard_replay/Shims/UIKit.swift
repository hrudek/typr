@_exported import Foundation

// The UIKit names the shared keyboard sources mention; the replay never reaches UIKit behavior.

public enum UITextAutocapitalizationType: Sendable { case none, words, sentences, allCharacters }
public enum UITextAutocorrectionType: Sendable { case `default`, no, yes }
public enum UITextInlinePredictionType: Sendable { case `default`, no, yes }
public enum UIKeyboardType: Sendable {
    case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad, phonePad, namePhonePad
    case emailAddress, decimalPad, twitter, webSearch, asciiCapableNumberPad
}
public enum UIReturnKeyType: Sendable { case `default`, go, send, search, done }
public enum UIKeyboardAppearance: Sendable { case `default`, dark, light }

public struct UILexiconEntry {
    public let userInput: String
    public let documentText: String
}

public final class UILexicon {
    public let entries: [UILexiconEntry] = []
}

/// System spelling is unavailable here; the replay injects its own `TextChecking`.
public final class UITextChecker {
    public static let availableLanguages: [String] = []
    public init() {}
    public func rangeOfMisspelledWord(in string: String, range: NSRange, startingAt: Int, wrap: Bool,
                                      language: String) -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }
    public func guesses(forWordRange range: NSRange, in string: String, language: String) -> [String]? { nil }
    public func completions(forPartialWordRange range: NSRange, in string: String, language: String) -> [String]? {
        nil
    }
}

@MainActor
public protocol UITextDocumentProxy {
    var documentContextBeforeInput: String? { get }
    var hasText: Bool { get }
    var autocapitalizationType: UITextAutocapitalizationType { get }
    var autocorrectionType: UITextAutocorrectionType { get }
    var isSecureTextEntry: Bool { get }
    var keyboardType: UIKeyboardType { get }
    var inlinePredictionType: UITextInlinePredictionType { get }
    var returnKeyType: UIReturnKeyType { get }
    var enablesReturnKeyAutomatically: Bool { get }
    var keyboardAppearance: UIKeyboardAppearance { get }
    func insertText(_ text: String)
    func deleteBackward()
    func adjustTextPosition(byCharacterOffset offset: Int)
}
