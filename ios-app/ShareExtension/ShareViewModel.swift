import Foundation
import SwiftUI

/// Скелет вью-модели: наполняется логикой в шаге «экраны» (Core подключается там же).
@MainActor
final class ShareViewModel: ObservableObject {
    @Published var statusText = "Загрузка…"
    @Published var isError = false
    @Published var canFinish = false

    var onFinish: (() -> Void)?

    func handleIncomingURL(_ url: URL?) async {
        guard let url else {
            fail("Это не страница аниме на animego.me")
            return
        }
        let host = url.host?.lowercased() ?? ""
        guard host == "animego.me" || host == "www.animego.me", url.path.hasPrefix("/anime/") else {
            fail("Это не страница аниме на animego.me")
            return
        }
        statusText = "Страница распознана"
        canFinish = true
    }

    private func fail(_ message: String) {
        statusText = message
        isError = true
        canFinish = true
    }

    func finish() {
        onFinish?()
    }
}
