import Foundation
import Observation
import SwiftUI

/// Trusted event context handed to Quick Capture when it's opened from an
/// event or an event follow-up notification.
struct CaptureEventContext {
    var name: String
    var date: Date
    var location: String
    var attendeeNames: [String]
}

/// One request to open Quick Capture with some trusted context already
/// supplied (a person, an event, "start recording"). Routed through a
/// single presentation point in `RootTabView` so Home, profiles, App
/// Intents, and notification actions all share one sheet.
struct QuickCaptureRequest: Identifiable {
    let id = UUID()
    var trustedPersonNames: [String] = []
    var eventContext: CaptureEventContext?
    var startRecording = false
    var prefilledText: String = ""
    var typeHint: InteractionType?
}

@MainActor
@Observable
final class QuickCaptureRouter {
    static let shared = QuickCaptureRouter()
    private init() {}

    var pendingRequest: QuickCaptureRequest?

    func open(_ request: QuickCaptureRequest = QuickCaptureRequest()) {
        pendingRequest = request
    }

    func open(person: Person, startRecording: Bool = false, typeHint: InteractionType? = nil) {
        pendingRequest = QuickCaptureRequest(
            trustedPersonNames: [person.name],
            startRecording: startRecording,
            typeHint: typeHint
        )
    }

    func open(event: Event) {
        pendingRequest = QuickCaptureRequest(
            trustedPersonNames: event.attendees.map(\.name),
            eventContext: CaptureEventContext(
                name: event.name,
                date: event.date,
                location: event.location,
                attendeeNames: event.attendees.map(\.name)
            )
        )
    }
}

// MARK: - Toast

/// One small, non-blocking confirmation ("Remembered") with optional
/// actions ("Undo", "Add detail"). Rendered by `RootTabView`'s overlay so
/// it survives whichever sheet or screen triggered it dismissing itself.
struct ToastAction: Identifiable {
    let id = UUID()
    let title: String
    let handler: () -> Void
}

@MainActor
@Observable
final class ToastCenter {
    static let shared = ToastCenter()
    private init() {}

    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let icon: String
        let actions: [ToastAction]
    }

    var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, icon: String = "checkmark.circle.fill", actions: [ToastAction] = []) {
        let toast = Toast(message: message, icon: icon, actions: actions)
        current = toast
        dismissTask?.cancel()
        // Toasts with actions stay a little longer so they're actually
        // reachable; either way they never block anything.
        let duration: Duration = actions.isEmpty ? .seconds(2.6) : .seconds(5)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            if self?.current?.id == toast.id {
                withAnimation(.snappy) { self?.current = nil }
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.snappy) { current = nil }
    }
}

/// The toast view itself, overlaid at the root.
struct ToastOverlay: View {
    @State private var center = ToastCenter.shared

    var body: some View {
        VStack {
            Spacer()
            if let toast = center.current {
                HStack(spacing: 10) {
                    Image(systemName: toast.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                    Text(toast.message)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    ForEach(toast.actions) { action in
                        Button(action.title) {
                            center.dismiss()
                            action.handler()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SCTheme.accent)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.08))
                }
                .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                .padding(.bottom, 64)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: center.current?.id)
        .allowsHitTesting(center.current != nil)
    }
}

// MARK: - Pending outbound contact

/// Remembers that the user just launched a call/message/email to someone
/// from inside Social Climber, so that when the app returns to the
/// foreground it can ask — never assume — whether the contact happened.
/// The app cannot (and does not claim to) read call history or other
/// apps' data; this is purely "you tapped the button, did it work out?".
struct PendingOutboundContact: Codable {
    var personName: String
    var interactionTypeRaw: String
    var timestamp: Date

    var interactionType: InteractionType {
        InteractionType(rawValue: interactionTypeRaw) ?? .message
    }
}

enum OutboundContactStore {
    private static let key = "pendingOutboundContact"
    /// How long after tapping a contact method the return-prompt is still
    /// plausible; beyond this the moment has passed and asking is noise.
    private static let window: TimeInterval = 6 * 3600

    static func record(personName: String, type: InteractionType) {
        let pending = PendingOutboundContact(personName: personName, interactionTypeRaw: type.rawValue, timestamp: .now)
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// The pending record, if it's still within the plausible window.
    static func currentWithinWindow() -> PendingOutboundContact? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let pending = try? JSONDecoder().decode(PendingOutboundContact.self, from: data) else { return nil }
        guard Date.now.timeIntervalSince(pending.timestamp) < window else {
            clear()
            return nil
        }
        return pending
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
