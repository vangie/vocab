import Foundation

/// 词典 mode, like Dictionary.app: typing anywhere starts a search.
public enum TypeToSearch {
    /// Key codes never redirected: Return, Tab, Space, Delete, Esc, Enter, arrows, Home/End/PgUp/PgDn, F-keys.
    static let reserved: Set<UInt16> = [36, 48, 49, 51, 53, 76, 117, 115, 119, 116, 121, 123, 124, 125, 126,
                                        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113]

    /// Whether a keyDown should move focus to the search field and be typed there.
    /// - Parameters:
    ///   - command/control/option: modifier state (⌥ alone is allowed: it types characters like é).
    ///   - textFocused: a text view or field already has the keyboard.
    public static func shouldRedirect(characters: String?, keyCode: UInt16, command: Bool, control: Bool,
                                      lookupMode: Bool, textFocused: Bool) -> Bool {
        guard lookupMode, !textFocused, !command, !control, !reserved.contains(keyCode) else { return false }
        guard let c = characters, let u = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        // Function-key range (arrows etc. arrive as private-use scalars) and control characters.
        if (0xF700...0xF8FF).contains(u.value) || CharacterSet.controlCharacters.contains(u) { return false }
        if CharacterSet.whitespacesAndNewlines.contains(u) { return false }
        return true
    }
}
