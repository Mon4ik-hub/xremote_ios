import Foundation

/// Тонкая обёртка над NSRegularExpression: группы совпадения как строки.
struct Regex {
    let regex: NSRegularExpression

    init(_ pattern: String,
         caseInsensitive: Bool = false,
         dotMatchesLineSeparators: Bool = false) {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        if dotMatchesLineSeparators { options.insert(.dotMatchesLineSeparators) }
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    func firstMatch(in text: String) -> NSTextCheckingResult? {
        let ns = text as NSString
        return regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length))
    }

    /// Группа 1 первого совпадения.
    func firstGroup(in text: String) -> String? {
        guard let match = firstMatch(in: text) else { return nil }
        return Self.group(match, text, 1)
    }

    func allMatches(in text: String) -> [NSTextCheckingResult] {
        let ns = text as NSString
        return regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
    }

    /// Замена всех совпадений на шаблон.
    func replace(in text: String, with template: String) -> String {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    static func group(_ match: NSTextCheckingResult, _ text: String, _ index: Int) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}
