import SwiftUI
import SwiftData
import PhotosUI

/// Add & edit form for a Person. Pass nil (default) to create a new person.
struct PersonEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var person: Person?

    @State private var name = ""
    @State private var nickname = ""
    @State private var relationshipToMe = ""
    @State private var category: PersonCategory = .friend
    @State private var closeness = 3
    @State private var priority = 3
    @State private var hasBirthday = false
    @State private var birthday = Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1)) ?? .now
    @State private var schoolOrWork = ""
    @State private var location = ""
    @State private var notes = ""
    @State private var personalityNotes = ""
    @State private var interests: [String] = []
    @State private var dislikes: [String] = []
    @State private var familyMembers: [String] = []
    @State private var tags: [String] = []
    @State private var contactMethods: [ContactMethod] = []
    @State private var customCadence = false
    @State private var cadenceDays = 30
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var avatarError: String?
    @State private var newMethodLabel = "Phone"
    @State private var newMethodValue = ""

    private let methodLabels = ["Phone", "Email", "Instagram", "LinkedIn", "Discord", "Other"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile Photo") {
                    VStack(spacing: 12) {
                        avatarPreview

                        PhotosPicker(selection: $avatarItem, matching: .images) {
                            Label(avatarData == nil ? "Choose from Photos" : "Change Photo", systemImage: "photo.on.rectangle")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        if avatarData != nil {
                            Button(role: .destructive) {
                                avatarItem = nil
                                avatarData = nil
                                avatarError = nil
                            } label: {
                                Label("Remove Photo", systemImage: "trash")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }

                        if let avatarError {
                            Text(avatarError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Name", text: $name)
                        .submitLabel(.done)
                    TextField("Nickname", text: $nickname)
                        .submitLabel(.done)
                    TextField("Relationship to me (e.g. Berkeley roommate)", text: $relationshipToMe, axis: .vertical)
                }

                Section("Relationship") {
                    Picker("Category", selection: $category) {
                        ForEach(PersonCategory.allCases) { category in
                            Label(category.label, systemImage: category.icon).tag(category)
                        }
                    }
                    DotRatingPicker(label: "Closeness", value: $closeness, color: .pink)
                    DotRatingPicker(label: "Priority", value: $priority, color: .orange)
                    Toggle("Custom check-in cadence", isOn: $customCadence)
                        .tint(.green)
                    if customCadence {
                        Stepper("Every \(cadenceDays) days", value: $cadenceDays, in: 1...365)
                    }
                    if person != nil {
                        Text("Closeness also adjusts on its own as you log interactions; set it here only to correct it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Details") {
                    Toggle("Birthday", isOn: $hasBirthday)
                        .tint(.green)
                    if hasBirthday {
                        DatePicker("Date", selection: $birthday, displayedComponents: .date)
                    }
                    TextField("School / Work", text: $schoolOrWork)
                        .submitLabel(.done)
                    TextField("Location", text: $location)
                        .submitLabel(.done)
                }

                Section("Contact Methods") {
                    ForEach(contactMethods) { method in
                        HStack {
                            Text(method.label).foregroundStyle(.secondary)
                            Spacer()
                            Text(method.value)
                        }
                    }
                    .onDelete { contactMethods.remove(atOffsets: $0) }
                    HStack {
                        Picker("", selection: $newMethodLabel) {
                            ForEach(methodLabels, id: \.self) { Text($0) }
                        }
                        .labelsHidden()
                        TextField("Value", text: $newMethodValue)
                            .submitLabel(.done)
                        Button {
                            let value = newMethodValue.trimmingCharacters(in: .whitespaces)
                            guard !value.isEmpty else { return }
                            contactMethods.append(ContactMethod(label: newMethodLabel, value: value))
                            newMethodValue = ""
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                    }
                }

                Section("Interests") { TagListEditor(label: "interest", items: $interests) }
                Section("Dislikes") { TagListEditor(label: "dislike", items: $dislikes) }
                Section("Family Members") { TagListEditor(label: "family member", items: $familyMembers) }
                Section("Tags") { TagListEditor(label: "tag", items: $tags) }

                Section("Notes") {
                    TextField("General notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                    TextField("Personality notes", text: $personalityNotes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(person == nil ? "New Person" : "Edit Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .keyboardDoneButton()
            .onAppear(perform: load)
            .onChange(of: avatarItem) {
                Task {
                    await loadSelectedAvatar()
                }
            }
        }
    }

    @MainActor
    private func loadSelectedAvatar() async {
        avatarError = nil
        guard let avatarItem else { return }

        do {
            guard let data = try await avatarItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let compressed = image.jpegData(compressionQuality: 0.82) else {
                avatarError = "That photo couldn't be loaded. Try another image from Photos."
                return
            }
            avatarData = compressed
        } catch {
            avatarError = "Photo access failed. You can allow Photos access in iOS Settings and try again."
        }
    }

    private var avatarPreview: some View {
        Group {
            if let avatarData, let image = UIImage(data: avatarData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle()
                        .fill(.thinMaterial)
                        .frame(width: 84, height: 84)
                    Image(systemName: "person.crop.circle.badge.camera")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel(avatarData == nil ? "No profile photo selected" : "Selected profile photo")
    }

    private func load() {
        guard let person else { return }
        name = person.name
        nickname = person.nickname
        relationshipToMe = person.relationshipToMe
        category = person.category
        closeness = person.closeness
        priority = person.priority
        if let bday = person.birthday {
            hasBirthday = true
            birthday = bday
        }
        schoolOrWork = person.schoolOrWork
        location = person.location
        notes = person.notes
        personalityNotes = person.personalityNotes
        interests = person.interests
        dislikes = person.dislikes
        familyMembers = person.familyMembers
        tags = person.tags
        contactMethods = person.contactMethods
        avatarData = person.avatarData
        if let cadence = person.checkInCadenceDays {
            customCadence = true
            cadenceDays = cadence
        }
    }

    private func save() {
        let target = person ?? Person(name: name)
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.nickname = nickname.trimmingCharacters(in: .whitespaces)
        target.relationshipToMe = relationshipToMe.trimmingCharacters(in: .whitespaces)
        target.category = category
        target.closeness = closeness
        target.priority = priority
        target.birthday = hasBirthday ? birthday : nil
        target.schoolOrWork = schoolOrWork
        target.location = location
        target.notes = notes
        target.personalityNotes = personalityNotes
        target.interests = interests
        target.dislikes = dislikes
        target.familyMembers = familyMembers
        target.tags = tags
        target.contactMethods = contactMethods
        target.avatarData = avatarData
        target.checkInCadenceDays = customCadence ? cadenceDays : nil
        target.updatedAt = .now

        if person == nil { context.insert(target) }
        NotificationService.shared.scheduleBirthday(for: target)
        Haptics.success()
        dismiss()
    }
}

#Preview {
    PersonEditView()
        .modelContainer(PreviewData.container)
}
