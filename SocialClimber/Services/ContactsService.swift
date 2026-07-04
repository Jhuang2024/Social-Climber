import SwiftUI
import Contacts
import ContactsUI

/// Presents the system contact picker so single contacts can be imported
/// deliberately. There is intentionally no bulk import.
struct ContactPickerView: UIViewControllerRepresentable {
    var onPick: (CNContact) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (CNContact) -> Void
        init(onPick: @escaping (CNContact) -> Void) { self.onPick = onPick }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onPick(contact)
        }
    }
}

enum ContactsImporter {
    /// Map a picked CNContact onto a new Person.
    static func person(from contact: CNContact) -> Person {
        let name = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let person = Person(name: name.isEmpty ? "Unnamed" : name, category: .acquaintance)

        if let bday = contact.birthday, bday.month != nil, bday.day != nil {
            var comps = bday
            comps.year = comps.year ?? 2000
            person.birthday = Calendar.current.date(from: comps)
        }
        var methods: [ContactMethod] = []
        for phone in contact.phoneNumbers.prefix(2) {
            methods.append(ContactMethod(label: "Phone", value: phone.value.stringValue))
        }
        for email in contact.emailAddresses.prefix(2) {
            methods.append(ContactMethod(label: "Email", value: email.value as String))
        }
        person.contactMethods = methods
        person.schoolOrWork = contact.organizationName
        if let imageData = contact.thumbnailImageData {
            person.avatarData = imageData
        }
        return person
    }
}
