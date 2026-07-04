import SwiftUI

struct BrandLogoView: View {
    var size: CGFloat = 36

    var body: some View {
        Image("SocialClimberLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityLabel("Social Climber")
    }
}
