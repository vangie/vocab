import SwiftUI

/// Native DisclosureGroup (keeps Form row layout and the system chevron animation) whose whole header
/// row toggles it, not just the chevron: the label is a full-width plain button with a hover highlight.
/// The button is focusable (Space toggles with full keyboard access) and VoiceOver reads the state.
struct RowDisclosure<Content: View>: View {
    let title: LocalizedStringKey
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    init(_ title: LocalizedStringKey, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; _isExpanded = isExpanded; self.content = content
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { isExpanded },
                                            set: { v in withAnimation(.easeInOut(duration: 0.2)) { isExpanded = v } })) {
            content()
        } label: {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(hover ? 0.06 : 0)).padding(.horizontal, -4))
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")
        }
    }
}

/// Same, with its own expansion state.
struct RowDisclosureLocal<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: () -> Content
    @State private var open = false
    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View { RowDisclosure(title, isExpanded: $open, content: content) }
}
