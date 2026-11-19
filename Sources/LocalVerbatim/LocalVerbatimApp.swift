import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var store: MeetingStore?
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        guard let store else { return .terminateNow }
        terminating = true
        Task { await store.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppExperience.shared.showMain()
        // We handled the reopen event. Letting AppKit also handle it can
        // restore/create another main window after a Dock/Finder reopen.
        return false
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let store, (store.recording || store.starting), !AppSettings.shared.options.closeHintShown {
            let alert = NSAlert()
            alert.messageText = tr("关闭窗口后继续在后台录音？", "Keep recording in the background?")
            alert.informativeText = tr("关闭窗口不会停止录音。可从菜单栏结束录音或重新打开窗口。退出应用会先保存录音。", "Closing the window does not stop recording. Stop or reopen from the menu bar. Quitting the app saves the recording first.")
            alert.addButton(withTitle: tr("继续在后台录音", "Continue in background"))
            alert.addButton(withTitle: tr("保持窗口打开", "Keep window open"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            AppSettings.shared.update { $0.closeHintShown = true }
        }
        sender.orderOut(nil)
        return false
    }
}

private struct WindowConnector: NSViewRepresentable {
    let configure: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = WindowProbe(); view.configure = configure; return view
    }
    func updateNSView(_ view: NSView, context: Context) { if let window = view.window { configure(window) } }
    final class WindowProbe: NSView {
        var configure: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { configure?(window) } }
    }
}

@main
struct LocalVerbatimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = MeetingStore()
    @ObservedObject private var settings = AppSettings.shared
    var body: some Scene {
        Window(AppIdentity.displayName, id: "main") {
            ContentView(store: store, engine: store.engine, capture: store.capture)
                .background(WindowConnector { window in
                    window.title = AppIdentity.displayName
                    delegate.store = store; window.delegate = delegate
                    AppExperience.shared.registerMainWindow(window)
                    AppExperience.shared.attach(store)
                }.frame(width: 0, height: 0))
        }
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(tr("新建会议", "New meeting")) { store.newMeeting() }.keyboardShortcut("n").disabled(!store.canStart)
            }
            CommandGroup(replacing: .appSettings) {
                Button(tr("设置…", "Settings…")) { AppExperience.shared.openSettings() }.keyboardShortcut(",")
            }
        }
        MenuBarExtra(AppIdentity.displayName, systemImage: store.recording && settings.options.recordingBadge ? "record.circle.fill" : "waveform") {
            Text(store.recording ? tr("正在录音 · ", "Recording · ") + clockText(store.elapsed) : AppIdentity.displayName)
            Button(tr("显示主窗口", "Show main window")) { AppExperience.shared.showMain() }
            if store.starting { Button(tr("取消启动", "Cancel start")) { store.cancelStarting() } }
            else if store.recording { Button(tr("结束录音", "Stop recording")) { Task { await store.stopRecording() } } }
            else { Button(tr("开始录音", "Start recording")) { Task { await store.startRecording() } }.disabled(!store.canStart) }
            Button(tr("设置…", "Settings…")) { AppExperience.shared.openSettings() }
            Divider()
            Button(tr("退出本地逐字稿", "Quit LocalVerbatim")) { NSApp.terminate(nil) }
        }
    }
}
