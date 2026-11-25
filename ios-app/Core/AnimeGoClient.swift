import Foundation

/// Цепочка animego.me: страница тайтла -> серии -> плееры с озвучками.
/// Порт fetchAnimeMeta / fetchEpisodes / fetchProviders из background.js.
struct AnimeGoClient {
    static let base = "https://animego.me"

    private let http: HttpClient

    init(http: HttpClient = HttpClient()) {
        self.http = http
    }

    private func animeHeaders(referer: String) -> [String: String] {
        [
            "X-Requested-With": "XMLHttpRequest",
            "Accept": "application/json",
            "User-Agent": HttpClient.browserUA,
            "Referer": referer,
        ]
    }

    func fetchAnimeMeta(animeUrl: String) async throws -> AnimeMeta {
        let page = try await http.getText(animeUrl, headers: [
            "Accept-Language": "ru-RU,ru;q=0.9",
            "User-Agent": HttpClient.browserUA,
        ])
        return try Html.animeMeta(from: page)
    }

    func fetchEpisodes(animeUrl: String, animeId: String) async throws -> [Episode] {
        var byNumber: [String: Episode] = [:]
        var order: [String] = []
        let headers = animeHeaders(referer: animeUrl)
        for page in 0...50 {
            let payload = try await http.getJson(
                "\(Self.base)/player/\(animeId)/episodes?page=\(page)",
                headers: headers
            )
            let data = payload["data"] as? [String: Any] ?? [:]
            let content = data["content"] as? String ?? ""
            let returned = data["page"] as? Int
            let rows = Html.episodes(from: content)
            for row in rows where byNumber[row.number] == nil {
                byNumber[row.number] = row
                order.append(row.number)
            }
            if rows.isEmpty || (returned != nil && returned != page) {
                break // дальше страниц нет
            }
        }
        return order.compactMap { byNumber[$0] }
            .sorted { (Int($0.number) ?? Int.max) < (Int($1.number) ?? Int.max) }
    }

    func fetchProviders(animeUrl: String, episodeId: String) async throws -> [ProviderItem] {
        let payload = try await http.getJson(
            "\(Self.base)/player/videos/\(episodeId)",
            headers: animeHeaders(referer: animeUrl)
        )
        let content = (payload["data"] as? [String: Any])?["content"] as? String ?? ""
        return Html.providers(from: content)
    }
}
