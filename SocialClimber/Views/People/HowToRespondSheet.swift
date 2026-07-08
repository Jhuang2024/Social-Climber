import SwiftUI
import UIKit

/// Screenshot a conversation, get a reply grounded in this person's real
/// profile — closeness, notes, history, and current strategy read. Purely an
/// assist surface: the screenshots and the advice shown here are never
/// saved, never logged as an `Interaction`, and never touch closeness or
/// interaction history, unlike every other AI feature on this profile.
struct HowToRespondSheet: View {
    let person: Person
    @Environment(\.dismiss) private var dismiss

    @State private var images: [UIImage] = []
    @State private var isAnalyzing = false
    @State private var advice: ReplyAdvice?
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    FormSectionCard("Screenshot", icon: "camera.viewfinder") {
                        Text("Add a screenshot of the conversation with \(person.firstName). Used only to suggest a reply — never logged as an interaction, saved, or counted toward closeness.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        PhotoInputControl(
                            images: $images,
                            maxCount: 3,
                            placeholderIcon: "text.bubble",
                            placeholderText: "Add a screenshot"
                        )
                    }

                    if !images.isEmpty {
                        Button {
                            Task { await analyze() }
                        } label: {
                            if isAnalyzing {
                                HStack(spacing: 8) {
                                    ProgressView().tint(.white)
                                    Text("Reading the conversation…")
                                }
                            } else {
                                Label(advice == nil ? "Get a Reply" : "Re-analyze", systemImage: "sparkles")
                            }
                        }
                        .buttonStyle(.primaryCTA)
                        .disabled(isAnalyzing)
                    }

                    if let notice {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let advice {
                        ReplyAdviceCard(advice: advice)
                    } else if !isAnalyzing && images.isEmpty {
                        EmptyStateView(
                            icon: "text.bubble",
                            title: "Add a screenshot",
                            message: "Take or upload a screenshot of the conversation to get a reply suggestion grounded in \(person.firstName)'s profile, closeness, and history."
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .socialClimberPageBackground()
            .navigationTitle("How to Respond")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: images) { _, _ in
                advice = nil
                notice = nil
            }
        }
        .presentationDetents([.large])
    }

    private func analyze() async {
        isAnalyzing = true
        notice = nil
        let outcome = await ReplyAdvisorEngine.analyze(images: images, person: person)
        advice = outcome.advice
        notice = outcome.notice
        isAnalyzing = false
        if outcome.advice != nil { Haptics.success() }
    }
}

/// Recommended reply, tone, rationale, and any risk warning — plus copyable
/// alternates. Shown once `HowToRespondSheet` gets a `ReplyAdvice` back.
private struct ReplyAdviceCard: View {
    let advice: ReplyAdvice

    var body: some View {
        VStack(spacing: 16) {
            if let warning = advice.warning, !warning.isEmpty {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
            }

            FormSectionCard("Recommended Reply", icon: "text.bubble.fill") {
                Text(advice.recommendedReply.isEmpty ? "No reply returned." : advice.recommendedReply)
                    .font(.body.weight(.medium))
                if !advice.tone.isEmpty {
                    TagPillView(text: advice.tone, color: SCTheme.accent, icon: "waveform")
                }
                Button {
                    UIPasteboard.general.string = advice.recommendedReply
                    Haptics.success()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                }
                .disabled(advice.recommendedReply.isEmpty)
            }

            if !advice.explanation.isEmpty {
                FormSectionCard("Why This Works", icon: "lightbulb") {
                    Text(advice.explanation).font(.subheadline)
                }
            }

            if !advice.alternates.isEmpty {
                FormSectionCard("Other Options", icon: "square.stack") {
                    ForEach(Array(advice.alternates.enumerated()), id: \.offset) { index, alt in
                        if index > 0 { Divider() }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(alt.text).font(.subheadline.weight(.medium))
                            if !alt.why.isEmpty {
                                Text(alt.why).font(.caption).foregroundStyle(.secondary)
                            }
                            Button {
                                UIPasteboard.general.string = alt.text
                                Haptics.success()
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .font(.caption.weight(.medium))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

#Preview {
    HowToRespondSheet(person: PreviewData.samplePerson)
        .modelContainer(PreviewData.container)
}
