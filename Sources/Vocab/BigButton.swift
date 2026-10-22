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
