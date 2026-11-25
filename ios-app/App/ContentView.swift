import SwiftUI
import UIKit

/// Контейнерное приложение: инструкция + история просмотров.
/// История заполняется автоматически: после успешной отправки Share Extension
/// открывает приложение (animegocast://resume?...) и передаёт тайтл, серию,
/// телевизор и плеер. Отсюда же можно продолжить просмотр без Safari.
struct ContentView: View {
    @StateObject private var history = HistoryStore()
    @StateObject private var profiles = TvProfileStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                if !history.entries.isEmpty {
                    Section("История") {
                        ForEach(history.entries) { entry in
                            NavigationLink {
                                ResumeView(entry: entry, history: history, profiles: profiles)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(entry.title)
                                        .lineLimit(1)
                                    Text("эпизод \(entry.episodeNumber) · "
                                            + entry.watchedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { positions in
                            for index in positions where index < history.entries.count {
                                history.remove(history.entries[index])
                            }
                        }
                    }
                }
                Section("Что это") {
                    Text("AnimeGO Cast отправляет серию аниме с animego.me на AniLabX на телевизоре.")
                    Text("Ничего не скачивается: телевизор получает прямую ссылку и играет сам.")
                    Text("После каждой отправки серия попадает в «Историю».")
                    Text("Продолжить просмотр можно прямо отсюда, без Safari.")
                }
                Section("Как пользоваться") {
                    Text("1. В Safari откройте страницу тайтла на animego.me.")
                    Text("2. Нажмите «Поделиться».")
                    Text("3. Выберите «AnimeGO Cast».")
                    Text("4. Нажмите на серию (и телевизор, если их несколько) — она запустится.")
                    Text("Плеер, озвучка и профили телевизоров настраиваются внутри самой панели.")
                }
                Section("Если телевизор не отвечает") {
                    Text("• Телефон и телевизор должны быть в одной Wi-Fi-сети, AniLabX — запущен.")
                    Text("• Доступ к локальной сети: при первом запуске iOS спросит разрешение — ответьте «Разрешить».")
                    Text("• Если отказали: Настройки → Приватность и безопасность → Локальная сеть → включите AnimeGO Cast.")
                    Text("• Проверьте адрес телевизора в расширении (кнопка «Профили» → «Проверить»).")
                }
            }
            .navigationTitle("AnimeGO Cast")
            .onOpenURL { url in
                if let payload = HistoryHandoff.parse(url) {
                    applyHandoff(payload)
                }
            }
            .onAppear { importPasteboardHistory() }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    importPasteboardHistory()
                }
            }
        }
    }

    /// История из расширения приходит по буферу обмена (см. HistoryPasteboard):
    /// читаем только если changeCount изменился — чужое содержимое не трогаем.
    private func importPasteboardHistory() {
        let defaults = UserDefaults.standard
        let countKey = "history_paste_count"
        let count = UIPasteboard.general.changeCount
        guard count != defaults.integer(forKey: countKey) else { return }
        defaults.set(count, forKey: countKey)
        AppLog.shared.log("Приложение: буфер изменился (count=\(count)), проверяю payload")
        guard let payload = HistoryPasteboard.readPayload() else { return }
        HistoryPasteboard.clear()
        applyHandoff(payload)
    }

    private func applyHandoff(_ payload: HistoryHandoff.Payload) {
        AppLog.shared.log("Приложение: handoff — \(payload.title) эп.\(payload.episodeNumber)")
        history.upsert(url: payload.url, title: payload.title, episodeNumber: payload.episodeNumber)
        if let name = payload.tvName, let host = payload.tvHost, let port = payload.tvPort {
            profiles.upsert(name: name, host: host, port: port)
        }
        let prefs = CastPreferences()
        if let player = payload.playerKey {
            prefs.playerKey = player
        }
        if let dub = payload.dub {
            prefs.dub = dub
        }
    }
}
