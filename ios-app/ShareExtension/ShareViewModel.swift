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
    /// Плееры первой серии: из них собираются озвучки выбранного плеера.
    @Published var providersPreview: [ProviderItem] = []
    @Published private(set) var store: TvProfileStore
    /// Плеер по умолчанию выбирает пользователь ("cvh" | "kodik").
    @Published private(set) var playerKey: String
    /// Выбранная озвучка (зависит от плеера); пустая строка — «первая доступная».
    @Published private(set) var selectedDub: String
    /// Просмотренные серии (id из data-episode).
    @Published private(set) var watched: Set<String>
    private(set) var inputURL: URL?

    private let prefs = CastPreferences()
    private let watchedStore = WatchedStore()

    var onFinish: (() -> Void)?
    var onShowProfiles: (() -> Void)?
    var onShowTVPicker: ((Episode) -> Void)?
    var onPopToRoot: (() -> Void)?
    /// Открыть приложение с handoff-ссылкой (запись в «Историю»); работает,
    /// только если вызвать прямо по нажатию кнопки — отложенный вызов iOS
    /// отклоняет и просто закрывает панель.
    var onOpenApp: ((URL, @escaping (Bool) -> Void) -> Void)?
    /// Ссылка для кнопки «Записать в историю приложения» (после успешной отправки).
    @Published private(set) var handoffURL: URL?

    private let http = HttpClient()
    private lazy var animego = AnimeGoClient(http: http)

    init(store: TvProfileStore = TvProfileStore()) {
        self.store = store
        playerKey = prefs.playerKey
        selectedDub = prefs.dub
        watched = watchedStore.all()
    }

    /// Ручная пометка «Просмотрено» (свайп по строке серии).
    func toggleWatched(_ episode: Episode) {
        watchedStore.toggle(episode.id)
        watched = watchedStore.all()
    }

    // MARK: - Выбор плеера и озвучки

    /// Доступные озвучки выбранного плеера (по первой серии).
    var dubOptions: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for provider in providersPreview where provider.key == playerKey {
            if seen.insert(provider.dub).inserted {
                out.append(provider.dub)
            }
        }
        return out
    }

    func selectPlayer(_ key: String) {
        playerKey = key
        prefs.playerKey = key
        normalizeDub()
    }

    func selectDub(_ dub: String) {
        selectedDub = dub
        prefs.dub = dub
    }

    /// Если выбранная озвучка недоступна у нового плеера — берём первую из списка.
    private func normalizeDub() {
        let options = dubOptions
        if !options.contains(selectedDub) {
            selectedDub = options.first ?? ""
        }
        prefs.dub = selectedDub
    }

    // MARK: - Вход и загрузка страницы

    func handleIncomingURL(_ url: URL?) async {
        AppLog.shared.log("Панель: вход url=\(url?.absoluteString ?? "nil")")
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
            AppLog.shared.log("Панель: «\(loadedMeta.title)» id=\(loadedMeta.animeId), серий \(loadedEpisodes.count)")
            canFinish = true
            if let first = loadedEpisodes.first {
                providersPreview = (try? await animego.fetchProviders(
                    animeUrl: url.absoluteString,
                    episodeId: first.id
                )) ?? []
                normalizeDub()
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
        AppLog.shared.log("Панель: отправка эп.\(episode.number) на «\(profile.name)» (\(playerKey)/\(selectedDub))")
        casting = true
        statusText = "Ищу ссылку…"
        isError = false
        handoffURL = nil
        defer { casting = false }
        do {
            guard let meta, let urlString = inputURL?.absoluteString else {
                throw AppError.cast("Страница ещё не загружена")
            }
            let resolved = try await CastResolver.play(
                query: .init(
                    episode: episode,
                    title: meta.title,
                    urlString: urlString,
                    playerKey: playerKey,
                    selectedDub: selectedDub
                ),
                host: profile.host,
                port: profile.port,
                http: http,
                onProgress: { statusText = $0 },
                onSent: { _ in
                    // история пишется сразу после принятия команды сервером,
                    // не дожидаясь подтверждения воспроизведения
                    let handoffPayload = HistoryHandoff.Payload(
                        url: urlString,
                        title: meta.title,
                        episodeNumber: episode.number,
                        episodeId: episode.id,
                        tvName: profile.name,
                        tvHost: profile.host,
                        tvPort: profile.port,
                        playerKey: playerKey,
                        dub: selectedDub
                    )
                    HistoryPasteboard.write(handoffPayload)
                    handoffURL = HistoryHandoff.makeURL(handoffPayload) // для кнопки «Записать в историю»
                }
            )
            statusText = "Запущено на «\(profile.name)»: эпизод \(episode.number), \(resolved.qualityName)"
            AppLog.shared.log("Панель: играет, эп.\(episode.number) на «\(profile.name)»")
            store.markUsed(id: profile.id)
            watchedStore.markWatched(episode.id) // отправленная серия = просмотренная
            watched = watchedStore.all()
        } catch {
            AppLog.shared.log("Панель: ошибка отправки — \(AppError.humanText(error))")
            fail(AppError.humanText(error))
            onPopToRoot?()
        }
    }

    /// По нажатию кнопки: открыть приложение и записать тайтл в «Историю».
    func recordToApp() {
        guard let handoffURL else { return }
        AppLog.shared.log("Панель: «Записать в историю» — открываю приложение")
        onOpenApp?(handoffURL) { [weak self] opened in
            if opened {
                AppLog.shared.log("Панель: приложение открылось, история записана")
            } else {
                self?.statusText = "Не удалось открыть приложение — история не записана"
                self?.isError = true
                self?.canFinish = true
                AppLog.shared.log("Панель: open() отклонён iOS")
            }
        }
    }

    // MARK: - Служебное

    private func fail(_ message: String) {
        statusText = message
        isError = true
        canFinish = true
    }

    nonisolated static func errorText(_ error: Error) -> String {
        AppError.humanText(error)
    }

    func finish() {
        onFinish?()
    }
}
