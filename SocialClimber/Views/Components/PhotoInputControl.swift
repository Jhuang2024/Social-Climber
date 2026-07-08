import SwiftUI
import PhotosUI
import UIKit

/// A reusable "take or choose a photo" control shared by every feature that
/// needs to hand a photo to a vision AI call (Fit Checker's outfit photo, How
/// to Respond's conversation screenshots), same camera + library affordance,
/// loading/error handling, and card styling everywhere instead of each
/// feature rolling its own. Not for the multi-select-then-OCR screenshot flow
/// in `AddInteractionView`, which has its own on-device text pipeline.
struct PhotoInputControl: View {
    @Binding var images: [UIImage]
    /// 1 for a single outfit/profile-style photo; >1 to capture a scrolling
    /// conversation across a few screenshots.
    var maxCount: Int = 1
    var placeholderIcon: String = "camera.on.rectangle"
    var placeholderText: String = "Add a photo"

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    private var isFull: Bool { images.count >= maxCount }
    private var remainingSlots: Int { max(1, maxCount - images.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if images.isEmpty {
                placeholder
            } else if maxCount == 1 {
                singlePreview
            } else {
                thumbnailRow
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading photo…").foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            if !isFull {
                HStack(spacing: 10) {
                    if cameraAvailable {
                        Button {
                            showCamera = true
                        } label: {
                            Label("Take Photo", systemImage: "camera")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.secondaryCTA)
                    }
                    PhotosPicker(selection: $photoItems, maxSelectionCount: remainingSlots, matching: .images) {
                        Label(images.isEmpty ? "Choose Photo\(maxCount > 1 ? "s" : "")" : "Add More", systemImage: "photo.on.rectangle")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.secondaryCTA)
                }
            }

            if !images.isEmpty {
                Button(role: .destructive) {
                    images.removeAll()
                    photoItems.removeAll()
                    errorMessage = nil
                } label: {
                    Label("Remove Photo\(images.count > 1 ? "s" : "")", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraCaptureView { captured in
                if let captured, images.count < maxCount { images.append(captured) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await load(items) }
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous)
                .fill(.thinMaterial)
            VStack(spacing: 8) {
                Image(systemName: placeholderIcon)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(placeholderText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 180)
        .frame(maxWidth: .infinity)
    }

    private var singlePreview: some View {
        Image(uiImage: images[0])
            .resizable()
            .scaledToFill()
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
            .clipped()
    }

    private var thumbnailRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 120, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
                            .clipped()
                        Button {
                            images.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .padding(6)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @MainActor
    private func load(_ items: [PhotosPickerItem]) async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            photoItems = []
        }
        for item in items {
            guard images.count < maxCount else { break }
            do {
                guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    errorMessage = "One of those photos couldn't be loaded. Try another image."
                    continue
                }
                images.append(image)
            } catch {
                errorMessage = "Photo access failed. Allow Photos access in iOS Settings and try again."
            }
        }
    }
}
