import Foundation

/// Maps a stored contact method ("Phone" / "Email" / "Instagram" / …) to a
/// launchable system URL and the interaction type a completed contact of
/// that kind would be. Returns nil for values that can't be opened, in
/// which case the profile shows them as plain text like before.
enum ContactMethodLauncher {
    struct Target {
        let url: URL
        let interactionType: InteractionType
        let icon: String
    }

    static func target(for method: ContactMethod) -> Target? {
        let label = method.label.lowercased()
        let value = method.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if label.contains("phone") || label.contains("call") || label.contains("mobile") {
            guard let url = URL(string: "tel:\(digits(of: value))") else { return nil }
            return Target(url: url, interactionType: .call, icon: "phone.fill")
        }
        if label.contains("text") || label.contains("sms") || label.contains("imessage") {
            guard let url = URL(string: "sms:\(digits(of: value))") else { return nil }
            return Target(url: url, interactionType: .message, icon: "message.fill")
        }
        if label.contains("email") || label.contains("mail") || value.contains("@") && value.contains(".") && !value.hasPrefix("@") {
            guard let url = URL(string: "mailto:\(value)") else { return nil }
            return Target(url: url, interactionType: .email, icon: "envelope.fill")
        }
        if label.contains("instagram") {
            let handle = value.hasPrefix("@") ? String(value.dropFirst()) : value
            guard let url = URL(string: "https://instagram.com/\(handle)") else { return nil }
            return Target(url: url, interactionType: .socialMedia, icon: "camera.fill")
        }
        if label.contains("linkedin") {
            let path = value.hasPrefix("http") ? value : "https://www.linkedin.com/in/\(value)"
            guard let url = URL(string: path) else { return nil }
            return Target(url: url, interactionType: .socialMedia, icon: "briefcase.fill")
        }
        if label.contains("whatsapp") {
            guard let url = URL(string: "https://wa.me/\(digits(of: value))") else { return nil }
            return Target(url: url, interactionType: .message, icon: "phone.circle.fill")
        }
        // A pasted URL of any kind is at least openable.
        if value.hasPrefix("http://") || value.hasPrefix("https://"), let url = URL(string: value) {
            return Target(url: url, interactionType: .socialMedia, icon: "link")
        }
        // Bare number with a phone-ish label missing: still try tel:.
        let numeric = digits(of: value)
        if numeric.count >= 7 && numeric.count == value.filter({ !"() -+.".contains($0) }).count {
            guard let url = URL(string: "tel:\(numeric)") else { return nil }
            return Target(url: url, interactionType: .call, icon: "phone.fill")
        }
        return nil
    }

    private static func digits(of value: String) -> String {
        value.filter { $0.isNumber || $0 == "+" }
    }
}
