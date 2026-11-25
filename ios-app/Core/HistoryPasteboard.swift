import UIKit
import UniformTypeIdentifiers

/// Автоматическая передача истории из расширения в приложение без App Groups:
/// расширение после успешной отправки кладёт payload в буфер обмена,
/// приложение импортирует его при следующем открытии и очищает буфер.
///
/// - `localOnly` — не уходит на другие устройства через Universal Clipboard;
/// - данные своего приложения читаются без системного баннера «вставлено из…»;
/// - чтение чужого содержимого баннер показывает, поэтому приложение сначала
///   смотрит `changeCount` (простое число, без баннера) и читает строку только
///   если буфер менялся с прошлой проверки.
enum HistoryPasteboard {
    static let marker = "animegocast-history:1:"
    /// Буфер очищается через сутки, даже если приложение так и не открыли.
    static let expiration: TimeInterval = 60 * 60 * 24

    static func write(_ payload: HistoryHandoff.Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let item = [UTType.utf8PlainText.identifier: marker + String(decoding: data, as: UTF8.self)]
        UIPasteboard.general.setItems(
            [item],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(expiration)
            ]
        )
    }

    /// Наши данные в буфере? (чужое содержимое вернёт nil)
    static func readPayload() -> HistoryHandoff.Payload? {
        guard let string = UIPasteboard.general.string,
              string.hasPrefix(marker) else {
            return nil
        }
        let json = String(string.dropFirst(marker.count))
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(HistoryHandoff.Payload.self, from: data) else {
            return nil
        }
        return payload
    }

    /// Потребить наши данные: очистить буфер (запись — без баннера).
    static func clear() {
        UIPasteboard.general.string = ""
    }
}
