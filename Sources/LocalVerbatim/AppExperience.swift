import AppKit
import Combine
import UserNotifications
import ServiceManagement

@MainActor
final class AppExperience: ObservableObject {
    static let shared = AppExperience()
    @Published var notificationsAllowed = false
    @Published var launchAtLogin = false
    @Published var error: String?
    weak var store: MeetingStore?
    weak var mainWindow: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Timer?
    private var idleSince: Date?
    private var icon: NSImage?
    private var lastBadge = false

    func attach(_ store: MeetingStore) {
        guard self.store == nil else { return }
        self.store = store; icon = AppBrand.icon
        NSApp.applicationIconImage = AppBrand.icon
        _ = HotkeyManager.shared.configure(AppSettings.shared.options)
        HotkeyManager.shared.onAction = { [weak self] action in
            guard let self, let store = self.store else { return }
            switch action {
            case 1:
                guard store.canStart, !store.showSetup, !store.showSettings else { return }
                Task {
                    await store.startRecording()
                    if store.recording && AppSettings.shared.options.hideDockForHotkeys {
                        self.mainWindow?.orderOut(nil)
                        NSApp.setActivationPolicy(.accessory)
                    } else if store.errorMessage != nil { self.showMain() }
                }
            case 2:
                if store.starting { store.cancelStarting() }
                else { Task { await store.stopRecording() } }
            default: self.showMain()
            }
        }
        store.onRecordingStarted = { [weak self] in
            self?.updateBadge()
            if AppSettings.shared.options.startSound { NSSound(named: "Tink")?.play() }
        }
        store.onRecordingStopped = { [weak self] in
            self?.updateBadge()
            if AppSettings.shared.options.stopSound { NSSound(named: "Pop")?.play() }
        }
        store.onTranscriptReady = { [weak self] in self?.notifyReady() }
        AppSettings.shared.$options.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.updateBadge() }
        }.store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIdle() }
        }
        refreshSystemPreferences()
    }
    func registerMainWindow(_ window: NSWindow) {
        window.tabbingMode = .disallowed
        window.isRestorable = false
        if let existing = mainWindow, existing !== window {
            // Discard a legacy restored duplicate without invoking the normal
            // close-to-background delegate. Both views share the same store.
            window.delegate = nil
            window.close()
            return
        }
        mainWindow = window
        window.identifier = NSUserInterfaceItemIdentifier("LocalVerbatim.main")
    }
    func showMain() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
    }
    func openSettings() { showMain(); store?.showSetup = false; store?.showSettings = true }
    func updateBadge() {
        let badge = store?.recording == true && AppSettings.shared.options.recordingBadge
        guard badge != lastBadge, let icon else { return }
        lastBadge = badge
        if !badge { NSApp.applicationIconImage = icon; return }
        let size = NSSize(width: 256, height: 256)
        NSApp.applicationIconImage = NSImage(size: size, flipped: false) { rect in
            icon.draw(in: rect)
            NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 185, y: 185, width: 65, height: 65)).fill()
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: 191, y: 191, width: 53, height: 53)).fill()
            return true
        }
    }
    private func checkIdle() {
        guard let store, !store.recording, !store.starting, !store.stopping, store.engine.pendingCount == 0, store.engine.ready else { idleSince = nil; return }
        let minutes = AppSettings.shared.options.idleUnloadMinutes
        guard minutes > 0 else { idleSince = nil; return }
        if idleSince == nil { idleSince = Date() }
        if Date().timeIntervalSince(idleSince!) >= Double(minutes * 60) { store.engine.unload(); idleSince = nil }
    }
    func refreshSystemPreferences() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in self.notificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional }
        }
    }
    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, error in
            Task { @MainActor in self.error = error?.localizedDescription; self.refreshSystemPreferences() }
        }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshSystemPreferences()
        } catch { self.error = error.localizedDescription }
    }
    private func notifyReady() {
        guard AppSettings.shared.options.completionNotifications, notificationsAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = AppIdentity.displayName
        content.body = tr("逐字稿已处理完成，可在应用中查看。", "Your transcript is ready to review in the app.")
        // Deliberately omit meeting names, transcript text and notification sound.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
