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
            if !providerLines.isEmpty {
                Section("Плееры (серия 1)") {
                    ForEach(providerLines, id: \.self) { line in
                        Text(line)
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

    /// «CVH: Dream Cast, AniLiberty» / «Kodik: …»
    private var providerLines: [String] {
        var lines: [String] = []
        for (key, title) in [("cvh", "CVH"), ("kodik", "Kodik")] {
            let dubs = viewModel.providersPreview
                .filter { $0.key == key }
                .map { $0.dub }
            if !dubs.isEmpty {
                lines.append("\(title): \(dubs.joined(separator: ", "))")
            }
        }
        return lines
    }
}
