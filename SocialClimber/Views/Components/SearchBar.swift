import SwiftUI

struct SearchBar: View {
    @Binding var text: String
    var placeholder = "Search"
    var autoFocus = false

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .focused($focused)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
        .onAppear { if autoFocus { focused = true } }
    }
}
