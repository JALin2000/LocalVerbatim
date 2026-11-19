import AppKit
import Carbon
import SwiftUI
import Combine

@MainActor
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()
    @Published private(set) var error: String?
    var onAction: ((UInt32) -> Void)?
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var installed: [Shortcut] = []
    private var editing = false
    private var suppressUntil = Date.distantPast

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let owner = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
            let action = id.id
            Task { @MainActor in if !owner.editing && Date() >= owner.suppressUntil { owner.onAction?(action) } }
            return noErr
        }, 1, &spec, context, &handler)
    }
    func beginEditing() {
        guard !editing else { return }
        editing = true
        references.forEach { UnregisterEventHotKey($0) }; references.removeAll()
    }
    func endEditing() {
        guard editing else { return }
        editing = false; suppressUntil = Date().addingTimeInterval(0.4)
        _ = register(installed)
    }
    private func register(_ shortcuts: [Shortcut]) -> Bool {
        for (index, shortcut) in shortcuts.enumerated() {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4C534352), id: UInt32(index + 1))
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference)
            guard status == noErr, let reference else {
                references.forEach { UnregisterEventHotKey($0) }; references.removeAll()
                error = tr("快捷键已被占用或无法注册：", "Shortcut is already in use or could not be registered: ") + shortcut.display
                return false
            }
            references.append(reference)
        }
        return true
    }
    @discardableResult
    func configure(_ options: UserOptions, persist: Bool = false) -> Bool {
        let next = options.shortcutsEnabled ? [options.startShortcut, options.stopShortcut, options.showShortcut] : []
        guard Set(next.map { "\($0.keyCode):\($0.modifiers)" }).count == next.count else {
            error = tr("开始、停止和显示窗口必须使用不同的快捷键。", "Start, stop and show-window shortcuts must be different.")
            return false
        }
        references.forEach { UnregisterEventHotKey($0) }; references.removeAll()
        let previous = installed
        if !register(next) {
            let problem = error
            _ = register(previous); error = problem
            return false
        }
        if persist && !AppSettings.shared.update({ $0 = options }) {
            references.forEach { UnregisterEventHotKey($0) }; references.removeAll()
            _ = register(previous)
            error = AppSettings.shared.error
            return false
        }
        installed = next; error = nil
        return true
    }
    func change(_ keyPath: WritableKeyPath<UserOptions, Shortcut>, to shortcut: Shortcut) {
        var options = AppSettings.shared.options; options[keyPath: keyPath] = shortcut
        _ = configure(options, persist: true)
    }
    func restoreDefaults() {
        var options = AppSettings.shared.options
        options.startShortcut = .start; options.stopShortcut = .stop; options.showShortcut = .show
        _ = configure(options, persist: true)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var value: Shortcut
    var changed: (Shortcut) -> Void
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton(); button.bezelStyle = .rounded; button.target = button; button.action = #selector(RecorderButton.begin)
        button.changed = changed; return button
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.stopListening() }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.changed = changed; button.savedTitle = value.display
        if !button.listening { button.title = value.display }
        button.setAccessibilityLabel(tr("设置快捷键：", "Set shortcut: ") + value.display)
    }
}

final class RecorderButton: NSButton {
    var changed: ((Shortcut) -> Void)?
    var listening = false
    var savedTitle = ""
    override var acceptsFirstResponder: Bool { true }
    @objc func begin() {
        HotkeyManager.shared.beginEditing()
        listening = true; title = tr("请按快捷键…", "Press shortcut…"); window?.makeFirstResponder(self)
    }
    func stopListening() {
        if listening { listening = false; HotkeyManager.shared.endEditing() }
        title = savedTitle
    }
    override func keyDown(with event: NSEvent) {
        guard listening else { super.keyDown(with: event); return }
        if event.keyCode == 53 { stopListening(); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else {
            title = tr("请组合 ⌘、⌃ 或 ⌥", "Include ⌘, ⌃ or ⌥"); return
        }
        var modifiers: UInt32 = 0, prefix = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); prefix += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); prefix += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); prefix += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); prefix += "⌘" }
        let name = event.charactersIgnoringModifiers?.uppercased() ?? String(event.keyCode)
        stopListening()
        changed?(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, display: prefix + name))
        title = savedTitle
    }
    override func resignFirstResponder() -> Bool { stopListening(); return super.resignFirstResponder() }
}
