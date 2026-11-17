import Foundation

/// The owner writes compounds with spaces, not hyphens.
///
/// `spaceCompounds` runs on the speech engine's text in every style, before spelling and AI cleanup
/// (and so also on Off, Verbatim and fallback paths). It is radical, and a space wins when in
/// doubt: every hyphen between two words becomes a space ("Feedback-Menü", "Know-how",
/// "PR-Feedback", "Open-Source-Build"). Kept: a hyphen after a single letter (E-Mail, T-Shirt,
/// x-mal, so "testflight-e-mails" becomes "testflight e-mails"), a hyphen between two numbers
/// (5-10, 2026-11-10), and everything inside a link, address or file name. A user's Custom
/// vocabulary term with a hyphen is restored by the spelling passes.
enum CleanupHyphens {
    /// Every hyphen between two words becomes a space, except after a single letter (E-Mail),
    /// between two numbers (5-10) and inside links, addresses and file names. See the type comment.
    static func spaceCompounds(_ text: String) -> String {
        let chunks = try! NSRegularExpression(pattern: #"\S+"#)
        let compounds = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+(?:-[\p{L}\p{M}\p{N}]+)+"#)
        let linkLike = try! NSRegularExpression(pattern: #"[/@]|\.[\p{L}\p{N}]"#)
        let source = text as NSString
        let result = NSMutableString(string: text)
        for chunk in chunks.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard linkLike.firstMatch(in: text, range: chunk.range) == nil else { continue }
            for match in compounds.matches(in: text, range: chunk.range) {
                let parts = source.substring(with: match.range).components(separatedBy: "-")
                var location = match.range.location
                for index in parts.indices.dropLast() {
                    location += (parts[index] as NSString).length
                    let before = parts[index], after = parts[index + 1]
                    let singleLetter = before.count == 1 && before.allSatisfy(\.isLetter)
                    let numbers = before.allSatisfy(\.isNumber) && after.allSatisfy(\.isNumber)
                    if !singleLetter && !numbers {
                        // "-" and " " have the same UTF-16 length, so later ranges stay valid.
                        result.replaceCharacters(in: NSRange(location: location, length: 1), with: " ")
                    }
                    location += 1
                }
            }
        }
        return result as String
    }
}
