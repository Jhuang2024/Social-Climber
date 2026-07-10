import UIKit
import UniformTypeIdentifiers

/// The Share Extension's entry point. Appears when the user shares text
/// (selected Messages bubbles, a paragraph) or images (screenshots) to
/// Social Climber. It stages everything into the App Group queue as a
/// capture payload, confirms with "Saved to Social Climber", and closes
/// immediately — the main app imports and organizes it automatically the
/// next time it's active, without asking the user to finish anything.
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
        let imageNames = await stageImages()
        spinner.stopAnimating()

        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imageNames.isEmpty else {
            statusLabel.text = "Couldn't find anything to save."
            try? await Task.sleep(for: .seconds(1.2))
            complete()
            return
        }

        SharedImportInbox.add(SharedImportEntry(
            text: trimmed,
            imageFileNames: imageNames,
            sourceApp: sourceApplicationIdentifier() ?? ""
        ))
        statusLabel.text = "Saved to Social Climber"
        try? await Task.sleep(for: .seconds(0.7))
        complete()
    }

    /// The host app's bundle identifier, when iOS provides it.
    private func sourceApplicationIdentifier() -> String? {
        // NSExtensionItem doesn't carry the source app directly; the
        // extension context's userInfo sometimes does on newer systems.
        (extensionContext?.inputItems.first as? NSExtensionItem)?
            .userInfo?["NSExtensionItemSourceApplicationKey"] as? String
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

    /// Copies every shared image into the App Group container so the main
    /// app can pick it up later; the image never leaves the device and is
    /// OCR'd locally by the app. Returns the staged file names.
    private func stageImages() async -> [String] {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem],
              let directory = SharedImportInbox.imagesDirectory else { return [] }
        var names: [String] = []

        for item in items {
            for provider in item.attachments ?? [] {
                guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { continue }
                guard let data = await loadImageData(from: provider) else { continue }
                let name = "\(UUID().uuidString).jpg"
                let url = directory.appendingPathComponent(name)
                if (try? data.write(to: url, options: .atomic)) != nil {
                    names.append(name)
                }
            }
        }
        return names
    }

    private func loadImageData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                switch item {
                case let data as Data:
                    continuation.resume(returning: data)
                case let url as URL:
                    continuation.resume(returning: try? Data(contentsOf: url))
                case let image as UIImage:
                    continuation.resume(returning: image.jpegData(compressionQuality: 0.9))
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
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
