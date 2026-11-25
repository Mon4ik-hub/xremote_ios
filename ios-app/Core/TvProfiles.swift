import Foundation

/// Профиль телевизора: имя, IP и порт.
struct TvProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int

    var address: String { "\(host):\(port)" }
}

/// Хранилище профилей телевизоров. JSON-массив в UserDefaults расширения
/// (без App Groups: контейнерному приложению профили не нужны).
/// Первый элемент списка — последний использованный телевизор.
final class TvProfileStore: ObservableObject {
    static let storageKey = "tv_profiles"

    private let defaults: UserDefaults

    @Published private(set) var profiles: [TvProfile]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([TvProfile].self, from: data),
           !saved.isEmpty {
            profiles = saved
        } else {
            let initial = TvProfile(name: "Телевизор", host: "192.168.1.140", port: 31337)
            profiles = [initial]
            persist()
        }
    }

    /// Телевизор, на который отправляли последним.
    var lastUsed: TvProfile? { profiles.first }

    /// После отправки телевизор всплывает первым в списке.
    func markUsed(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), index != 0 else { return }
        let profile = profiles.remove(at: index)
        profiles.insert(profile, at: 0)
        persist()
    }

    func add(_ profile: TvProfile) {
        profiles.append(profile)
        persist()
    }

    func update(_ profile: TvProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        persist()
    }

    /// При удалении последнего использованного «последним» становится следующий
    /// по порядку (просто сжимаем список — порядок остального сохраняется).
    func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
        persist()
    }

    /// Добавить или обновить телевизор и поднять наверх (handoff из расширения).
    func upsert(name: String, host: String, port: Int) {
        if let existing = profiles.first(where: { $0.host == host && $0.port == port }) {
            var updated = existing
            updated.name = name
            update(updated)
            markUsed(id: updated.id)
        } else {
            let profile = TvProfile(name: name, host: host, port: port)
            add(profile)
            markUsed(id: profile.id)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Валидация адреса. Возвращает нормализованные host и port или nil.
    static func validatedAddress(host rawHost: String, port rawPort: String) -> (host: String, port: Int)? {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        // на случай вставки целого адреса со схемой
        if let schemeRange = host.range(of: "://") { host = String(host[schemeRange.upperBound...]) }
        if let slashIndex = host.firstIndex(of: "/") { host = String(host[..<slashIndex]) }
        guard !host.isEmpty, !host.contains(" "), !host.contains(":") else { return nil }
        guard let port = Int(rawPort.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(port) else { return nil }
        return (host, port)
    }
}
