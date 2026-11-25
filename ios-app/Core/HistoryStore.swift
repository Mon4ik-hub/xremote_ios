import Foundation

/// История просмотров в контейнерном приложении. Заполняется через handoff
/// (animegocast://resume?...) после успешных отправок из расширения:
/// без App Groups расширение и приложение не видят общие UserDefaults.
struct HistoryEntry: Codable, Identifiable, Equatable {
    var url: String
    var title: String
    var episodeNumber: String
    var watchedAt: Date
    var id: String { url }
}

final class HistoryStore: ObservableObject {
    static let storageKey = "watch_history"
    static let limit = 30

    private let defaults: UserDefaults

    @Published private(set) var entries: [HistoryEntry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.storageKey).flatMap {
            try? JSONDecoder().decode([HistoryEntry].self, from: $0)
        } ?? []
        entries = saved.sorted { $0.watchedAt > $1.watchedAt }
    }

    /// Добавить или обновить запись тайтла (последняя серия и время).
    func upsert(url: String, title: String, episodeNumber: String) {
        var updated = entries
        if let index = updated.firstIndex(where: { $0.url == url }) {
            updated[index].title = title
            updated[index].episodeNumber = episodeNumber
            updated[index].watchedAt = Date()
        } else {
            updated.insert(
                HistoryEntry(url: url, title: title, episodeNumber: episodeNumber, watchedAt: Date()),
                at: 0
            )
        }
        if updated.count > Self.limit {
            updated = Array(updated.prefix(Self.limit))
        }
        entries = updated
        persist()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// Передача успешной отправки из расширения в приложение.
enum HistoryHandoff {
    static let scheme = "animegocast"
    static let host = "resume"

    struct Payload {
        let url: String
        let title: String
        let episodeNumber: String
        let episodeId: String
        let tvName: String?
        let tvHost: String?
        let tvPort: Int?
        let playerKey: String?
        let dub: String?
    }

    static func makeURL(_ payload: Payload) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var items: [URLQueryItem] = [
            URLQueryItem(name: "url", value: payload.url),
            URLQueryItem(name: "title", value: payload.title),
            URLQueryItem(name: "episode", value: payload.episodeNumber),
            URLQueryItem(name: "episodeId", value: payload.episodeId)
        ]
        if let name = payload.tvName { items.append(URLQueryItem(name: "tvName", value: name)) }
        if let hostValue = payload.tvHost { items.append(URLQueryItem(name: "tvHost", value: hostValue)) }
        if let port = payload.tvPort { items.append(URLQueryItem(name: "tvPort", value: String(port))) }
        if let player = payload.playerKey { items.append(URLQueryItem(name: "player", value: player)) }
        if let dub = payload.dub, !dub.isEmpty { items.append(URLQueryItem(name: "dub", value: dub)) }
        components.queryItems = items
        return components.url
    }

    static func parse(_ url: URL) -> Payload? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value
        }
        guard let pageUrl = value("url"),
              let title = value("title"),
              let episode = value("episode") else {
            return nil
        }
        return Payload(
            url: pageUrl,
            title: title,
            episodeNumber: episode,
            episodeId: value("episodeId") ?? "",
            tvName: value("tvName"),
            tvHost: value("tvHost"),
            tvPort: value("tvPort").flatMap(Int.init),
            playerKey: value("player"),
            dub: value("dub")
        )
    }
}
