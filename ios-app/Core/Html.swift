import Foundation

/// Разбор HTML-разметки animego регулярками, перенесёнными из
/// chrome-extension/background.js 1:1 — порядок атрибутов в разметке важен.
enum Html {
    static let playerLoader = Regex(#"data-anime-player-loader-url-value="/player/(\d+)""#)
    static let h1 = Regex(#"<h1[^>]*>(.*?)</h1>"#, dotMatchesLineSeparators: true)
    static let htmlTag = Regex(#"<[^>]+>"#)
    static let episodeRow = Regex(
        #"data-episode-number="([^"]+)"[^>]*data-episode-page="\d+""#
            + #"[^>]*data-episode-index="\d+"[^>]*data-episode-type="\d+"[^>]*data-episode="(\d+)""#
    )
    static let providerRow = Regex(
        #"data-player="([^"]+)"[^>]*data-provider-title="([^"]+)"[^>]*data-translation-title="([^"]+)""#
    )

    /// Какие плееры из разметки animego поддерживаем: title на сайте -> ключ.
    static let supportedPlayers = ["CVH": "cvh", "Kodik": "kodik"]

    static func animeMeta(from page: String) throws -> AnimeMeta {
        guard let animeId = playerLoader.firstGroup(in: page) else {
            throw AppError.parse("Не нашёл плеер на странице — это точно страница аниме?")
        }
        let rawTitle = h1.firstGroup(in: page) ?? ""
        let title = htmlTag.replace(in: rawTitle, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return AnimeMeta(animeId: animeId, title: title.isEmpty ? "anime_" + animeId : title)
    }

    static func episodes(from content: String) -> [Episode] {
        episodeRow.allMatches(in: content).compactMap { match in
            guard let number = Regex.group(match, content, 1),
                  let id = Regex.group(match, content, 2) else { return nil }
            return Episode(number: number, id: id)
        }
    }

    static func providers(from content: String) -> [ProviderItem] {
        providerRow.allMatches(in: content).compactMap { match in
            guard let rawUrl = Regex.group(match, content, 1),
                  let playerTitle = Regex.group(match, content, 2),
                  let dub = Regex.group(match, content, 3),
                  let key = supportedPlayers[playerTitle] else { return nil }
            // AniBoom и прочие не поддерживаем
            return ProviderItem(key: key, url: "https:" + unescapeHtml(rawUrl), dub: dub)
        }
    }

    /// JSON из html-атрибута: убирает &quot;, &amp;, &#x5B; и прочие сущности.
    static func unescapeHtml(_ value: String) -> String {
        let named = ["quot": "\"", "amp": "&", "lt": "<", "gt": ">", "apos": "'", "nbsp": " "]
        let entityRegex = Regex("&(#x?[0-9a-fA-F]+|[a-zA-Z]+);")

        let nsHtml = value as NSString
        var out = ""
        var cursor = 0
        while cursor < nsHtml.length {
            let range = NSRange(location: cursor, length: nsHtml.length - cursor)
            guard let match = entityRegex.regex.firstMatch(in: value, options: [], range: range) else { break }
            out += nsHtml.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let entity = nsHtml.substring(with: match.range(at: 1))
            let original = nsHtml.substring(with: match.range)
            out += decodeEntity(entity, original: original, named: named)
            cursor = match.range.location + match.range.length
        }
        if cursor < nsHtml.length {
            out += nsHtml.substring(from: cursor)
        }
        return out
    }

    private static func decodeEntity(_ entity: String, original: String, named: [String: String]) -> String {
        guard entity.hasPrefix("#") else {
            return named[entity.lowercased()] ?? original
        }
        let second = entity.index(after: entity.startIndex)
        let isHex = second < entity.endIndex && (entity[second] == "x" || entity[second] == "X")
        let digits = isHex ? String(entity.dropFirst(2)) : String(entity.dropFirst(1))
        guard let code = isHex ? UInt32(digits, radix: 16) : UInt32(digits),
              let scalar = Unicode.Scalar(code) else {
            return original
        }
        return String(Character(scalar))
    }
}
