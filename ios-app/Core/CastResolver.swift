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

    struct PlayResult {
        let resolved: Resolved
        /// true — подтверждено опросом (IS_PLAYING/POSITION/DURATION);
        /// false — команда принята, но плеер рапортует «не играет» (возможно,
        /// просто долго буферизует — повторная отправка перезапустила бы видео).
        let confirmed: Bool
    }

    /// Полный цикл: найти ссылку → отправить → убедиться, что видео началось.
    /// Повтор со свежей ссылкой — только если плеер вообще не поднялся
    /// (PLAYER_NOT_RUNNING = верный признак мёртвой ссылки). Если PLAY_NFO есть,
    /// но «не играет» — не шлём повторно: видео могло уже идти, повтор
    /// перезапустил бы его с начала.
    static func play(
        query: Query,
        host: String,
        port: Int,
        http: HttpClient,
        onProgress: @MainActor (String) -> Void = { _ in },
        onSent: @MainActor (Resolved) -> Void = { _ in }
    ) async throws -> PlayResult {
        let first = try await resolve(query, http: http, onProgress: onProgress)
        try await send(first, host: host, port: port)
        onSent(first)

        onProgress("Проверяю воспроизведение…")
        let firstCheck = await didPlay(host: host, port: port)
        if firstCheck.playing {
            return PlayResult(resolved: first, confirmed: true)
        }

        if firstCheck.playerExists {
            AppLog.shared.log("Play: PLAY_NFO есть, воспроизведение не подтвердилось — повтор не шлю")
            return PlayResult(resolved: first, confirmed: false)
        }

        // плеер не поднялся — ссылка умерла до старта; свежая ссылка
        AppLog.shared.log("Play: плеер не поднялся — повтор со свежей ссылкой")
        onProgress("Не заиграло — пробую ещё раз со свежей ссылкой…")
        let second = try await resolve(query, http: http, onProgress: onProgress)
        try await send(second, host: host, port: port)

        onProgress("Проверяю воспроизведение…")
        let secondCheck = await didPlay(host: host, port: port)
        if secondCheck.playing {
            return PlayResult(resolved: second, confirmed: true)
        }
        if secondCheck.playerExists {
            AppLog.shared.log("Play: повтор принят, но не подтвердился")
            return PlayResult(resolved: second, confirmed: false)
        }
        throw AppError.cast(
            "Сервер принял команду, но видео не началось. Попробуйте ещё раз или другой плеер в настройках"
        )
    }

    /// Первая попытка иногда падает с «Network is down» — пока iOS показывает
    /// запрос доступа к локальной сети или Wi-Fi моргнул; один повтор через 0,7 c.
    private static func send(_ resolved: Resolved, host: String, port: Int) async throws {
        let payload = String(decoding: resolved.message, as: UTF8.self)
        do {
            try await sendOnce(payload, host: host, port: port)
        } catch XRemoteError.connectionFailed {
            AppLog.shared.log("Play: подключение/отправка не удались, повтор через 0,7 c")
            try? await Task.sleep(nanoseconds: 700_000_000)
            try await sendOnce(payload, host: host, port: port)
        }
    }

    private static func sendOnce(_ payload: String, host: String, port: Int) async throws {
        let client = try XRemoteClient(host: host, port: port)
        let response = try await client.send(payload)
        try requireSuccess(response)
    }

    /// Опрос GET_PLAY_INFO: видео началось? COMMAND_SUCCESS сам по себе не значит,
    /// что играет — CVH стартует 2–3 c, Kodik 5–8 c, иногда рапортует
    /// IS_PLAYING=false даже при идущем видео, поэтому засчитываем любой из
    /// признаков: IS_PLAYING, POSITION > 0 или DURATION > 0.
    /// Возврат: playing — точно играет; playerExists — плеер поднят (PLAY_NFO есть).
    /// Два подряд PLAYER_NOT_RUNNING (~5 c) — ссылка мертва, выходим раньше
    /// для быстрого повтора со свежей ссылкой.
    private static func didPlay(host: String, port: Int, seconds: Double = 20) async -> (playing: Bool, playerExists: Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        var attempts = 0
        var playerExists = false
        var notRunningInRow = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            attempts += 1
            guard let client = try? XRemoteClient(host: host, port: port),
                  let response = try? await client.send(String(decoding: CastMessage.getPlayInfo(), as: UTF8.self)) else {
                AppLog.shared.log("Play: опрос \(attempts) — ошибка запроса")
                continue
            }
            if response.response == "PLAYER_NOT_RUNNING" {
                notRunningInRow += 1
                AppLog.shared.log("Play: опрос \(attempts) — PLAYER_NOT_RUNNING (\(notRunningInRow) подряд)")
                if notRunningInRow >= 2 {
                    return (false, false)
                }
                continue
            }
            notRunningInRow = 0
            guard let info = response.json["PLAY_NFO"] as? [String: Any] else {
                AppLog.shared.log("Play: опрос \(attempts) — нет PLAY_NFO")
                continue
            }
            playerExists = true
            let isPlaying = info["IS_PLAYING"] as? Bool ?? false
            let position = (info["POSITION"] as? Double) ?? 0
            let duration = (info["DURATION"] as? Double) ?? 0
            AppLog.shared.log(
                "Play: опрос \(attempts) — IS_PLAYING=\(isPlaying), POS=\(position), DUR=\(duration)"
            )
            if isPlaying || position > 0 || duration > 0 {
                return (true, true)
            }
        }
        return (false, playerExists)
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
