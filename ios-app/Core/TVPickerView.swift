import SwiftUI

/// Выбор телевизора при отправке серии (когда профилей несколько).
/// Первый в списке — последний использованный.
struct TVPickerView: View {
    @ObservedObject var store: TvProfileStore
    let episode: Episode
    let onSelect: (TvProfile) -> Void

    var body: some View {
        Form {
            Section("Куда отправить эпизод \(episode.number)") {
                ForEach(store.profiles) { profile in
                    Button {
                        onSelect(profile)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(profile.name)
                            Text(profile.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Телевизор")
    }
}
