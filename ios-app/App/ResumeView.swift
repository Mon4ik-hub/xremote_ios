import SwiftUI

/// Продолжение просмотра из истории: серии тайтла грузит само приложение
/// (Core собран и в него), отправка — выбранным плеером на телевизор из профиля.
struct ResumeView: View {
    let entry: HistoryEntry
    @ObservedObject var history: HistoryStore
    @ObservedObject var profiles: TvProfileStore
    @StateObject private var viewModel: ResumeViewModel
    @State private var pickingEpisode: Episode?

    init(entry: HistoryEntry, history: HistoryStore, profiles: TvProfileStore) {
        self.entry = entry
        self.history = history
        self.profiles = profiles
        _viewModel = StateObject(wrappedValue: ResumeViewModel(url: entry.url, title: entry.title))
    }

    var body: some View {
        Form {
            if let meta = viewModel.meta {
                Section("Тайтл") {
                    Text(meta.title).font(.headline)
                }
            }
            if !viewModel.dubOptions.isEmpty {
                Section("Настройки") {
                    Picker("Плеер", selection: Binding(
                        get: { viewModel.playerKey },
                        set: { viewModel.selectPlayer($0) }
                    )) {
                        Text("CVH").tag("cvh")
                        Text("Kodik").tag("kodik")
                    }
                    .pickerStyle(.segmented)
                    Picker("Озвучка", selection: Binding(
                        get: { viewModel.selectedDub },
                        set: { viewModel.selectDub($0) }
                    )) {
                        ForEach(viewModel.dubOptions, id: \.self) { dub in
                            Text(dub).tag(dub)
                        }
                    }
                }
            }
            Section("Серии") {
                ForEach(viewModel.episodes) { episode in
                    episodeRow(episode)
                }
            }
            Section {
                Text(viewModel.statusText)
                    .foregroundStyle(viewModel.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            }
        }
        .navigationTitle("Продолжить")
        .task { await viewModel.load() }
        .sheet(item: $pickingEpisode) { episode in
            TVPickerView(store: profiles, episode: episode) { _ in
                pickingEpisode = nil
                Task {
                    await viewModel.cast(episode, profiles: profiles, history: history)
                }
            }
        }
    }

    @ViewBuilder
    private func episodeRow(_ episode: Episode) -> some View {
        Button {
            if profiles.profiles.count <= 1, let profile = profiles.profiles.first {
                Task { await viewModel.cast(episode, profiles: profiles, history: history) }
            } else {
                pickingEpisode = episode
            }
        } label: {
            HStack {
                if viewModel.watched.contains(episode.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text("Эпизод \(episode.number)")
                    .foregroundStyle(
                        viewModel.watched.contains(episode.id)
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(.primary)
                    )
            }
        }
        .disabled(viewModel.casting)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                viewModel.toggleWatched(episode)
            } label: {
                Label(
                    viewModel.watched.contains(episode.id) ? "Не смотрел" : "Просмотрено",
                    systemImage: viewModel.watched.contains(episode.id) ? "circle" : "checkmark"
                )
            }
            .tint(viewModel.watched.contains(episode.id) ? .gray : .green)
        }
    }
}

/// Вью-модель продолжения просмотра (та же цепочка, что в расширении).
@MainActor
final class ResumeViewModel: ObservableObject {
    @Published var statusText = "Загрузка…"
    @Published var isError = false
    @Published var casting = false
    @Published var meta: AnimeMeta?
    @Published var episodes: [Episode] = []
    @Published var providersPreview: [ProviderItem] = []
    @Published private(set) var playerKey: String
    @Published private(set) var selectedDub: String
    @Published private(set) var watched: Set<String>

    private let url: URL
    private let entryTitle: String
    private let prefs = CastPreferences()
    private let watchedStore = WatchedStore()
    private let http = HttpClient()

    init(url: String, title: String) {
        self.url = URL(string: url) ?? URL(string: AnimeGoClient.base)!
        entryTitle = title
        playerKey = prefs.playerKey
        selectedDub = prefs.dub
        watched = watchedStore.all()
    }

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

    private func normalizeDub() {
        let options = dubOptions
        if !options.contains(selectedDub) {
            selectedDub = options.first ?? ""
        }
        prefs.dub = selectedDub
    }

    func toggleWatched(_ episode: Episode) {
        watchedStore.toggle(episode.id)
        watched = watchedStore.all()
    }

    func load() async {
        statusText = "Читаю страницу…"
        isError = false
        do {
            let animego = AnimeGoClient(http: http)
            let loadedMeta = try await animego.fetchAnimeMeta(animeUrl: url.absoluteString)
            meta = loadedMeta
            episodes = try await animego.fetchEpisodes(
                animeUrl: url.absoluteString,
                animeId: loadedMeta.animeId
            )
            statusText = episodes.isEmpty ? "Серии не найдены" : "Найдено серий: \(episodes.count)"
            if let first = episodes.first {
                providersPreview = (try? await animego.fetchProviders(
                    animeUrl: url.absoluteString,
                    episodeId: first.id
                )) ?? []
                normalizeDub()
            }
        } catch {
            statusText = AppError.humanText(error)
            isError = true
        }
    }

    func cast(_ episode: Episode, profiles: TvProfileStore, history: HistoryStore) async {
        AppLog.shared.log("Продолжить: отправка эп.\(episode.number) (плеер=\(playerKey)/\(selectedDub))")
        guard let profile = profiles.lastUsed ?? profiles.profiles.first else {
            statusText = "Нет телевизора — настройте профиль в расширении"
            isError = true
            return
        }
        casting = true
        statusText = "Ищу ссылку…"
        isError = false
        defer { casting = false }
        do {
            let resolved = try await CastResolver.resolve(
                .init(
                    episode: episode,
                    title: meta?.title ?? entryTitle,
                    urlString: url.absoluteString,
                    playerKey: playerKey,
                    selectedDub: selectedDub
                ),
                http: http,
                onProgress: { statusText = $0 }
            )
            let client = try XRemoteClient(host: profile.host, port: profile.port)
            let payload = String(decoding: resolved.message, as: UTF8.self)
            let response = try await client.send(payload)
            try CastResolver.requireSuccess(response)
            statusText = "Запущено на «\(profile.name)»: эпизод \(episode.number), \(resolved.qualityName)"
            profiles.markUsed(id: profile.id)
            watchedStore.markWatched(episode.id)
            watched = watchedStore.all()
            history.upsert(
                url: url.absoluteString,
                title: meta?.title ?? entryTitle,
                episodeNumber: episode.number
            )
        } catch {
            statusText = AppError.humanText(error)
            isError = true
        }
    }
}
