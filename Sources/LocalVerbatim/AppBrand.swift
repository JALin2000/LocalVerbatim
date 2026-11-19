import AppKit

enum AppBrand {
    static let icon: NSImage = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AppIcon.icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 32, height: 32))
    }()
}
