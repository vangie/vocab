import SwiftUI

/// Label of the main action buttons (继续, 认识/不认识, 再学一组…): 17 pt semibold, ≥ 200 pt wide,
/// ~44 pt tall with `.controlSize(.large)`; optional key hint (↩, ←, →) in a lighter weight.
struct BigLabel: View {
    let text: String
    var hint: String? = nil
    var minWidth: CGFloat = 200
    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 17, weight: .semibold))
            if let hint { Text(hint).font(.system(size: 15)).opacity(0.6) }
        }
        .frame(minWidth: minWidth, minHeight: 36)
    }
}

/// Shared style of the quiz / test buttons: the label (text, icon + text, or BigLabel) is centred
/// both ways in a fixed-height rounded rect, so CJK text never sits low the way the system bezel
/// draws it. `prominent` = the one blue primary action. Always shows the hand cursor.
struct QuizButtonStyle: ButtonStyle {
    var prominent = false
    var height: CGFloat = 34
    var capsule = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: capsule ? height / 2 : 8, style: .continuous)
        return configuration.label
            .labelStyle(QuizLabelStyle())
            .font(.system(size: 15))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 16)
            .frame(height: height, alignment: .center)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(shape.fill(prominent ? Color.accentColor
                                   : Color(nsColor: scheme == .dark ? .controlColor : .controlBackgroundColor)))
            .overlay(shape.strokeBorder(Color.primary.opacity(prominent ? 0 : 0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 0.5, y: 0.5)
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(shape)
            .handCursor()
    }
}

/// Icon and title on one centre line (the default Label aligns the icon to the text's first baseline).
struct QuizLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 6) { configuration.icon; configuration.title }
    }
}
