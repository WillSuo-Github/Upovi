import AppKit

@MainActor enum AppManagementAccessService {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles")!
    static let privacyURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!

    static func openSettings() -> Bool {
        NSWorkspace.shared.open(settingsURL) || NSWorkspace.shared.open(privacyURL)
    }

    static func revealInstaller() -> Bool {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/UpoviStoreInstaller.app")
        guard FileManager.default.fileExists(atPath: helper.path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([helper])
        return true
    }
}
