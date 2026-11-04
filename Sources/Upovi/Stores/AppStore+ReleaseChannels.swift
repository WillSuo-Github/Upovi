import Foundation
import UpoviCore

extension AppStore {
    func releaseChannel(for app: InstalledApp) -> ReleaseChannel { sourceOverrides[app.bundleID]?.releaseChannel ?? .stable }

    func setReleaseChannel(_ channel: ReleaseChannel, for app: InstalledApp) {
        guard !app.isAppStore, channel != releaseChannel(for: app) else { return }
        var next = sourceOverrides
        var source = next[app.bundleID] ?? .init()
        source.releaseChannel = channel; next[app.bundleID] = source
        guard let data = try? JSONEncoder().encode(next), preferences.set(data, forKey: "sourceOverridesV1") else { return }
        sourceOverrides = next; sourceResults = [:]; cancelChecking()
    }
}
