import UIKit
import UniformTypeIdentifiers

/// The Share Extension's entry point. Appears when the user selects one or
/// more messages in Messages (or anything else offering plain text to the
/// system share sheet) and taps Share → Social Climber. Pulls the shared
/// text out, queues it via `SharedImportInbox` for the main app to pick up
/// next time it's opened, and shows a brief confirmation before closing;
/// no compose UI, nothing to edit here (that happens in the app, where the
/// existing paste-import review flow already lives).
///
/// No `@objc(ShareViewController)` override here on purpose: the
/// extension's Info.plist looks this class up as
/// `$(PRODUCT_MODULE_NAME).ShareViewController`, which relies on Swift's
/// *default* `ModuleName.ClassName` runtime name. An explicit `@objc` name
/// would strip that module prefix and break the lookup.
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureLayout()
        Task { await handleSharedItems() }
    }

    private func configureLayout() {
        view.backgroundColor = .systemBackground

        let iconView = UIImageView(image: UIImage(systemName: "sparkles"))
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.text = "Saving to Social Climber…"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [iconView, statusLabel, spinner])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    private func handleSharedItems() async {
        let text = await extractText()
        spinner.stopAnimating()

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusLabel.text = "Couldn't find any text to save."
            try? await Task.sleep(for: .seconds(1.2))
            complete()
            return
        }

        SharedImportInbox.add(text)
        statusLabel.text = "Saved. Open Social Climber to log it."
        try? await Task.sleep(for: .seconds(0.9))
        complete()
    }

    /// Walks every attachment on every input item looking for plain text:
    /// what Messages hands over when you multi-select bubbles and share.
    private func extractText() async -> String? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }
        var collected: [String] = []

        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = await loadText(from: provider, type: UTType.plainText.identifier) {
                    collected.append(text)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
                          let text = await loadText(from: provider, type: UTType.text.identifier) {
                    collected.append(text)
                }
            }
            // Some sources only populate this instead of an attachment.
            if let attributed = item.attributedContentText?.string, !attributed.isEmpty {
                collected.append(attributed)
            }
        }

        let combined = collected.joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
    }

    private func loadText(from provider: NSItemProvider, type: String) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                switch item {
                case let text as String:
                    continuation.resume(returning: text)
                case let data as Data:
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                case let url as URL:
                    continuation.resume(returning: try? String(contentsOf: url, encoding: .utf8))
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
