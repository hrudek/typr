import Foundation

// The UIKit names the shared keyboard sources mention; the replay never reaches UIKit behavior.

enum UITextAutocapitalizationType { case none, words, sentences, allCharacters }
enum UITextAutocorrectionType { case `default`, no, yes }
enum UIKeyboardType {
    case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad, phonePad, namePhonePad
    case emailAddress, decimalPad, twitter, webSearch, asciiCapableNumberPad
}
enum UIReturnKeyType { case `default`, go, send, search, done }
enum UIKeyboardAppearance { case `default`, dark, light }

struct UILexiconEntry {
    let userInput: String
    let documentText: String
}

final class UILexicon {
    let entries: [UILexiconEntry] = []
}

/// System spelling is unavailable here; `LexiconChecker` stands in through `TextChecking`.
final class UITextChecker {
    static let availableLanguages: [String] = []
    func rangeOfMisspelledWord(in string: String, range: NSRange, startingAt: Int, wrap: Bool,
                               language: String) -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }
    func guesses(forWordRange range: NSRange, in string: String, language: String) -> [String]? { nil }
    func completions(forPartialWordRange range: NSRange, in string: String, language: String) -> [String]? { nil }
}

func CACurrentMediaTime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

@MainActor
protocol UITextDocumentProxy {
    var documentContextBeforeInput: String? { get }
    var hasText: Bool { get }
    var autocapitalizationType: UITextAutocapitalizationType { get }
    var autocorrectionType: UITextAutocorrectionType { get }
    var isSecureTextEntry: Bool { get }
    var keyboardType: UIKeyboardType { get }
    var returnKeyType: UIReturnKeyType { get }
    var enablesReturnKeyAutomatically: Bool { get }
    var keyboardAppearance: UIKeyboardAppearance { get }
    func insertText(_ text: String)
    func deleteBackward()
    func adjustTextPosition(byCharacterOffset offset: Int)
}

#if os(Linux)
// Linux CoreFoundation declares the Darwin notify center without implementing it. One process,
// so there is nobody to notify.
@_cdecl("CFNotificationCenterGetDarwinNotifyCenter")
func darwinNotifyCenter() -> UnsafeMutableRawPointer? { nil }
@_cdecl("CFNotificationCenterPostNotification")
func postNotification(_ center: UnsafeRawPointer?, _ name: UnsafeRawPointer?, _ object: UnsafeRawPointer?,
                      _ userInfo: UnsafeRawPointer?, _ immediately: UInt8) {}
@_cdecl("CFNotificationCenterAddObserver")
func addObserver(_ center: UnsafeRawPointer?, _ observer: UnsafeRawPointer?, _ callback: UnsafeRawPointer?,
                 _ name: UnsafeRawPointer?, _ object: UnsafeRawPointer?, _ behavior: Int) {}
@_cdecl("CFNotificationCenterRemoveObserver")
func removeObserver(_ center: UnsafeRawPointer?, _ observer: UnsafeRawPointer?, _ name: UnsafeRawPointer?,
                    _ object: UnsafeRawPointer?) {}

extension FileManager {
    func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? { nil }
}
#endif
