import SwiftUI

/// Keep the field name outside native controls so long translations cannot
/// squeeze it into a narrow column beside a segmented picker or popup.
struct LabeledControl<Control: View>: View {
    let title: String
    let control: Control
    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true) // The native control retains its accessible label.
            control.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
