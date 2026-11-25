import Foundation

/// Пометки просмотренных серий. Хранятся в UserDefaults расширения,
/// живут между вызовами «Поделиться». Ключ — id серии (data-episode).
final class WatchedStore {
    static let storageKey = "watched_episodes"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func all() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    func isWatched(_ episodeId: String) -> Bool {
        all().contains(episodeId)
    }

    func markWatched(_ episodeId: String) {
        var set = all()
        set.insert(episodeId)
        persist(set)
    }

    /// Переключить пометку (ручной свайп в списке серий).
    func toggle(_ episodeId: String) {
        var set = all()
        if set.contains(episodeId) {
            set.remove(episodeId)
        } else {
            set.insert(episodeId)
        }
        persist(set)
    }

    private func persist(_ set: Set<String>) {
        defaults.set(Array(set).sorted(), forKey: Self.storageKey)
    }
}
