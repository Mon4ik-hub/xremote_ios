import Foundation

/// Общая цепочка отправки серии: выбор провайдера по плееру/озвучке, поиск
/// прямой ссылки, сборка сообщения. Используется и Share Extension, и приложением
/// (экран «Продолжить» из истории).
@MainActor
enum CastResolver {
    struct Resolved {
        let message: Data
        let qualityName: String
        let season: String
        let providerKey: String
        let dub: String
    }

    static func playerName(_ key: String) -> String {
        key == "cvh" ? "CVH" : "Kodik"
    }

    /// Что отправляем: серия тайтла выбранным плеером и озвучкой.
    struct Query {
        let episode: Episode
        let title: String
        let urlString: String
        let playerKey: String
        let selectedDub: String
    }

    /// Плеер выбирает пользователь: сначала выбранная озвучка, затем остальные
    /// озвучки ТОГО ЖЕ плеера (автоподмены плеера нет). Ссылка получается в
    /// последний момент и сразу возвращается — CVH-ссылки короткоживущие.
    static func resolve(
        _ query: Query,
        http: HttpClient,
        onProgress: @MainActor (String) -> Void = { _ in }
    ) async throws -> Resolved {
        AppLog.shared.log(
            "Resolve: эп.\(query.episode.number) плеер=\(query.playerKey) озвучка=\(query.selectedDub)"
        )
        let providers = try await AnimeGoClient(http: http)
            .fetchProviders(animeUrl: query.urlString, episodeId: query.episode.id)
        let playerProviders = providers.filter { $0.key == query.playerKey }
        AppLog.shared.log(
            "Resolve: провайдеров \(providers.count), для плеера — \(playerProviders.count)"
        )
        guard !playerProviders.isEmpty else {
            let other = playerName(query.playerKey == "cvh" ? "kodik" : "cvh")
            AppLog.shared.log("Resolve: плеера нет у эпизода")
            throw AppError.cast(
                "У этого эпизода нет плеера \(playerName(query.playerKey)) — выберите \(other) в настройках"
            )
        }

        let chosen = playerProviders.first { $0.dub == query.selectedDub }
        let candidates = [chosen].compactMap { $0 } + playerProviders.filter { $0.dub != query.selectedDub }

        var lastError: Error?
        for (index, provider) in candidates.enumerated() {
            if index > 0 {
                let previous = candidates[index - 1].dub
                onProgress("Озвучка «\(previous)» не подошла, пробую «\(provider.dub)»…")
            }
            AppLog.shared.log("Resolve: попытка \(index + 1)/\(candidates.count) — \(provider.dub)")
            do {
                let resolved = try await resolveOne(provider, query: query, http: http)
                AppLog.shared.log(
                    "Resolve: успех \(resolved.qualityName) через \(resolved.providerKey)/\(resolved.dub)"
                )
                return resolved
            } catch {
                AppLog.shared.log("Resolve: попытка не удалась — \(AppError.humanText(error))")
                lastError = error
            }
        }
        let available = playerProviders.map { $0.dub }.joined(separator: ", ")
        let reason = AppError.humanText(lastError ?? AppError.parse("неизвестно"))
        let other = playerName(query.playerKey == "cvh" ? "kodik" : "cvh")
        throw AppError.cast(
            "Плеер \(playerName(query.playerKey)) не дал ссылку (озвучки: \(available)). \(reason)"
            + " Можно попробовать плеер \(other) в настройках."
        )
    }

    /// Извлечение прямой ссылки одного провайдера и сборка сообщения.
    private static func resolveOne(
        _ provider: ProviderItem,
        query: Query,
        http: HttpClient
    ) async throws -> Resolved {
        let streams: [VideoStream]
        let season: String
        if provider.key == "cvh" {
            let extracted = try await CvhExtractor.extract(http, embedUrl: provider.url)
            streams = extracted.streams
            season = "\(extracted.item.season) сезон" // сезон берётся из плейлиста CVH
        } else {
            streams = try await KodikExtractor.extract(http, embedUrl: provider.url)
            season = "1 сезон" // у Kodik сезон неизвестен
        }
        guard let stream = pickMp4(streams, maxQuality: provider.key == "cvh" ? "1080" : "720") else {
            throw AppError.cast("Плеер отдал только HLS, прямого mp4 нет")
        }
        var headers = ["Referer": "https://animego.org/"]
        if provider.key == "cvh", srcAg(of: stream.url) != "CHROME" {
            headers["User-Agent"] = HttpClient.browserUA
        }
        let qualityName = "\(stream.quality ?? 0)p"
        let message = try CastMessage.playVideo(.init(
            contentId: "animego/" + query.episode.id,
            title: query.title,
            season: season,
            translation: provider.dub,
            episode: "\(query.episode.number) серия",
            qualityName: qualityName,
            directUrl: stream.url,
            embedUrl: provider.url,
            headersForDirect: headers
        ))
        return Resolved(
            message: message,
            qualityName: qualityName,
            season: season,
            providerKey: provider.key,
            dub: provider.dub
        )
    }

    /// COMMAND_SUCCESS и осмысленные русские фразы для остальных ответов.
    static func requireSuccess(_ response: XRemoteResponse) throws {
        switch response.response {
        case "COMMAND_SUCCESS":
            break
        case "COMMAND_FAIL":
            throw AppError.cast("Сервер отверг команду (COMMAND_FAIL)")
        case "VERSION_INCOMPATIBLE":
            throw AppError.cast("Версия AniLabX несовместима с приложением (VERSION_INCOMPATIBLE)")
        case "EXCEPTION":
            throw AppError.cast("На сервере AniLabX произошло исключение (EXCEPTION)")
        case .some(let other):
            throw AppError.cast("Неожиданный ответ сервера: \(other)")
        case nil:
            throw AppError.cast("В ответе сервера нет поля RESPONSE")
        }
    }

    /// Тип клиента в параметре srcAg: плеер AniLabX ходит как Chrome.
    private static func srcAg(of url: String) -> String? {
        Regex("[?&]srcAg=([^&]+)").firstGroup(in: url)
    }
}
