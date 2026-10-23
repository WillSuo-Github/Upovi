import Foundation
import Security

public enum AppScanner {
    public static func scan(roots: [URL]? = nil) -> [InstalledApp] {
        let manager = FileManager.default
        let locations = roots ?? [URL(fileURLWithPath: "/Applications"), manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        for root in locations {
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    enumerator.skipDescendants(); continue
                }
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted, let app = read(url) else { continue }
                apps.append(app)
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func read(_ url: URL) -> InstalledApp? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")), data.count <= 2_000_000,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
        let version = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "Unknown"
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        var code: SecStaticCode?
        var signing: CFDictionary?
        if SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code {
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing)
        }
        let team = (signing as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        return InstalledApp(name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent,
                            bundleID: bundleID, version: version, build: info["CFBundleVersion"] as? String ?? "",
                            path: url.path, teamID: team,
                            isAppStore: FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path), feedURL: feed)
    }
}
