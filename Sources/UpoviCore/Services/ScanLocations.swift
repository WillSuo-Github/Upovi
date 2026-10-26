import Foundation

public enum ScanLocations {
    public static var defaults: [URL] { [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")] }
    public static func normalized(_ paths: [String]) -> [String] {
        var seen = Set(defaults.map { $0.standardizedFileURL.path })
        return paths.prefix(32).compactMap { path in
            guard path.hasPrefix("/"), path.utf8.count <= 4096 else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path != "/", seen.insert(url.path).inserted else { return nil }
            return url.path
        }
    }
}
