import Foundation

/// Настройки отправки в самом расширении (без App Groups): плеер по умолчанию
/// и выбранная озвучка. Список озвучек зависит от выбранного плеера.
final class CastPreferences {
    static let playerKeyKey = "cast_player"
    static let dubKey = "cast_dub"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// "cvh" | "kodik" (по умолчанию CVH — у него до 1080p).
    var playerKey: String {
        get { defaults.string(forKey: Self.playerKeyKey) ?? "cvh" }
        set { defaults.set(newValue, forKey: Self.playerKeyKey) }
    }

    /// Выбранная озвучка; пустая строка — «первая доступная».
    var dub: String {
        get { defaults.string(forKey: Self.dubKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.dubKey) }
    }
}
