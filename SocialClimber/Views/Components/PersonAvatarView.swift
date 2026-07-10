import SwiftUI

struct PersonAvatarView: View {
    let person: Person
    var size: CGFloat = 44

    private static let gradients: [[Color]] = [
        [.blue, .cyan], [.purple, .pink], [.orange, .yellow],
        [.green, .mint], [.indigo, .blue], [.pink, .red], [.teal, .green],
    ]

    private var gradient: LinearGradient {
        // Stable across launches (String.hashValue is seeded per-process).
        let hash = person.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let index = hash % Self.gradients.count
        return LinearGradient(colors: Self.gradients[index], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var initials: String {
        let parts = person.name.components(separatedBy: " ").filter { !$0.isEmpty }
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        Group {
            if let data = person.avatarData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                gradient.overlay(
                    // Serif initials, matching the app's editorial display
                    // type (see SocialClimberApp's nav-title typography):
                    // the monogram treatment of a luxury label rather than
                    // a generic app avatar.
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // A jewellery-style double ring: a fine bright inner line with a
        // soft accent halo just outside it, so photos read as set pieces
        // rather than cropped thumbnails. The halo scales with the avatar
        // and vanishes into the background on tiny sizes instead of
        // muddying them.
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(0.8), lineWidth: max(1, size * 0.025))
        }
        .background {
            Circle()
                .stroke(SCTheme.accent.opacity(0.35), lineWidth: max(1, size * 0.045))
                .padding(-max(2, size * 0.05))
        }
        .shadow(color: Color.black.opacity(0.25), radius: size * 0.12, x: 0, y: size * 0.06)
    }
}
