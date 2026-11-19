import SwiftUI
import AppKit

/// The text view grows inside the page's one scrolling surface. There is no
/// second inner scroll view to consume wheel events before the tabs are pinned.
struct GrowingNotesEditor: NSViewRepresentable {
    @Binding var text: String
    var textSize: Double
    var minimumHeight: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isRichText = false; view.isEditable = true; view.isSelectable = true
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.delegate = context.coordinator
        view.allowsUndo = true
        view.setAccessibilityLabel(tr("我的笔记", "My notes"))
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text {
            let selection = view.selectedRange()
            view.string = text
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        view.font = NSFont.systemFont(ofSize: textSize)
        view.textColor = .labelColor
        view.insertionPointColor = .labelColor
        view.setAccessibilityLabel(tr("我的笔记", "My notes"))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        nsView.textContainer?.containerSize = NSSize(width: max(20, width - 24), height: .greatestFiniteMagnitude)
        if let container = nsView.textContainer { nsView.layoutManager?.ensureLayout(for: container) }
        let used = nsView.textContainer.flatMap { nsView.layoutManager?.usedRect(for: $0).height } ?? 0
        return CGSize(width: width, height: max(minimumHeight, ceil(used) + 32))
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingNotesEditor
        init(_ parent: GrowingNotesEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
        }
    }
}
