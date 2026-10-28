import Foundation

/// Live sources supply release metadata; only reviewed identity, trust and packaging exceptions live here.
public enum ApplicationSourceCatalog {
    public static let casks: [String: String] = [
        "com.google.Chrome": "google-chrome", "org.mozilla.firefox": "firefox",
        "com.microsoft.VSCode": "visual-studio-code", "com.microsoft.VSCodeInsiders": "visual-studio-code@insiders",
        "com.sublimetext.4": "sublime-text", "org.videolan.vlc": "vlc",
        "com.colliderli.iina": "iina", "com.googlecode.iterm2": "iterm2",
        "com.tinyspeck.slackmacgap": "slack", "com.spotify.client": "spotify",
        "com.figma.Desktop": "figma", "com.hnc.Discord": "discord", "com.raycast.macos": "raycast",
        "com.1password.1password": "1password", "com.docker.docker": "docker-desktop"
    ]


    public static let githubRepositories: [String: String] = [
        "com.knollsoft.Rectangle": "rxhanson/Rectangle", "eu.exelban.Stats": "exelban/stats",
        "com.caldis.Mos": "Caldis/Mos", "com.colliderli.iina": "iina/iina",
        "com.aone.keka": "aonez/Keka", "com.ranchero.NetNewsWire-Evergreen": "Ranchero-Software/NetNewsWire",
        "com.steipete.codexbar": "steipete/CodexBar", "app.upovi.Upovi": "WillSuo-Github/Upovi",
        "com.willsuo.livehub": "WillSuo-Github/livehub-desktop",
        "io.playcover.PlayCover": "PlayCover/PlayCover",
        "com.stablyai.orca": "stablyai/orca", "com.audiout.Audiout": "aa-hh/Audiout"
    ]

    public static let catalogExceptions: [String: String] = [
        "com.caldis.Mos": "mos",
        "abnerworks.Typora": "typora",
        "com.vscodium": "vscodium",
        "org.blenderfoundation.blender": "blender",
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.github.GitHubClient": "github",
        "com.github.githubapp": "github-copilot-app",
        "com.bjango.istatmenus": "istat-menus",
        "com.janhuelsmann.SaneSideButtons": "sanesidebuttons",
        "com.yetone.magpie": "magpie",
        "com.soda.music": "sodamusic",
        "org.pqrs.Karabiner-Elements.Settings": "karabiner-elements",
        "org.pqrs.Karabiner-EventViewer": "karabiner-elements",
        "wang.jianing.app.OpenInTerminal": "openinterminal",
        "us.zoom.xos": "zoom"
    ]


    /// Reviewed fallback for ordinary app replacement when an official source publishes no archive proof.
    /// This authorizes downloading for inspection, never installation without Developer ID and Gatekeeper checks.
    public struct DeveloperDownloadRule: Sendable {
        public let teamID: String
        public let host: String
        public let pathPrefix: String
    }
    public static let developerDownloads: [String: DeveloperDownloadRule] = [
        "com.bjango.istatmenus": .init(teamID: "Y93TK974AT", host: "cdn.istatmenus.app",
                                       pathPrefix: "/files/istatmenus7/versions/iStatMenus"),
        // The cask points at Google's unversioned stable DMG; a newer payload fails the exact version check.
        "com.google.Chrome": .init(teamID: "EQHXZ8M8AV", host: "dl.google.com",
                                   pathPrefix: "/chrome/mac/universal/stable/")
    ]

    public struct LegacyMigrationRule: Sendable {
        public let version: String
        public let build: String
        public let executableSHA256: String
        public let successorTeamID: String
    }
    // The official Mos 3.5.0 universal DMG contains a valid ad hoc signature, without a Team ID.
    // Pin its complete executable (including both code directories) and validate sealed resources at use time.
    public static let legacyMigrations: [String: LegacyMigrationRule] = [
        "com.caldis.Mos": .init(version: "3.5.0", build: "2024.01.11",
                               executableSHA256: "14e4f8367192273f8b95b8df90c63d471841a71bbc250500c648e78fc5709fe0",
                               successorTeamID: "N7Z52F27XK")
    ]
    public static func legacyMigration(for app: InstalledApp) -> LegacyMigrationRule? {
        guard !app.isAppStore, app.teamID == nil || app.teamID?.isEmpty == true,
              let rule = legacyMigrations[app.bundleID], app.version == rule.version, app.build == rule.build else { return nil }
        return rule
    }
    public static func replacementTeam(for app: InstalledApp) -> String? {
        if let team = app.teamID, !team.isEmpty { return team }
        return legacyMigration(for: app)?.successorTeamID
    }

    /// The official 7.50.1 ZIP contains a signed 7.50 / 2356 app. Keep this exact reviewed
    /// packaging exception instead of accepting arbitrary version mismatches or altering scanned versions.
    public static func bundleRelease(for app: InstalledApp, sourceVersion: String, download: URL?) -> (version: String, build: String)? {
        guard app.bundleID == "com.bjango.istatmenus", app.teamID == "Y93TK974AT", sourceVersion == "7.50.1",
              download?.absoluteString == "https://cdn.istatmenus.app/files/istatmenus7/versions/iStatMenus7.50.1.zip" else { return nil }
        return ("7.50", "2356")
    }

    public static func permitsDeveloperDownload(_ url: URL, for app: InstalledApp) -> Bool {
        guard !app.isAppStore, let rule = developerDownloads[app.bundleID], app.teamID == rule.teamID,
              url.scheme == "https", url.host?.lowercased() == rule.host, url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix(rule.pathPrefix), !url.path.contains(".."), !url.path.contains("%"),
              ["zip", "dmg"].contains(url.pathExtension.lowercased()) else { return false }
        return true
    }
}
