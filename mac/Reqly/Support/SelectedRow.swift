import SwiftUI

extension View {
    /// Marks a row of a grouped form as selected, the way a list marks its selection. Grouped
    /// forms on the Mac ignore `listRowBackground`, so the row draws the highlight itself, out
    /// into the row's margins, without changing its size.
    func selectedRow(_ isSelected: Bool) -> some View {
        background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.2))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -5)
            }
        }
    }
}
