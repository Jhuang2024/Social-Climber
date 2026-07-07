import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Central helper for reliably dismissing the keyboard from anywhere.
enum KeyboardDismisser {
    /// Resigns the current first responder, closing the keyboard regardless of
    /// which text field, editor, or secure field is focused.
    static func dismiss() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
    }
}

private struct KeyboardDoneToolbar: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { KeyboardDismisser.dismiss() }
                    .fontWeight(.semibold)
            }
        }
    }
}

extension View {
    /// Adds a keyboard accessory bar with a clear **Done** button that dismisses
    /// the keyboard for any focused field on the screen. Use this on the screen's
    /// top-level container (Form / ScrollView / NavigationStack content) so every
    /// text entry field — including `TextEditor` and multi-line fields that don't
    /// support submit — always has a dismissal path.
    func keyboardDoneToolbar() -> some View {
        modifier(KeyboardDoneToolbar())
    }
}
