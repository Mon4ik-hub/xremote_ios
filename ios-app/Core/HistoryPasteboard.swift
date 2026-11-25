import UIKit

/// Автоматическая передача истории из расширения в приложение без App Groups:
/// расширение после успешной отправки кладёт payload в буфер обмена,
/// приложение импортирует его при следующем открытии и очищает буфер.
///
/// Чтение чужого содержимого показывает системный баннер «вставлено из…»,
/// поэтому приложение сначала смотрит `changeCount` (простое число, без
/// баннера) и читает строку только если буфер менялся с прошлой проверки.
enum HistoryPasteboard {
    static let marker = "animegocast-history:1:"

    /// Обычная запись строки (без setItems/expirationDate — на них были краши).
    static func write(_ payload: HistoryHandoff.Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UIPasteboard.general.string = marker + String(decoding: data, as: UTF8.self)
        AppLog.shared.log("HistoryPasteboard.write: payload записан (\(data.count) байт)")
    }

    /// Наши данные в буфере? (чужое содержимое вернёт nil)
    static func readPayload() -> HistoryHandoff.Payload? {
        guard let string = UIPasteboard.general.string else {
            AppLog.shared.log("HistoryPasteboard.read: буфер пуст")
            return nil
        }
        guard string.hasPrefix(marker) else {
            AppLog.shared.log("HistoryPasteboard.read: не наши данные (\(string.count) символов)")
            return nil
        }
        let json = String(string.dropFirst(marker.count))
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(HistoryHandoff.Payload.self, from: data) else {
            AppLog.shared.log("HistoryPasteboard.read: не разобрали payload")
            return nil
        }
        AppLog.shared.log("HistoryPasteboard.read: payload \(payload.title) эп.\(payload.episodeNumber)")
        return payload
    }

    /// Потребить наши данные: очистить буфер (запись — без баннера).
    static func clear() {
        UIPasteboard.general.string = ""
        AppLog.shared.log("HistoryPasteboard.clear")
    }
}
