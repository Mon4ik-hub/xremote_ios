import Foundation
import SwiftUI

/// Логика Share Extension: разбор страницы, поиск прямой ссылки, отправка на телевизор.
@MainActor
final class ShareViewModel: ObservableObject {
    @Published var statusText = "Загрузка…"
    @Published var isError = false
    @Published var canFinish = false
    @Published var casting = false
    @Published var meta: AnimeMeta?
    @Published var episodes: [Episode] = []
    /// Плееры первой серии — чтобы показать плеер и озвучки ещё до отправки.
    @Published var providersPreview: [ProviderItem] = []
    @Published private(set) var store: TvProfileStore
    private(set) var inputURL: URL?

    var onFinish: (() -> Void)?
    var onShowProfiles: (() -> Void)?
    var onShowTVPicker: ((Episode) -> Void)?
    var onPopToRoot: (() -> Void)?

    private let http = HttpClient()
    private lazy var animego = AnimeGoClient(http: http)

    init(store: TvProfileStore = TvProfileStore()) {
        self.store = store
    }

    // MARK: - Вход и загрузка страницы

    func handleIncomingURL(_ url: URL?) async {
        guard let url, isAnimeTitlePage(url) else {
            fail("Это не страница аниме на animego.me")
            return
        }
        inputURL = url
        await load(url: url)
    }

    private func isAnimeTitlePage(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return (host == "animego.me" || host == "www.animego.me") && url.path.hasPrefix("/anime/")
    }

    private func load(url: URL) async {
        statusText = "Читаю страницу…"
        isError = false
        do {
            let loadedMeta = try await animego.fetchAnimeMeta(animeUrl: url.absoluteString)
            meta = loadedMeta
            let loadedEpisodes = try await animego.fetchEpisodes(
                animeUrl: url.absoluteString,
                animeId: loadedMeta.animeId
            )
            episodes = loadedEpisodes
            statusText = loadedEpisodes.isEmpty ? "Серии не найдены" : "Найдено серий: \(loadedEpisodes.count)"
            canFinish = true
            if let first = loadedEpisodes.first {
                providersPreview = (try? await animego.fetchProviders(
                    animeUrl: url.absoluteString,
                    episodeId: first.id
                )) ?? []
            }
        } catch {
            fail(Self.errorText(error))
        }
    }

    // MARK: - Отправка серии

    /// Один профиль — отправляем сразу; несколько — сначала выбор телевизора.
    func cast(_ episode: Episode) {
        guard !casting else { return }
        if let single = store.profiles.first, store.profiles.count == 1 {
            Task { await cast(episode, to: single) }
        } else {
            onShowTVPicker?(episode)
        }
    }

    func cast(_ episode: Episode, to profile: TvProfile) async {
        casting = true
        statusText = "Ищу ссылку…"
        isError = false
        defer { casting = false }
        do {
            let resolved = try await resolveCast(episode: episode)
            let client = try XRemoteClient(host: profile.host, port: profile.port)
            let payload = String(decoding: resolved.message, as: UTF8.self)
            let response = try await client.send(payload)
            try requireSuccess(response)
            statusText = "Запущено на «\(profile.name)»: эпизод \(episode.number), \(resolved.qualityName)"
            store.markUsed(id: profile.id)
        } catch {
            fail(Self.errorText(error))
        }
        onPopToRoot?()
    }

    private func resolveCast(episode: Episode) async throws -> (message: Data, qualityName: String) {
        guard let meta, let urlString = inputURL?.absoluteString else {
            throw AppError.cast("Страница ещё не загружена")
        }
        let providers = try await animego.fetchProviders(animeUrl: urlString, episodeId: episode.id)
        let candidates = castCandidates(providers)
        guard !candidates.isEmpty else {
            throw AppError.cast("У этого эпизода нет поддерживаемых плееров (нужны CVH или Kodik)")
        }

        // Ссылку получаем в последний момент и сразу возвращаем — CVH-ссылки
        // короткоживущие и не перезапрашиваются. Если CVH не сработал (например,
        // пустой плейлист) — пробуем Kodik и остальные озвучки.
        var lastError: Error?
        let attempts = Array(candidates.prefix(4))
        for (index, provider) in attempts.enumerated() {
            if index > 0 {
                statusText = attempts[index - 1].key == "cvh"
                    ? "CVH не сработал, пробую Kodik…"
                    : "Пробую другой плеер…"
            }
            do {
                return try await extractAndBuild(provider: provider, episode: episode, title: meta.title)
            } catch {
                lastError = error
            }
        }
        let reason = Self.errorText(lastError ?? AppError.parse("неизвестно"))
        throw AppError.cast("Ни один плеер не дал ссылку. Последняя ошибка: \(reason)")
    }

    /// Извлечение прямой ссылки одного плеера и сборка сообщения.
    private func extractAndBuild(provider: ProviderItem, episode: Episode, title: String) async throws -> (message: Data, qualityName: String) {
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
            contentId: "animego/" + episode.id,
            title: title,
            season: season,
            translation: provider.dub,
            episode: "\(episode.number) серия",
            qualityName: qualityName,
            directUrl: stream.url,
            embedUrl: provider.url,
            headersForDirect: headers
        ))
        return (message, qualityName)
    }

    /// Тип клиента в параметре srcAg: плеер AniLabX ходит как Chrome.
    private func srcAg(of url: String) -> String? {
        Regex("[?&]srcAg=([^&]+)").firstGroup(in: url)
    }

    private func requireSuccess(_ response: XRemoteResponse) throws {
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

    // MARK: - Служебное

    private func fail(_ message: String) {
        statusText = message
        isError = true
        canFinish = true
    }

    nonisolated static func errorText(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return error.localizedDescription
    }

    func finish() {
        onFinish?()
    }
}
