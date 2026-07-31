import SwiftUI
import SwiftData

/// One thing that happened, rendered the same way everywhere it appears
/// (the Past Events screen, the dashboard preview, a person's profile).
struct PastEventRowView: View {
    let event: LifeEvent
    /// Hidden on a person's own profile, where the subject is obvious.
    var showSubject: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: event.kind.icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(event.kind.color)
                .frame(width: 28, height: 28)
                .background(event.kind.color.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if showSubject {
                        Text(event.subjectLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(event.aboutMe ? SCTheme.accent : .secondary)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(event.kind.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(event.kind.color)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    // "around" rather than a confident day when the date was
                    // inferred from when the conversation was captured.
                    Text(event.isDateApproximate ? "around \(event.date.relativeLabel.lowercased())" : event.date.relativeLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
