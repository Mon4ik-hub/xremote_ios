import SwiftUI

struct ShareView: View {
    @ObservedObject var viewModel: ShareViewModel

    var body: some View {
        Form {
            Section {
                Text(viewModel.statusText)
                    .foregroundStyle(viewModel.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            }
            Section {
                Button("Готово") { viewModel.finish() }
            }
        }
        .navigationTitle("AnimeGO Cast")
    }
}
