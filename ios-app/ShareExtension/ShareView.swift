import SwiftUI

/// Главный экран расширения: тайтл, плееры, список серий, одна строка статуса.
struct ShareView: View {
    @ObservedObject var viewModel: ShareViewModel
    @State private var showingLog = false

    var body: some View {
        Form {
            if let meta = viewModel.meta {
                Section("Тайтл") {
                    Text(meta.title).font(.headline)
                }
            }
            Section("Телевизор") {
                if let last = viewModel.store.lastUsed {
                    Text("\(last.name) — \(last.address)")
                }
                Button("Профили") { viewModel.onShowProfiles?() }
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
                    Button {
                        viewModel.cast(episode)
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
            Section {
                Text(viewModel.statusText)
                    .foregroundStyle(viewModel.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                if viewModel.handoffURL != nil {
                    Button("Записать в историю приложения") { viewModel.recordToApp() }
                }
                if viewModel.canFinish {
                    Button("Готово") { viewModel.finish() }
                }
                Button("Журнал") {
                    showingLog = true
                }
                .font(.footnote)
            }
        }
        .navigationTitle("AnimeGO Cast")
        .sheet(isPresented: $showingLog) {
            LogSheet()
        }
    }
}
