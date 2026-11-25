import Foundation

/// Сборка XRemote-сообщений (формат из IOS_APP_PROMPT.md, проверен на настоящем
/// AniLabX 24.11.2026). Обязательные поля PLAY_DATA проверяются до отправки:
/// пустой SEASON/TRANSLATION/EPISODE/CONTENT_TITLE/CONTENT_ID валят сервер.
enum CastMessage {
    static let apiVersion = 10
    static let clientName = "iPhone"
    static let clientAppName = "AnimeGO Cast"
    static let clientAppVersion = "1.0"
    static let clientType = "PHONE"

    struct PlayRequest: Equatable {
        var contentId: String      // "animego/<id серии>"
        var title: String          // CONTENT_TITLE
        var season: String         // "<номер> сезон"
        var translation: String    // озвучка
        var episode: String        // "<номер> серия"
        var qualityName: String    // "<качество>p"
        var directUrl: String      // прямая ссылка mp4
        var embedUrl: String       // embed-ссылка плеера (PARSE_LINK.ORIGINAL)
        var headersForDirect: [String: String]
    }

    static func playVideo(_ request: PlayRequest) throws -> Data {
        let required = [
            request.contentId, request.title, request.season, request.translation,
            request.episode, request.directUrl, request.embedUrl
        ]
        guard required.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AppError.cast("Пустые обязательные поля PLAY_DATA — отправка отменена (без них сервер AniLabX падает)")
        }
        let playData: [String: Any] = [
            "SERVICE_ID": 0,
            "CONTENT_ID": request.contentId,
            "CONTENT_TITLE": request.title,
            "CONTENT_SUBTITLE": "аниме",
            "SEASON": request.season,
            "TRANSLATION": request.translation,
            "EPISODE": request.episode,
            "LINK_ITEM": [
                "NAME": request.qualityName,
                "LINK_PARTS": [request.directUrl],
                "IS_ALTERNATIVE": false
            ],
            "PARSE_LINK": [
                "ORIGINAL": request.embedUrl,
                "DIRECT": request.directUrl,
                "HEADERS_FOR_DIRECT": request.headersForDirect
            ],
            "RESPECT_TRANSLATION_NAME": true,
            "POSITION": 0,
            "WINDOW": 0
        ]
        return try envelope("PLAY_VIDEO", extra: [
            "PLAY_COMMAND": "NONE",
            "PLAY_DATA": playData
        ])
    }

    static func ping() throws -> Data {
        try envelope("PING", extra: [:])
    }

    static func getPlayInfo() throws -> Data {
        try envelope("GET_PLAY_INFO", extra: [:])
    }

    static func closePlayer() throws -> Data {
        try envelope("CLOSE_PLAYER", extra: [:])
    }

    private static func envelope(_ command: String, extra: [String: Any]) throws -> Data {
        var message: [String: Any] = [
            "API_VERSION": apiVersion,
            "CLIENT_NAME": clientName,
            "CLIENT_APP_NAME": clientAppName,
            "CLIENT_APP_VERSION": clientAppVersion,
            "CLIENT_TYPE": clientType,
            "COMMAND": command
        ]
        for (key, value) in extra {
            message[key] = value
        }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A) // сервер читает построчно — JSON заканчивается \n
        return data
    }
}
