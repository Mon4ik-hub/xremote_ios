import Foundation

/// Открытый API plapi.cdnvideohub.com: playlist -> vkId -> video -> mp4.
/// Порт extractors.js (parseCvhUrl / cvhPlaylist / cvhSelect / cvhVideo / cvhExtract).
///
/// ВАЖНО: запросы идут с User-Agent десктопного Chrome — CDN записывает тип
/// клиента в параметр srcAg ссылки, а плеер AniLabX ходит как Chrome.
enum CvhExtractor {
    static let api = "https://plapi.cdnvideohub.com/api/v1/player/sv"
    static let referer = "https://animego.org/"

    private static let headers = [
        "Referer": referer,
        "Accept": "application/json",
        "User-Agent": HttpClient.browserUA
    ]

    private static let qualityMap: [(String, Int)] = [
        ("mpegMobileUrl", 144), ("mpegTinyUrl", 144), ("mpegLowestUrl", 240), ("mpegLowUrl", 360),
        ("mpegMediumUrl", 480), ("mpegHighUrl", 720), ("mpegFullHdUrl", 1080), ("mpegQhdUrl", 1440),
        ("mpeg2kUrl", 2048), ("mpeg4kUrl", 2160)
    ]

    struct EpisodeItem: Equatable {
        let cvhId: String
        let videoId: String
        let studio: String?
        let season: Int
        let episode: Int
    }

    struct ParsedEmbed: Equatable {
        let cvhId: String
        let studio: String?
        let season: Int?
        let episode: Int?
    }

    private static let embedRegex = Regex(#"/cdn-iframe/(\d+)((?:/[^/?#]+){0,3})"#, caseInsensitive: true)
    private static let dubbingRegex = Regex(#"[?&]dubbing=([^&]+)"#)

    /// /cdn-iframe/<id>/<studio>/<season>/<episode> (или новый формат с ?dubbing=).
    static func parseUrl(_ url: String) throws -> ParsedEmbed {
        guard let match = embedRegex.firstMatch(in: url), let cvhId = Regex.group(match, url, 1) else {
            throw AppError.parse("Не узнал ссылку CVH: \(url)")
        }
        var segments = (Regex.group(match, url, 2) ?? "")
            .split(separator: "/").map(String.init)
        var studio: String?
        if let first = segments.first, !isDigits(first) {
            studio = first.removingPercentEncoding ?? first
            segments.removeFirst()
        }
        if let dubParam = dubbingRegex.firstGroup(in: url) {
            studio = dubParam.removingPercentEncoding ?? dubParam
        }
        let numbers = segments.filter(isDigits).compactMap(Int.init)
        return ParsedEmbed(
            cvhId: cvhId,
            studio: studio,
            season: numbers.count > 0 ? numbers[0] : nil,
            episode: numbers.count > 1 ? numbers[1] : nil
        )
    }

    static func playlist(_ http: HttpClient, cvhId: String) async throws -> [EpisodeItem] {
        let url = "\(api)/playlist?pub=747&aggr=mali&id=\(cvhId)"
        let data = try await http.getJson(url, headers: headers)
        let items = data["items"] as? [[String: Any]] ?? []
        guard !items.isEmpty else {
            throw AppError.parse("CVH вернул пустой плейлист для id=\(cvhId)")
        }
        return items.map { item in
            let season = intValue(item["season"])
            let episode = intValue(item["episode"])
            return EpisodeItem(
                cvhId: stringValue(item["cvhId"]) ?? "",
                videoId: stringValue(item["vkId"]) ?? "",
                studio: stringValue(item["voiceStudio"]),
                season: season == 0 ? 1 : season,
                episode: episode == 0 ? 1 : episode
            )
        }
    }

    /// Нечёткое сравнение озвучек: "Dream Cast" == "Dream-Cast".
    static func studioKey(_ name: String?) -> String {
        guard let name else { return "" }
        return String(name.lowercased().filter { character in
            ("0"..."9").contains(character)
                || ("a"..."z").contains(character)
                || ("а"..."я").contains(character)
                || character == "ё"
        })
    }

    static func select(_ items: [EpisodeItem], season: Int?, episode: Int?, studio: String?) throws -> EpisodeItem {
        guard !items.isEmpty else { throw AppError.parse("Плейлист CVH пуст") }
        let seasons = Array(Set(items.map { $0.season })).sorted()
        var wantedSeason = season
        if wantedSeason == nil || seasons.count == 1 { wantedSeason = seasons.first }
        var pool = items.filter { $0.season == wantedSeason }
        guard !pool.isEmpty else {
            throw AppError.parse("Сезон \(wantedSeason ?? -1) не найден; есть: \(seasons.map(String.init).joined(separator: ","))")
        }
        var wantedEpisode = episode
        if wantedEpisode == nil { wantedEpisode = pool.map { $0.episode }.min() }
        pool = pool.filter { $0.episode == wantedEpisode }
        guard !pool.isEmpty else {
            throw AppError.parse("Эпизод \(wantedEpisode ?? -1) не найден в сезоне \(wantedSeason ?? -1)")
        }
        if let studio {
            let wanted = studioKey(studio)
            if let exact = pool.first(where: { studioKey($0.studio) == wanted }) {
                return exact
            }
            if let fuzzy = pool.first(where: { item in
                let key = studioKey(item.studio)
                return !key.isEmpty && (key.contains(wanted) || wanted.contains(key))
            }) {
                return fuzzy
            }
        }
        return pool[0]
    }

    static func video(_ http: HttpClient, videoId: String) async throws -> [VideoStream] {
        let data = try await http.getJson("\(api)/video/\(videoId)", headers: headers)
        let sources = data["sources"] as? [String: Any] ?? [:]
        var streams: [VideoStream] = []
        if let hls = stringValue(sources["hlsUrl"]) {
            streams.append(VideoStream(kind: .hls, quality: nil, url: hls))
        }
        for (key, value) in sources.sorted(by: { $0.key < $1.key }) {
            guard let urlString = value as? String, urlString.hasPrefix("http") else { continue }
            if key == "hlsUrl" || key == "dashUrl" || key == "dashManifestUrl" { continue }
            guard let quality = qualityMap.first(where: { $0.0 == key })?.1 else { continue }
            streams.append(VideoStream(kind: .mp4, quality: quality, url: urlString))
        }
        guard !streams.isEmpty else {
            throw AppError.parse("CVH не отдал ссылок для видео \(videoId)")
        }
        // по убыванию качества, при равенстве mp4 раньше hls
        streams.sort { lhs, rhs in
            let left = lhs.quality ?? 0
            let right = rhs.quality ?? 0
            if left != right { return left > right }
            return lhs.kind == .mp4 && rhs.kind != .mp4
        }
        return streams
    }

    /// Полный поток CVH: embed-ссылка (несёт cvh_id, озвучку и номер серии) -> потоки.
    static func extract(_ http: HttpClient, embedUrl: String) async throws -> (item: EpisodeItem, streams: [VideoStream]) {
        let parsed = try parseUrl(embedUrl)
        let items = try await playlist(http, cvhId: parsed.cvhId)
        let chosen = try select(items, season: parsed.season, episode: parsed.episode, studio: parsed.studio)
        let streams = try await video(http, videoId: chosen.videoId)
        return (chosen, streams)
    }

    static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string) ?? 0
        default: return 0
        }
    }

    private static func isDigits(_ string: String) -> Bool {
        !string.isEmpty && string.allSatisfy { ("0"..."9").contains($0) }
    }
}
