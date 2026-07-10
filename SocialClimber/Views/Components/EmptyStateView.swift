import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            BrandLogoView(size: 42)
                .padding(.bottom, 2)
            // Circular badge with the same soft accent halo the avatars
            // wear, so even an empty screen speaks the app's jewellery
            // language instead of a generic rounded square.
            Image(systemName: icon)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(SCTheme.accent)
                .frame(width: 64, height: 64)
                .background(SCTheme.accent.opacity(0.12), in: Circle())
                .background {
                    Circle()
                        .stroke(SCTheme.accent.opacity(0.30), lineWidth: 2)
                        .padding(-5)
                }
                .padding(.bottom, 4)
            Text(title)
                .font(SCTheme.displayFont(21, weight: .semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: "plus")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(SCTheme.accent, in: Capsule())
                }
                .buttonStyle(.pressable)
                .padding(.top, 8)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.055))
        }
        .cardShadow()
    }
}
