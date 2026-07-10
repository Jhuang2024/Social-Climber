import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// How an interaction's content is getting into the app. Plain manual entry,
/// or an imported social-media message: pasted or scanned from a screenshot.
/// Import is a mode of logging an interaction, not a separate feature: it
/// shares the same person picker, sentiment, follow-up, and save path.
enum InteractionSource: String, CaseIterable, Identifiable {
    case manual = "Manual"
    case paste = "Paste Text"
    case screenshot = "Screenshot"
    var id: String { rawValue }
}

struct AddInteractionView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var preselected: [Person] = []

    @State private var source: InteractionSource
    @State private var selectedPeople: [Person] = []
    @State private var type: InteractionType = .inPerson
    @State private var date = Date.now
    @State private var location = ""
    @State private var note = ""
    @State private var messageSummary = ""
    @State private var nextMove = ""
    @State private var topics: [String] = []
    @State private var sentiment: Sentiment = .neutral
    @State private var followUpNeeded = false
    @State private var followUpDate = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
    @State private var analyzeWithAI = true
    @State private var isSaving = false
    @State private var showPeoplePicker = false
    @State private var message: String?
    /// When true, tapping "OK" on the `message` alert dismisses this sheet:
    /// used so a post-save notice (AI degraded, closeness impact) is
    /// actually visible instead of being torn down by an immediate dismiss.
    @State private var dismissAfterAlert = false

    // Suggestion review: shown between "AI extraction produced something"
    // and actually writing anything, whenever there's at least one
    // interest/gift/reminder/date/personality note to approve or reject.
    @State private var showSuggestionReview = false
    @State private var reviewExtraction: AIExtraction?
    @State private var reviewOptions = ExtractionApplier.Options()
    @State private var pendingAINotice: String?

    // Import-mode state.
    @State private var rawText = ""
    @State private var parsed: ParsedMessage?
    @State private var aiExtraction: AIExtraction?
    @State private var platform: MessagePlatform = .instagram
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isScanning = false
    @State private var isAnalyzing = false
    @State private var hasAnalyzed = false
    @State private var newContactName = ""

    @Query(sort: \Person.name) private var allPeople: [Person]

    /// `initialRawText` pre-fills the paste-import text field: used to hand
    /// off text the Share Extension queued (e.g. selected Messages bubbles
    /// shared from outside the app). Forces paste mode so it's immediately
    /// visible; the user still explicitly taps "Detect summary" themselves,
    /// same as any other paste import.
    init(preselected: [Person] = [], initialSource: InteractionSource = .manual, initialRawText: String = "") {
        self.preselected = preselected
        _source = State(initialValue: initialRawText.isEmpty ? initialSource : .paste)
        _rawText = State(initialValue: initialRawText)
    }

    private var isImportMode: Bool { source != .manual }

    private var canSave: Bool {
        guard !selectedPeople.isEmpty else { return false }
        guard isImportMode else { return true }
        let noContent = messageSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !noContent
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Capture the useful bits while they are fresh.", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous)
                        .fill(.thinMaterial)
                        .padding(.vertical, 3)
                )

                sourceSection

                whoSection

                if isImportMode { platformSection }

                Section("What") {
                    if !isImportMode {
                        Picker("Type", selection: $type) {
                            ForEach(InteractionType.loggable) { t in
                                Label(t.label, systemImage: t.icon).tag(t)
                            }
                        }
                    }
                    DatePicker(isImportMode ? "Message date" : "When", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    if isImportMode, let detected = parsed?.detectedDate {
                        Button {
                            date = detected
                        } label: {
                            Label("Use detected date (\(detected.formatted(date: .abbreviated, time: .shortened)))", systemImage: "clock.arrow.circlepath")
                        }
                    } else if isImportMode, hasAnalyzed {
                        // No reliable date in the pasted/scanned text: say so
                        // explicitly instead of silently leaving the picker at
                        // whatever it defaulted to (now), which would make an
                        // old screenshot look like it happened today.
                        Label("No date found in this. Confirm the date above is right, it doesn't default to when the conversation happened.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    TextField("Location", text: $location)
                        .submitLabel(.done)
                }

                Section(isImportMode ? "Summary" : "Notes") {
                    TextField(isImportMode ? "Notes (optional)" : "What happened? What did you talk about?", text: $note, axis: .vertical)
                        .lineLimit(isImportMode ? 1...4 : 4...10)
                    if isImportMode {
                        if isAnalyzing {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Generating summary with AI…").foregroundStyle(.secondary)
                            }
                        } else if hasAnalyzed {
                            TextField("Editable summary", text: $messageSummary, axis: .vertical)
                                .lineLimit(2...6)
                        } else {
                            Text(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? "Paste a message or choose a screenshot above to generate a summary."
                                 : "Tap \"Detect summary\" above to generate a summary with AI.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TextField("Message summary (optional)", text: $messageSummary, axis: .vertical)
                            .lineLimit(1...4)
                    }
                    if let speakers = parsed?.speakers, !speakers.isEmpty {
                        Text("Detected: \(speakers.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TagListEditor(label: "topic", items: $topics)
                }

                Section {
                    SentimentPicker(sentiment: $sentiment)
                }

                Section("Follow-up") {
                    Toggle("Needs follow-up", isOn: $followUpNeeded.animation(.snappy))
                        .tint(.green)
                    if followUpNeeded {
                        DatePicker("Follow up by", selection: $followUpDate, displayedComponents: .date)
                        TextField("Next move (e.g. send resume, grab coffee)", text: $nextMove, axis: .vertical)
                            .lineLimit(1...3)
                    }
                }

                Section {
                    Toggle(isOn: $analyzeWithAI) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isImportMode ? "Analyze with AI" : "Analyze note")
                            Text(isImportMode
                                 ? "Generate a summary and extract topics, gifts, dates & follow-ups"
                                 : "Extract interests, gifts, dates & follow-ups")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.green)
                    if isImportMode && isAnalyzing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Analyzing…").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if isImportMode {
                        Text("Uses the AI provider configured in Settings. Only the extracted/pasted text is sent to it. Screenshots themselves are never uploaded.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Log Interaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(!canSave)
                    }
                }
            }
            .sheet(isPresented: $showPeoplePicker) {
                NavigationStack {
                    PersonMultiPicker(selected: $selectedPeople)
                        .navigationTitle("Who was there?")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showPeoplePicker = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showSuggestionReview) {
                if let reviewExtraction {
                    SuggestionReviewSheet(extraction: reviewExtraction, options: $reviewOptions) {
                        confirmReview()
                    }
                }
            }
            .alert("Social Climber", isPresented: .init(get: { message != nil }, set: { isPresented in
                guard !isPresented else { return }
                // Fires however the alert closes (OK, swipe, or tap-outside),
                // so a saved interaction never leaves the sheet open behind
                // a dismissed alert (which risked a duplicate on re-tapping
                // Save).
                message = nil
                let shouldDismiss = dismissAfterAlert
                dismissAfterAlert = false
                if shouldDismiss { dismiss() }
            })) {
                Button("OK") {}
            } message: {
                Text(message ?? "")
            }
            .onAppear {
                if selectedPeople.isEmpty { selectedPeople = preselected }
            }
            .onChange(of: photoItems) { _, items in
                if !items.isEmpty { Task { await scan(items) } }
            }
            .keyboardDoneButton()
        }
    }

    // MARK: Sections

    private var sourceSection: some View {
        Section {
            Picker("Source", selection: $source) {
                ForEach(InteractionSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch source {
            case .manual:
                EmptyView()
            case .paste:
                TextField("Paste the copied chat or message here…", text: $rawText, axis: .vertical)
                    .lineLimit(5...14)
                Button {
                    Task { await analyzeImport(rawText) }
                } label: {
                    Label("Detect summary", systemImage: "wand.and.stars")
                }
                .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAnalyzing)
            case .screenshot:
                PhotosPicker(selection: $photoItems, matching: .images) {
                    Label(rawText.isEmpty ? "Choose screenshots" : "Choose different screenshots",
                          systemImage: "photo.on.rectangle.angled")
                }
                if !photoItems.isEmpty {
                    Text("\(photoItems.count) screenshot\(photoItems.count == 1 ? "" : "s") selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Scanning on-device…").foregroundStyle(.secondary)
                    }
                }
                if !rawText.isEmpty {
                    Text("Extracted text (edit if needed):")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Extracted text", text: $rawText, axis: .vertical)
                        .lineLimit(4...14)
                }
            }
        } header: {
            Text("Source")
        } footer: {
            if isImportMode {
                Text("Everything stays on your device. Screenshots are read with Apple's on-device text recognition and never uploaded.")
            }
        }
    }

    private var whoSection: some View {
        Section("Who") {
            if selectedPeople.isEmpty {
                Button { showPeoplePicker = true } label: {
                    Label("Choose people", systemImage: "person.2.badge.plus")
                }
            } else {
                ForEach(selectedPeople) { person in
                    HStack {
                        PersonAvatarView(person: person, size: 30)
                        Text(person.displayName)
                        Spacer()
                    }
                }
                .onDelete { selectedPeople.remove(atOffsets: $0) }
                Button { showPeoplePicker = true } label: {
                    Label("Add / remove people", systemImage: "person.2.badge.plus")
                }
            }
            if isImportMode {
                HStack {
                    TextField(newContactPrompt, text: $newContactName)
                        .submitLabel(.done)
                    Button("Create") { createContact() }
                        .disabled(newContactName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var platformSection: some View {
        Section("Platform") {
            Picker("Platform", selection: $platform) {
                ForEach(MessagePlatform.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
        }
    }

    private var newContactPrompt: String {
        if let name = parsed?.speakers.first, !name.isEmpty {
            return "New contact (e.g. \(name))"
        }
        return "Create a new contact"
    }

    private var quality: Int { sentiment.quality }

    // MARK: Import helpers

    /// Runs local on-device parsing (date/speaker detection) and, when
    /// enabled, sends the text to the configured AI provider (BazaarLink or
    /// Mock) to generate a real summary and extract topics/gifts/dates/
    /// follow-ups, the same extraction pipeline manual note logging uses.
    private func analyzeImport(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Hide the (not-yet-generated) summary field again while this run
        // is in flight, so a re-scan or re-detect doesn't leave stale text
        // sitting in an editable field.
        hasAnalyzed = false

        let local = MessageImportParser.parse(text)
        parsed = local
        if let detected = local.detectedDate { date = detected }
        if newContactName.isEmpty, let speaker = local.speakers.first,
           !allPeople.contains(where: { $0.name.localizedCaseInsensitiveContains(speaker) }) {
            newContactName = speaker
        }

        guard analyzeWithAI else {
            aiExtraction = nil
            messageSummary = local.summary
            hasAnalyzed = true
            Haptics.success()
            return
        }

        isAnalyzing = true
        defer { isAnalyzing = false }
        // Never leaves the user with nothing: if the configured AI provider
        // fails (missing/invalid key, timeout, rate limit, network, bad
        // response), this falls back to a deterministic local summary
        // instead of blocking the save.
        let outcome = await AIExtractionCoordinator.extract(from: trimmed, knownPeople: allPeople.map(\.name))
        let extraction = outcome.extraction
        aiExtraction = extraction
        messageSummary = extraction.summary.isEmpty ? local.summary : extraction.summary
        for topic in extraction.topics where !topics.contains(topic) { topics.append(topic) }
        hasAnalyzed = true
        if let notice = outcome.notice {
            message = notice
        } else {
            Haptics.success()
        }
    }

    private func scan(_ items: [PhotosPickerItem]) async {
        isScanning = true
        message = nil
        defer { isScanning = false }

        var texts: [String] = []
        var lastImageError: String?
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    lastImageError = OCRError.noImage.errorDescription
                    continue
                }
                let text = try await OCRService.recognizeText(in: image)
                texts.append(text)
            } catch let error as OCRError {
                lastImageError = error.errorDescription
            } catch {
                lastImageError = error.localizedDescription
            }
        }

        guard !texts.isEmpty else {
            message = lastImageError ?? OCRError.noText.errorDescription
            return
        }

        rawText = texts.joined(separator: "\n\n---\n\n")
        await analyzeImport(rawText)
    }

    private func createContact() {
        let name = newContactName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let person = Person(name: name, category: .acquaintance, closeness: 2, priority: 2)
        context.insert(person)
        selectedPeople.append(person)
        newContactName = ""
        Haptics.success()
    }

    // MARK: Save

    private func save() async {
        isSaving = true

        if isImportMode {
            if parsed == nil { await analyzeImport(rawText) }
            isSaving = false
            if let extraction = aiExtraction {
                if hasSuggestions(extraction) {
                    beginReview(extraction, notice: nil)
                } else {
                    // Nothing to approve/reject, but the AI did produce a
                    // real summary: still attach it (ConversationSummary)
                    // instead of silently dropping it the way `approved: nil`
                    // would.
                    let closenessNotice = saveImportedInteraction(approved: (extraction, .allApproved(for: extraction)))
                    finishSave(closenessNotice: closenessNotice)
                }
            } else {
                finishSave(closenessNotice: saveImportedInteraction(approved: nil))
            }
            return
        }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        guard analyzeWithAI, !trimmedNote.isEmpty else {
            isSaving = false
            finishSave(closenessNotice: savePlainInteraction(note: trimmedNote))
            return
        }

        // Never throws: falls back to a deterministic local extraction if
        // the configured AI provider fails, so the save always goes through
        // with something useful.
        let outcome = await AIExtractionCoordinator.extract(from: trimmedNote, knownPeople: allPeople.map(\.name))
        isSaving = false

        if hasSuggestions(outcome.extraction) {
            beginReview(outcome.extraction, notice: outcome.notice)
        } else {
            let closenessNotice = applyManualExtraction(outcome.extraction, options: .allApproved(for: outcome.extraction))
            finishSave(aiNotice: outcome.notice, closenessNotice: closenessNotice)
        }
    }

    private func hasSuggestions(_ extraction: AIExtraction) -> Bool {
        !extraction.interests.isEmpty || !extraction.giftIdeas.isEmpty || !extraction.reminders.isEmpty
            || !extraction.importantDates.isEmpty || !extraction.personalityNotes.isEmpty
    }

    /// Pauses the save to let the user approve or reject each suggestion:
    /// everything starts checked, `confirmReview()` finishes the save once
    /// they tap Save in the review sheet.
    private func beginReview(_ extraction: AIExtraction, notice: String?) {
        reviewExtraction = extraction
        reviewOptions = .allApproved(for: extraction)
        pendingAINotice = notice
        showSuggestionReview = true
    }

    private func confirmReview() {
        guard let extraction = reviewExtraction else { return }
        let closenessNotice: String?
        if isImportMode {
            closenessNotice = saveImportedInteraction(approved: (extraction, reviewOptions))
        } else {
            closenessNotice = applyManualExtraction(extraction, options: reviewOptions)
        }
        finishSave(aiNotice: pendingAINotice, closenessNotice: closenessNotice)
    }

    private func finishSave(aiNotice: String? = nil, closenessNotice: String?) {
        Haptics.success()
        // Show both notices together rather than letting one silently win:
        // an AI degradation notice shouldn't hide that closeness also moved.
        let combined = [aiNotice, closenessNotice].compactMap { $0 }.joined(separator: "\n\n")
        if !combined.isEmpty {
            message = combined
            dismissAfterAlert = true
        } else {
            dismiss()
        }
    }

    /// Applies an AI extraction to a manually-logged note (not an import):
    /// only the items in `options` get written; everything else is
    /// discarded, same as if the AI had never suggested it.
    @discardableResult
    private func applyManualExtraction(_ extraction: AIExtraction, options: ExtractionApplier.Options) -> String? {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let interaction = ExtractionApplier.apply(
            extraction,
            to: selectedPeople,
            sourceText: trimmedNote,
            interactionType: type,
            date: date,
            quality: quality,
            options: options,
            context: context
        )
        interaction?.location = location
        // Only override the AI-generated summary if the user actually
        // typed their own; otherwise keep what ExtractionApplier set from
        // the AI extraction.
        let typedSummary = messageSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedSummary.isEmpty {
            interaction?.messageSummary = typedSummary
        }
        interaction?.nextMove = nextMove.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep any follow-up the analysis inferred; add the user's if set.
        if followUpNeeded {
            interaction?.followUpNeeded = true
            interaction?.followUpDate = followUpDate
        }
        var mergedTopics = interaction?.topics ?? []
        for topic in topics where !mergedTopics.contains(topic) { mergedTopics.append(topic) }
        interaction?.topics = mergedTopics
        // Only schedule an extra reminder for the user's explicit toggle;
        // the analysis already created reminders for anything approved.
        if followUpNeeded, let interaction {
            InteractionSaver.scheduleFollowUpIfNeeded(for: interaction, people: selectedPeople, context: context)
        }
        return interaction.flatMap(closenessImpactMessage)
    }

    /// A short, immediate confirmation of how this interaction moved
    /// closeness (e.g. "Closeness -1 for Jordan.") so the impact of a
    /// poorly- or well-rated interaction is never a surprise you have to go
    /// looking for.
    private func closenessImpactMessage(for interaction: Interaction) -> String? {
        let deltas = interaction.appliedClosenessDeltas
        let parts = selectedPeople.compactMap { person -> String? in
            guard let delta = deltas[person.persistentModelID], delta != 0 else { return nil }
            let signed = delta > 0 ? "+\(delta)" : "\(delta)"
            return "\(signed) for \(person.firstName)"
        }
        guard !parts.isEmpty else { return nil }
        return "Closeness \(parts.joined(separator: ", "))."
    }

    @discardableResult
    private func savePlainInteraction(note: String) -> String? {
        let interaction = Interaction(
            type: type,
            date: date,
            location: location,
            note: note,
            topics: topics,
            quality: quality,
            followUpNeeded: followUpNeeded,
            followUpDate: followUpNeeded ? followUpDate : nil,
            nextMove: nextMove.trimmingCharacters(in: .whitespacesAndNewlines),
            messageSummary: messageSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        InteractionSaver.finalize(interaction, people: selectedPeople, context: context)
        return closenessImpactMessage(for: interaction)
    }

    @discardableResult
    private func saveImportedInteraction(approved: (extraction: AIExtraction, options: ExtractionApplier.Options)?) -> String? {
        let finalSummary = messageSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let interaction = Interaction(
            type: .socialMedia,
            date: date,
            location: location,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            topics: topics,
            quality: quality,
            followUpNeeded: followUpNeeded,
            followUpDate: followUpNeeded ? followUpDate : nil,
            nextMove: nextMove.trimmingCharacters(in: .whitespacesAndNewlines),
            messageSummary: finalSummary.isEmpty ? (parsed?.summary ?? "") : finalSummary
        )
        interaction.isImported = true
        interaction.platform = platform
        interaction.rawImportText = rawText
        InteractionSaver.finalize(interaction, people: selectedPeople, context: context)

        // Apply whichever suggestions were approved (interests, gift ideas,
        // reminders, important dates, personality notes) without creating a
        // second interaction: the one above already carries the import's
        // own fields (platform, raw text, edited summary).
        if let approved {
            var options = approved.options
            options.createInteraction = false
            ExtractionApplier.apply(
                approved.extraction,
                to: selectedPeople,
                sourceText: rawText,
                interactionType: .socialMedia,
                date: date,
                options: options,
                context: context
            )
            let summary = ConversationSummary(extraction: approved.extraction)
            summary.interaction = interaction
            context.insert(summary)
        }

        return closenessImpactMessage(for: interaction)
    }
}

#Preview {
    AddInteractionView()
        .modelContainer(PreviewData.container)
}
