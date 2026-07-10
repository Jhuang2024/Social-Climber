import SwiftUI
import SwiftData

/// Every capture, newest first, grouped into Needs Context / Processing or
/// Failed / Recent. This is where corrections happen *when the user
/// chooses* — normal captures never force a review.
struct CaptureInboxView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CapturedMemory.capturedAt, order: .reverse) private var captures: [CapturedMemory]

    private var needsContext: [CapturedMemory] { captures.filter { $0.status == .needsContext } }
    private var pendingOrFailed: [CapturedMemory] {
        captures.filter { $0.status == .queued || $0.status == .processing || $0.status == .failed }
    }
    private var recent: [CapturedMemory] {
        captures.filter { $0.status == .processed || $0.status == .dismissed }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if captures.isEmpty {
                    EmptyStateView(
                        icon: "sparkles",
                        title: "Nothing captured yet",
                        message: "Anything you tell Social Climber from Home — typed, spoken, or shared — lands here while it's organized for you."
                    )
                } else {
                    if !needsContext.isEmpty {
                        FormSectionCard("Needs Context", icon: "person.fill.questionmark") {
                            ForEach(needsContext, id: \.persistentModelID) { capture in
                                CaptureRowView(capture: capture)
                            }
                        }
                    }
                    if !pendingOrFailed.isEmpty {
                        FormSectionCard("Processing", icon: "arrow.triangle.2.circlepath") {
                            ForEach(pendingOrFailed, id: \.persistentModelID) { capture in
                                CaptureRowView(capture: capture)
                            }
                        }
                    }
                    if !recent.isEmpty {
                        FormSectionCard("Recent", icon: "clock.arrow.circlepath") {
                            ForEach(recent.prefix(30), id: \.persistentModelID) { capture in
                                CaptureRowView(capture: capture)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .socialClimberPageBackground()
        .navigationTitle("Captures")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Row

/// One capture in a feed: headline, one-line detail, status. Needs-Context
/// rows carry one-tap candidate chips so resolving is a single tap.
struct CaptureRowView: View {
    @Environment(\.modelContext) private var context
    let capture: CapturedMemory
    /// Compact rows (Home cards) hide candidate chips to stay small.
    var showsCandidates = true

    @Query(sort: \Person.name) private var allPeople: [Person]

    private var candidates: [Person] {
        capture.candidatePersonNames.compactMap { name in
            allPeople.first { $0.name == name }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink {
                CaptureDetailView(capture: capture)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: capture.status.icon)
                        .font(.subheadline)
                        .foregroundStyle(capture.status.color)
                        .frame(width: 30, height: 30)
                        .background(capture.status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(capture.title.isEmpty ? capture.status.label : capture.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(rowDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Text(capture.capturedAt.relativeLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if showsCandidates, capture.status == .needsContext, !candidates.isEmpty {
                HStack(spacing: 6) {
                    ForEach(candidates.prefix(3), id: \.persistentModelID) { person in
                        Button {
                            Task { await CaptureProcessor.shared.assign(people: [person], to: capture) }
                        } label: {
                            HStack(spacing: 5) {
                                PersonAvatarView(person: person, size: 18)
                                Text(person.firstName)
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(SCTheme.accent.opacity(0.12), in: Capsule())
                            .foregroundStyle(SCTheme.accent)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.leading, 40)
            }

            if showsCandidates, capture.status == .failed {
                Button {
                    Task { await CaptureProcessor.shared.retry(capture) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .padding(.leading, 40)
            }
        }
        .padding(.vertical, 4)
    }

    private var rowDetail: String {
        if !capture.detail.isEmpty { return capture.detail }
        if !capture.errorMessage.isEmpty { return capture.errorMessage }
        return "“\(capture.preview)”"
    }
}

// MARK: - Detail

/// Everything about one capture: the raw text (editable), what it became,
/// the facts it produced, and every corrective action — retry, assign,
/// undo, delete — plus the optional path into the full detailed editor.
struct CaptureDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var capture: CapturedMemory

    @State private var editedText = ""
    @State private var isEditingText = false
    @State private var showAssign = false
    @State private var assignSelection: [Person] = []
    @State private var confirmUndo = false
    @State private var confirmDelete = false

    private var interaction: Interaction? {
        CaptureProcessor.interaction(for: capture, context: context)
    }

    private var facts: [MemoryFact] {
        CaptureProcessor.facts(for: capture, context: context)
    }

    private var reminders: [Reminder] {
        CaptureProcessor.reminders(for: capture, context: context)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusHeader

                rawTextCard

                if capture.status == .needsContext {
                    needsContextCard
                }

                if let interaction {
                    resultCard(interaction)
                }

                if !reminders.isEmpty {
                    FormSectionCard("Reminders Created", icon: "bell") {
                        ForEach(reminders) { reminder in
                            ReminderRowView(reminder: reminder)
                        }
                    }
                }

                if !facts.isEmpty {
                    factsCard
                }

                actionsCard
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .socialClimberPageBackground()
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAssign) {
            NavigationStack {
                PersonMultiPicker(selected: $assignSelection)
                    .navigationTitle("Who was this with?")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showAssign = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Assign") {
                                showAssign = false
                                let people = assignSelection
                                guard !people.isEmpty else { return }
                                Task { await CaptureProcessor.shared.assign(people: people, to: capture) }
                            }
                            .disabled(assignSelection.isEmpty)
                        }
                    }
            }
        }
        .confirmationDialog(
            "Undo everything this capture created? The interaction, reminders, dates, gift ideas, and facts it produced will be removed.",
            isPresented: $confirmUndo,
            titleVisibility: .visible
        ) {
            Button("Undo Changes", role: .destructive) {
                Haptics.warning()
                CaptureProcessor.shared.undo(capture)
            }
        }
        .confirmationDialog(
            "Delete this capture?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Undo Changes & Delete", role: .destructive) {
                Haptics.warning()
                CaptureProcessor.shared.undo(capture)
                CaptureProcessor.shared.delete(capture)
                dismiss()
            }
            Button("Delete Capture Only", role: .destructive) {
                Haptics.warning()
                CaptureProcessor.shared.delete(capture)
                dismiss()
            }
        }
    }

    // MARK: Cards

    private var statusHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: capture.status.icon)
                .font(.title2)
                .foregroundStyle(capture.status.color)
                .frame(width: 56, height: 56)
                .background(capture.status.color.opacity(0.12), in: Circle())
            Text(capture.status.label)
                .font(SCTheme.displayFont(19, weight: .semibold))
            HStack(spacing: 6) {
                Label(capture.source.label, systemImage: capture.source.icon)
                Text("·")
                Text(capture.capturedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !capture.errorMessage.isEmpty {
                Text(capture.errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            if capture.usedLocalFallback && capture.status == .processed {
                Text("Organized with the on-device fallback (AI was unavailable).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: SCTheme.heroCardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SCTheme.heroCardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.055))
        }
    }

    private var rawTextCard: some View {
        FormSectionCard("What You Said", icon: "text.quote") {
            if isEditingText {
                TextField("Raw capture", text: $editedText, axis: .vertical)
                    .lineLimit(3...12)
                HStack {
                    Button("Cancel") { isEditingText = false }
                        .font(.subheadline)
                    Spacer()
                    Button {
                        applyTextEdit()
                    } label: {
                        Label("Save & Reprocess", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            } else {
                Text(capture.effectiveText.isEmpty ? "No text" : capture.effectiveText)
                    .font(.subheadline)
                    .textSelection(.enabled)
                Button {
                    editedText = capture.effectiveText
                    isEditingText = true
                } label: {
                    Label(capture.transcript.isEmpty ? "Edit text" : "Edit transcript", systemImage: "pencil")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
    }

    private var needsContextCard: some View {
        FormSectionCard("Who was this with?", icon: "person.fill.questionmark") {
            Text("Social Climber couldn't confidently tell who this memory is about. Pick the right person and it finishes organizing itself.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            CaptureCandidateChips(capture: capture)
            Button {
                assignSelection = []
                showAssign = true
            } label: {
                Label("Choose someone else", systemImage: "person.badge.plus")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private func resultCard(_ interaction: Interaction) -> some View {
        FormSectionCard("What It Became", icon: "checkmark.seal") {
            NavigationLink {
                InteractionDetailView(interaction: interaction)
            } label: {
                TimelineRowView(interaction: interaction)
            }
            .buttonStyle(.plain)
            Text("Open it to review the extracted details, or edit the date, type, and every other field in the full editor.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var factsCard: some View {
        FormSectionCard("Facts Learned", icon: "brain.head.profile") {
            ForEach(facts, id: \.persistentModelID) { fact in
                MemoryFactRowView(fact: fact)
            }
            Text("Reject anything wrong — rejected facts never come back, even if this capture is reprocessed.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var actionsCard: some View {
        FormSectionCard("Actions", icon: "slider.horizontal.3") {
            if capture.status == .failed || capture.status == .needsContext {
                Button {
                    Task { await CaptureProcessor.shared.retry(capture) }
                } label: {
                    Label("Retry processing", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                }
            }
            if capture.status == .processed {
                Button {
                    assignSelection = []
                    showAssign = true
                } label: {
                    Label("Change people", systemImage: "person.2.badge.gearshape")
                        .font(.subheadline.weight(.medium))
                }
                Button(role: .destructive) {
                    confirmUndo = true
                } label: {
                    Label("Undo everything this created", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete capture", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
            }
        }
    }

    /// Editing the raw text reverses what the old text produced, then
    /// reprocesses from scratch — so a corrected capture never leaves the
    /// stale interaction/facts from its first wording behind.
    private func applyTextEdit() {
        let newText = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else { return }
        isEditingText = false
        CaptureProcessor.shared.undo(capture)
        if !capture.transcript.isEmpty {
            capture.transcript = newText
            capture.rawText = ""
        } else {
            capture.rawText = newText
        }
        capture.status = .queued
        Task { await CaptureProcessor.shared.processQueued() }
    }
}

// MARK: - Candidate chips (shared)

/// One-tap person chips for a Needs Context capture.
struct CaptureCandidateChips: View {
    let capture: CapturedMemory
    @Query(sort: \Person.name) private var allPeople: [Person]

    private var candidates: [Person] {
        capture.candidatePersonNames.compactMap { name in
            allPeople.first { $0.name == name }
        }
    }

    var body: some View {
        if candidates.isEmpty {
            EmptyView()
        } else {
            FlowLayout(spacing: 8) {
                ForEach(candidates, id: \.persistentModelID) { person in
                    Button {
                        Task { await CaptureProcessor.shared.assign(people: [person], to: capture) }
                    } label: {
                        HStack(spacing: 6) {
                            PersonAvatarView(person: person, size: 22)
                            Text(person.firstName)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(SCTheme.accent.opacity(0.12), in: Capsule())
                        .foregroundStyle(SCTheme.accent)
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }
}

// MARK: - Fact row (shared with PersonProfileView)

/// One evidence-linked fact with its type, confidence tier, and inline
/// reject/restore controls. Every automatic fact stays inspectable and
/// reversible — that's what removes the need for a mandatory review screen.
struct MemoryFactRowView: View {
    @Environment(\.modelContext) private var context
    @Bindable var fact: MemoryFact
    var showsPerson = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: fact.type.icon)
                .font(.caption)
                .foregroundStyle(fact.type.color)
                .frame(width: 26, height: 26)
                .background(fact.type.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(fact.value)
                    .font(.subheadline)
                    .strikethrough(fact.status == .rejected)
                    .foregroundStyle(fact.status == .rejected ? .secondary : .primary)
                HStack(spacing: 5) {
                    Text(fact.type.label)
                    if showsPerson, let person = fact.person {
                        Text("· \(person.firstName)")
                    }
                    if fact.status == .suggested {
                        Text("· Suggested")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                if fact.status == .suggested {
                    Button {
                        fact.status = .active
                    } label: {
                        Label("Confirm", systemImage: "checkmark")
                    }
                }
                if fact.status != .rejected {
                    Button {
                        fact.status = .rejected
                    } label: {
                        Label("Reject", systemImage: "hand.thumbsdown")
                    }
                } else {
                    Button {
                        fact.status = .active
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                }
                Button(role: .destructive) {
                    context.delete(fact)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

#Preview {
    NavigationStack {
        CaptureInboxView()
    }
    .modelContainer(PreviewData.container)
}
