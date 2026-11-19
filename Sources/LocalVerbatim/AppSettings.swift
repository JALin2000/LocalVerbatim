import Foundation
import Combine
import SwiftUI
import Carbon

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String
    static let start = Shortcut(keyCode: 15, modifiers: UInt32(controlKey | optionKey), display: "⌃⌥R")
    static let stop = Shortcut(keyCode: 1, modifiers: UInt32(controlKey | optionKey), display: "⌃⌥S")
    static let show = Shortcut(keyCode: 37, modifiers: UInt32(controlKey | optionKey), display: "⌃⌥L")
}

struct UserOptions: Codable, Equatable {
    var interfaceLanguage = "system"
    var appearance = "system"
    var textSize: Double = 14
    var reduceFillers = true
    var recordingsPath: String?
    var modelCachePath: String?
    var recordingBadge = true
    var hideDockForHotkeys = false
    var startShortcut = Shortcut.start
    var stopShortcut = Shortcut.stop
    var showShortcut = Shortcut.show
    var shortcutsEnabled = true
    var microphoneID = ""
    var defaultLanguage = ""
    var autoRefine = true
    var startSound = false
    var stopSound = false
    var completionNotifications = true
    var idleUnloadMinutes = 5
    var closeHintShown = false
    var onboardingComplete = false

    enum CodingKeys: String, CodingKey { case interfaceLanguage, appearance, textSize, reduceFillers, recordingsPath, modelCachePath, recordingBadge, hideDockForHotkeys, startShortcut, stopShortcut, showShortcut, shortcutsEnabled, microphoneID, defaultLanguage, autoRefine, startSound, stopSound, completionNotifications, idleUnloadMinutes, closeHintShown, onboardingComplete }
    init() {}
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        interfaceLanguage = try values.decodeIfPresent(String.self, forKey: .interfaceLanguage) ?? interfaceLanguage
        appearance = try values.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
        textSize = try values.decodeIfPresent(Double.self, forKey: .textSize) ?? textSize
        reduceFillers = try values.decodeIfPresent(Bool.self, forKey: .reduceFillers) ?? reduceFillers
        recordingsPath = try values.decodeIfPresent(String.self, forKey: .recordingsPath) ?? recordingsPath
        modelCachePath = try values.decodeIfPresent(String.self, forKey: .modelCachePath) ?? modelCachePath
        recordingBadge = try values.decodeIfPresent(Bool.self, forKey: .recordingBadge) ?? recordingBadge
        hideDockForHotkeys = try values.decodeIfPresent(Bool.self, forKey: .hideDockForHotkeys) ?? hideDockForHotkeys
        startShortcut = try values.decodeIfPresent(Shortcut.self, forKey: .startShortcut) ?? startShortcut
        stopShortcut = try values.decodeIfPresent(Shortcut.self, forKey: .stopShortcut) ?? stopShortcut
        showShortcut = try values.decodeIfPresent(Shortcut.self, forKey: .showShortcut) ?? showShortcut
        shortcutsEnabled = try values.decodeIfPresent(Bool.self, forKey: .shortcutsEnabled) ?? shortcutsEnabled
        microphoneID = try values.decodeIfPresent(String.self, forKey: .microphoneID) ?? microphoneID
        defaultLanguage = try values.decodeIfPresent(String.self, forKey: .defaultLanguage) ?? defaultLanguage
        autoRefine = try values.decodeIfPresent(Bool.self, forKey: .autoRefine) ?? autoRefine
        startSound = try values.decodeIfPresent(Bool.self, forKey: .startSound) ?? startSound
        stopSound = try values.decodeIfPresent(Bool.self, forKey: .stopSound) ?? stopSound
        completionNotifications = try values.decodeIfPresent(Bool.self, forKey: .completionNotifications) ?? completionNotifications
        idleUnloadMinutes = try values.decodeIfPresent(Int.self, forKey: .idleUnloadMinutes) ?? idleUnloadMinutes
        closeHintShown = try values.decodeIfPresent(Bool.self, forKey: .closeHintShown) ?? closeHintShown
        onboardingComplete = try values.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? onboardingComplete
        textSize = min(22, max(12, textSize))
        if ![0, 1, 5, 15].contains(idleUnloadMinutes) { idleUnloadMinutes = 5 }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published private(set) var options: UserOptions
    @Published var error: String?
    let file: URL

    init(file: URL = AppPaths.dataRoot.appendingPathComponent("settings.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            do { options = try JSONDecoder().decode(UserOptions.self, from: data) }
            catch {
                options = UserOptions()
                // Keep the malformed file intact; never overwrite it silently.
                self.error = "Settings could not be read. The original file is preserved."
            }
        } else { options = UserOptions() }
    }

    @discardableResult
    func update(_ change: (inout UserOptions) -> Void) -> Bool {
        var next = options
        change(&next)
        guard next != options else { return true }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if error != nil, let previous = try? Data(contentsOf: file) {
                try previous.write(to: file.deletingLastPathComponent().appendingPathComponent("settings-backup-\(UUID().uuidString).json"), options: .withoutOverwriting)
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(next).write(to: file, options: .atomic)
            options = next
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func binding<T>(_ keyPath: WritableKeyPath<UserOptions, T>) -> Binding<T> {
        Binding(get: { self.options[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    var isChinese: Bool {
        if options.interfaceLanguage == "zh-Hans" { return true }
        if options.interfaceLanguage == "en" { return false }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true
    }
    var locale: Locale { Locale(identifier: isChinese ? "zh_Hans" : "en") }
    var colorScheme: ColorScheme? { options.appearance == "dark" ? .dark : options.appearance == "light" ? .light : nil }
    var recordingsDirectory: URL { options.recordingsPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? AppPaths.dataRoot.appendingPathComponent("Recordings", isDirectory: true) }
    var modelCacheDirectory: URL { options.modelCachePath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? AppPaths.dataRoot.appendingPathComponent("Models", isDirectory: true) }
}

func tr(_ chinese: String, _ english: String) -> String { AppSettings.shared.isChinese ? chinese : english }
func formattedDate(_ date: Date, time: Bool = false) -> String {
    let formatter = DateFormatter(); formatter.locale = AppSettings.shared.locale
    formatter.dateStyle = .medium; formatter.timeStyle = time ? .short : .none
    return formatter.string(from: date)
}
