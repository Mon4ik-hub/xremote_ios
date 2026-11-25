import SwiftUI

/// Список профилей телевизоров: просмотр, добавление, редактирование, удаление.
struct ProfilesView: View {
    @ObservedObject var store: TvProfileStore
    @State private var editingProfile: TvProfile?
    @State private var addingProfile = false

    var body: some View {
        Form {
            Section {
                ForEach(store.profiles) { profile in
                    Button {
                        editingProfile = profile
                    } label: {
                        VStack(alignment: .leading) {
                            Text(profile.name)
                            Text(profile.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                // у единственного профиля удаление не показываем
                .onDelete(perform: store.profiles.count > 1 ? removePositions : nil)
            } footer: {
                Text("Нажмите на телевизор, чтобы изменить имя или адрес.")
            }
            Section {
                Button("Добавить телевизор") { addingProfile = true }
            }
        }
        .navigationTitle("Профили")
        .sheet(item: $editingProfile) { profile in
            ProfileEditor(store: store, existing: profile)
        }
        .sheet(isPresented: $addingProfile) {
            ProfileEditor(store: store, existing: nil)
        }
    }

    private func removePositions(_ positions: IndexSet) {
        for index in positions where index < store.profiles.count {
            store.remove(id: store.profiles[index].id)
        }
    }
}
