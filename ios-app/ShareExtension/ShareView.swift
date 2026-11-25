import SwiftUI

/// Главный экран расширения: тайтл, плееры, список серий, одна строка статуса.
struct ShareView: View {
    @ObservedObject var viewModel: ShareViewModel

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
                    Button("Эпизод \(episode.number)") {
                        viewModel.cast(episode)
                    }
                    .disabled(viewModel.casting)
                }
            }
            Section {
                Text(viewModel.statusText)
                    .foregroundStyle(viewModel.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                if viewModel.canFinish {
                    Button("Готово") { viewModel.finish() }
                }
            }
        }
        .navigationTitle("AnimeGO Cast")
    }
}
