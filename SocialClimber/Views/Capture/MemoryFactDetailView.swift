import SwiftUI
import SwiftData

/// Everything about one automatically-learned fact: its source capture,
/// the interaction it came from, the raw text it was extracted out of, who
/// it's attributed to, its confidence, and its status — plus every
/// correction available: confirm, reject, restore, delete, reassign an
/// unattributed fact to a person, and (for a reminder or date suggestion)
/// promote it into a real scheduled record once the user supplies what the
/// automatic pass couldn't safely infer on its own.
struct MemoryFactDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var fact: MemoryFact

    @Query(sort: \Person.name) private var allPeople: [Person]

    @State private var showAssign = false
    @State private var assignSelection: [Person] = []
    @State private var showDatePicker = false
    @State private var chosenDate = Date.now

    private var sourceCapture: CapturedMemory? {
        guard let uuid = fact.sourceCaptureUUID else { return nil }
        let descriptor = FetchDescriptor<CapturedMemory>(predicate: #Predicate { $0.uuid == uuid })
        return (try? context.fetch(descriptor))?.first
    }

    private var sourceInteraction: Interaction? {
        guard let uuid = fact.sourceInteractionUUID else { return nil }
        let descriptor = FetchDescriptor<Interaction>(predicate: #Predicate { $0.uuid == uuid })
        return (try? context.fetch(descriptor))?.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                FormSectionCard("Attribution", icon: "person") {
                    if let person = fact.person {
                        NavigationLink(value: person) {
                            HStack {
                                PersonAvatarView(person: person, size: 30)
                                Text(person.displayName).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("Not attributed to anyone yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        assignSelection = fact.person.map { [$0] } ?? []
                        showAssign = true
                    } label: {
                        Label(fact.person == nil ? "Assign to someone" : "Reassign", systemImage: "person.badge.plus")
                            .font(.subheadline.weight(.medium))
                    }
                }

                if let sourceCapture {
                    FormSectionCard("Source Capture", icon: "text.quote") {
                        Text(sourceCapture.effectiveText.isEmpty ? "No raw text" : sourceCapture.effectiveText)
                            .font(.subheadline)
                            .textSelection(.enabled)
                        NavigationLink {
                            CaptureDetailView(capture: sourceCapture)
                        } label: {
                            Label("Open capture", systemImage: "arrow.up.right.square")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }

                if let sourceInteraction {
                    FormSectionCard("Source Interaction", icon: "clock.arrow.circlepath") {
                        NavigationLink {
                            InteractionDetailView(interaction: sourceInteraction)
                        } label: {
                            TimelineRowView(interaction: sourceInteraction)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if fact.type == .reminderSuggestion, fact.status != .superseded {
                    FormSectionCard("Give It a Date", icon: "calendar.badge.plus") {
                        Text("This was an explicit reminder with no date Social Climber could resolve on its own. Set one to schedule it for real.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button {
                            chosenDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
                            showDatePicker = true
                        } label: {
                            Label("Set Date & Schedule", systemImage: "bell.badge")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }

                if fact.type == .importantDate, fact.dateValue != nil, fact.person != nil, fact.status != .superseded {
                    FormSectionCard("Promote This Date", icon: "calendar") {
                        Text("Automatic processing never sets a birthday or date on its own — confirm it here to add it to \(fact.person?.firstName ?? "their") profile.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if fact.value.localizedCaseInsensitiveContains("birthday"), fact.person?.birthday == nil {
                            Button {
                                MemoryFactPromotion.confirmAsBirthday(fact, context: context)
                            } label: {
                                Label("Confirm as Birthday", systemImage: "birthday.cake")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                        Button {
                            MemoryFactPromotion.confirmAsImportantDate(fact, context: context)
                        } label: {
                            Label("Add as Important Date", systemImage: "calendar.badge.plus")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }

                actionsCard
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .socialClimberPageBackground()
        .navigationTitle(fact.type.label)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Person.self) { PersonProfileView(person: $0) }
        .sheet(isPresented: $showAssign) {
            NavigationStack {
                PersonMultiPicker(selected: $assignSelection)
                    .navigationTitle("Who is this about?")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showAssign = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Assign") {
                                showAssign = false
                                guard let person = assignSelection.first else { return }
                                MemoryFactPromotion.assign(fact, to: person)
                            }
                            .disabled(assignSelection.isEmpty)
                        }
                    }
            }
        }
        .sheet(isPresented: $showDatePicker) {
            NavigationStack {
                Form {
                    DatePicker("Due", selection: $chosenDate, displayedComponents: .date)
                }
                .navigationTitle("Schedule Reminder")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showDatePicker = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Schedule") {
                            MemoryFactPromotion.schedule(fact, dueDate: chosenDate, context: context)
                            showDatePicker = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: fact.type.icon)
                .font(.title2)
                .foregroundStyle(fact.type.color)
                .frame(width: 56, height: 56)
                .background(fact.type.color.opacity(0.12), in: Circle())
            Text(fact.value)
                .font(SCTheme.displayFont(19, weight: .semibold))
                .multilineTextAlignment(.center)
            HStack(spacing: 6) {
                Text(fact.status.label)
                Text("·")
                Text("Confidence \(Int(fact.confidence * 100))%")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let date = fact.dateValue {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
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

    private var actionsCard: some View {
        FormSectionCard("Actions", icon: "slider.horizontal.3") {
            if fact.status == .suggested {
                Button {
                    fact.status = .active
                } label: {
                    Label("Confirm", systemImage: "checkmark")
                        .font(.subheadline.weight(.medium))
                }
            }
            if fact.status != .rejected {
                Button(role: .destructive) {
                    fact.status = .rejected
                } label: {
                    Label("Reject", systemImage: "hand.thumbsdown")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                }
            } else {
                Button {
                    fact.status = .active
                    fact.markUserEdited()
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                }
            }
            Button(role: .destructive) {
                context.delete(fact)
                dismiss()
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
            }
        }
    }
}

#Preview {
    NavigationStack {
        MemoryFactDetailView(fact: MemoryFact(type: .interest, value: "Hiking", person: nil))
    }
    .modelContainer(PreviewData.container)
}
