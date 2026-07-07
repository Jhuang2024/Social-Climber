import SwiftUI

/// A compact score gauge shown on the profile. Tap to see the full breakdown.
struct RelationshipScoreCard: View {
    let person: Person
    @State private var showBreakdown = false

    private var score: RelationshipScore { RelationshipScore.compute(for: person) }

    var body: some View {
        Button { showBreakdown = true } label: {
            HStack(spacing: 16) {
                ScoreRing(score: score.total, color: score.band.color)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: score.band.icon)
                            .font(.subheadline.weight(.bold))
                        Text(score.band.label)
                            .font(.headline)
                    }
                    .foregroundStyle(score.band.color)
                    Text(topLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .scCard()
        }
        .buttonStyle(.pressable)
        .sheet(isPresented: $showBreakdown) {
            ScoreBreakdownView(person: person)
        }
    }

    private var topLine: String {
        let ranked = score.rankedFactors.filter { $0.label != "Baseline" }
        if let top = ranked.first { return "\(top.signedString)  \(top.label)" }
        return "Tap to see why"
    }
}

/// A circular progress ring displaying the 0–100 score.
struct ScoreRing: View {
    let score: Int
    var color: Color = SCTheme.accent
    var size: CGFloat = 62

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy, value: score)
            Text("\(score)")
                .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Relationship score \(score) out of 100")
    }
}

/// The full, itemized explanation of a person's score. Every point is shown.
struct ScoreBreakdownView: View {
    let person: Person
    @Environment(\.dismiss) private var dismiss

    private var score: RelationshipScore { RelationshipScore.compute(for: person) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        ScoreRing(score: score.total, color: score.band.color, size: 96)
                        Text(score.band.label)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(score.band.color)
                        Text("for \(person.displayName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                    FormSectionCard("Why this score", icon: "list.bullet.rectangle") {
                        let factors = score.rankedFactors
                        ForEach(factors) { factor in
                            factorRow(factor)
                            if factor.id != factors.last?.id {
                                Divider()
                            }
                        }
                    }

                    Text("Scores update automatically from recency, quality, consistency, follow-through, and overdue items. Nothing here is random.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.horizontal)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .socialClimberPageBackground()
            .navigationTitle("Relationship Score")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func factorRow(_ factor: ScoreFactor) -> some View {
        HStack(spacing: 12) {
            Text(factor.signedString)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(factorColor(factor))
                .frame(width: 44, alignment: .leading)
            Text(factor.label)
                .font(.subheadline)
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private func factorColor(_ factor: ScoreFactor) -> Color {
        if factor.label == "Baseline" { return .secondary }
        return factor.isPositive ? .green : .red
    }
}

#Preview {
    ScoreBreakdownView(person: PreviewData.samplePerson)
        .modelContainer(PreviewData.container)
}
