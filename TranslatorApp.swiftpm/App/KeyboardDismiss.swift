import SwiftUI
import UIKit

/// Ends editing app-wide by resigning whatever field is first responder.
/// SwiftUI has no built-in "put the keyboard away" affordance, and on a
/// hand-held iPad the software keyboard covers half the screen — so every
/// surface with text fields pairs this with a keyboard-bar Done button,
/// scroll-to-dismiss, and (where safe) tap-on-content dismissal.
@MainActor
func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
    )
}
