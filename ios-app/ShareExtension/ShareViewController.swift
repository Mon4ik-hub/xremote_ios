import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Точка входа Share Extension: достаёт URL из «Поделиться» и отдаёт SwiftUI-экрану.
/// Навигация — внешний UINavigationController, экраны — UIHostingController.
final class ShareViewController: UIViewController {
    private let viewModel = ShareViewModel()
    private weak var navController: UINavigationController?

    override func viewDidLoad() {
        super.viewDidLoad()
        embedSwiftUI()
        viewModel.onFinish = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        viewModel.onShowProfiles = { [weak self] in
            self?.push(ProfilesView(store: self?.viewModel.store ?? TvProfileStore()))
        }
        viewModel.onShowTVPicker = { [weak self] episode in
            self?.push(TVPickerView(
                store: self?.viewModel.store ?? TvProfileStore(),
                episode: episode,
                onSelect: { [weak self] profile in
                    Task { await self?.viewModel.cast(episode, to: profile) }
                }
            ))
        }
        viewModel.onPopToRoot = { [weak self] in
            self?.navController?.popToRootViewController(animated: true)
        }
        viewModel.onOpenApp = { [weak self] url in
            // handoff в приложение: записать историю; после открытия расширение закрывается
            guard let context = self?.extensionContext else { return }
            context.open(url) { _ in
                context.completeRequest(returningItems: nil, completionHandler: nil)
            }
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
            nav.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        nav.didMove(toParent: self)
        navController = nav
    }

    private func push(_ view: some View) {
        navController?.pushViewController(UIHostingController(rootView: view), animated: true)
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
