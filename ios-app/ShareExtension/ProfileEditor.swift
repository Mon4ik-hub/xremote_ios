import SwiftUI

/// Добавление или редактирование профиля: имя, IP/хост, порт + кнопка «Проверить» (PING).
struct ProfileEditor: View {
    @ObservedObject var store: TvProfileStore
    let existing: TvProfile?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var message = ""
    @State private var checking = false

    init(store: TvProfileStore, existing: TvProfile?) {
        self.store = store
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _host = State(initialValue: existing?.host ?? "")
        _port = State(initialValue: existing.map { String($0.port) } ?? "31337")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Имя", text: $name, prompt: Text("Телевизор"))
                    TextField("IP / хост", text: $host, prompt: Text("192.168.1.140"))
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Порт", text: $port)
                        .keyboardType(.numberPad)
                }
                Section {
                    Button("Проверить") {
                        checking = true
                        Task {
                            message = await TVCheck.run(host: host, port: port)
                            checking = false
                        }
                    }
                    .disabled(checking)
                    if !message.isEmpty {
                        Text(message)
                            .foregroundStyle(checkResultIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    }
                } footer: {
                    Text("Отправляет PING этому адресу и показывает ответ.")
                }
                Section {
                    Button("Сохранить") { save() }
                    if existing != nil {
                        Button("Удалить", role: .destructive) { delete() }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Новый телевизор" : "Редактирование")
            .toolbar {
                Button("Отмена") { dismiss() }
            }
        }
    }

    private var checkResultIsError: Bool {
        message != "Сервер отвечает"
    }

    private func save() {
        guard let address = TvProfileStore.validatedAddress(host: host, port: port) else {
            message = "Неверный адрес — нужен IP или хост и порт 1–65535"
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? address.host : trimmedName
        if var profile = existing {
            profile.name = finalName
            profile.host = address.host
            profile.port = address.port
            store.update(profile)
        } else {
            store.add(TvProfile(name: finalName, host: address.host, port: address.port))
        }
        dismiss()
    }

    private func delete() {
        guard let profile = existing else { return }
        guard store.profiles.count > 1 else {
            message = "Единственный профиль удалить нельзя"
            return
        }
        store.remove(id: profile.id)
        dismiss()
    }
}

/// PING конкретному адресу для кнопки «Проверить».
enum TVCheck {
    static func run(host: String, port: String) async -> String {
        guard let address = TvProfileStore.validatedAddress(host: host, port: port),
              let client = try? XRemoteClient(host: address.host, port: address.port) else {
            return "Неверный адрес — нужен IP или хост и порт 1–65535"
        }
        do {
            let payload = String(decoding: try CastMessage.ping(), as: UTF8.self)
            let response = try await client.send(payload)
            if response.response == "ALIVE" {
                return "Сервер отвечает"
            }
            return "Ответ сервера: \(response.response ?? "без поля RESPONSE")"
        } catch {
            return ShareViewModel.errorText(error)
        }
    }
}
