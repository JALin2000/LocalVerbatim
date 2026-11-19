import Foundation
import SwiftUI
import AppKit

struct TermFlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 500, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in layout.points.enumerated() {
            let size = subviews[index].sizeThatFits(.unspecified)
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        var points: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let w = min(size.width, width)
            if x > 0 && x + w > width { x = 0; y += row + spacing; row = 0 }
            points.append(CGPoint(x: x, y: y)); x += w + spacing; row = max(row, size.height)
        }
        return (CGSize(width: width, height: y + row), points)
    }
}

struct TermTokenEditor: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var store: MeetingStore
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !Vocabulary.terms(store.selected?.vocabulary ?? "").isEmpty {
                TermFlowLayout {
                    ForEach(Array(Vocabulary.terms(store.selected?.vocabulary ?? "").enumerated()), id: \.offset) { _, term in
                        HStack(spacing: 6) {
                            Text(term).lineLimit(1)
                            Button { store.removeVocabularyTerm(term) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                    .frame(width: 16, height: 16).contentShape(Rectangle())
                            }
                                .buttonStyle(.plain).accessibilityLabel(tr("删除术语：", "Remove term: ") + term)
                        }
                        .font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 6)
                        .foregroundStyle(AppPalette.accent).background(AppPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityElement(children: .contain)
                    }
                }
            }
            CommaTermField(text: Binding(get: { store.vocabularyDraft }, set: store.setVocabularyDraft),
                           placeholder: tr("输入人名、公司名或缩写，例如：张伟、Acme、API", "Names, companies, or abbreviations, e.g. Alex Chen, Acme, API"),
                           submit: store.commitVocabularyDraft)
                .frame(height: 22)
            HStack(spacing: 5) {
                Image(systemName: store.vocabularyFeedback.isEmpty ? "comma" : "checkmark.circle.fill")
                Text(store.vocabularyFeedback.isEmpty ? tr("输入逗号或按回车，术语会变成独立标签。", "Type a comma or press Return to create a term chip.") : store.vocabularyFeedback)
                Spacer()
                Text("\(Vocabulary.terms(store.selected?.vocabulary ?? "").count)/40")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.2)))
    }
}

/// Synchronizes the native field editor after a comma. SwiftUI's plain
/// TextField can retain an editing buffer when the bound value changes back
/// to the same empty string within one keystroke. Respect marked IME text.
private struct CommaTermField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var submit: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false; field.drawsBackground = false
        field.font = NSFont.systemFont(ofSize: 13)
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.textColor = .labelColor
        field.setAccessibilityLabel(tr("添加会议术语", "Add meeting terms"))
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        context.coordinator.synchronize(field)
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommaTermField
        private var updating = false
        init(_ parent: CommaTermField) { self.parent = parent }
        func synchronize(_ field: NSTextField) {
            guard !updating else { return }
            updating = true; defer { updating = false }
            let value = parent.text
            if field.stringValue != value { field.stringValue = value }
            if let editor = field.currentEditor() as? NSTextView, editor.string != value, !editor.hasMarkedText() {
                editor.string = value
                editor.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
            }
        }
        func controlTextDidChange(_ notification: Notification) {
            guard !updating, let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.text = field.stringValue
            synchronize(field)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue; parent.submit(); synchronize(field)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard command == #selector(NSResponder.insertNewline(_:)), let field = control as? NSTextField else { return false }
            parent.text = field.stringValue; parent.submit(); synchronize(field)
            return true
        }
    }
}
