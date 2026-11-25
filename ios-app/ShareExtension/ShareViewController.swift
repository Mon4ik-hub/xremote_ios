import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Точка входа Share Extension: достаёт URL из «Поделиться» и отдаёт SwiftUI-экрану.
final class ShareViewController: UIViewController {
    private let viewModel = ShareViewModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        embedSwiftUI()
        viewModel.onFinish = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        Task { await loadIncomingURL() }
    }

    private func embedSwiftUI() {
        let hosting = UIHostingController(rootView: ShareView(viewModel: viewModel))
        let nav = UINavigationController(rootViewController: hosting)
        addChild(nav)
        nav.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nav.view)
        NSLayoutConstraint.activate([
            nav.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nav.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nav.view.topAnchor.constraint(equalTo: view.topAnchor),
            nav.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        nav.didMove(toParent: self)
    }

    private func loadIncomingURL() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var url: URL?
        for item in items {
            for attachment in item.attachments ?? [] {
                if let found = try? await attachment.loadSharedURL() {
                    url = found
                    break
                }
            }
            if url != nil { break }
        }
        await viewModel.handleIncomingURL(url)
    }
}

extension NSItemProvider {
    /// URL из «Поделиться»; иногда Safari кладёт его как текст.
    func loadSharedURL() async throws -> URL? {
        if hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let item = try await loadItem(forTypeIdentifier: UTType.url.identifier)
            if let url = item as? URL { return url }
            if let nsurl = item as? NSURL { return nsurl as URL? }
            if let string = item as? String { return URL(string: string) }
        }
        if hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let item = try await loadItem(forTypeIdentifier: UTType.plainText.identifier)
            if let string = item as? String {
                return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return nil
    }
}
