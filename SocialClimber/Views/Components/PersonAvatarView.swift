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
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(0.75), lineWidth: max(1, size * 0.025))
        }
        .shadow(color: Color.black.opacity(0.10), radius: size * 0.10, x: 0, y: size * 0.05)
    }
}
