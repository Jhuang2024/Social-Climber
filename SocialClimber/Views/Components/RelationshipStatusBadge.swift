import SwiftUI

struct RelationshipStatusBadge: View {
    let status: RelationshipStatus
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            if !compact {
                Text(status.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(status.color)
            }
        }
        .padding(.horizontal, compact ? 4 : 8)
        .padding(.vertical, 4)
        .background(status.color.opacity(0.12), in: Capsule())
    }
}
