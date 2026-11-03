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
    /// Reviewed one-way Developer ID transfer, keeping the exact application identifier.
    /// Official OpenClaw 2026.3.1 and 2026.10.9 retain the same Sparkle Ed25519 key.
    /// Original and incoming bundles must independently pass Apple-anchored Developer ID checks.
    public static func developerTeamMigration(for app: InstalledApp) -> String? {
        guard !app.isAppStore, app.bundleID == "ai.openclaw.mac", app.teamID == "Y5PE65HELJ" else { return nil }
        return "FWJYW4S8P8"
    }
    public static func replacementTeam(for app: InstalledApp) -> String? {
        if let successor = developerTeamMigration(for: app) { return successor }
        if let team = app.teamID, !team.isEmpty { return team }
        return legacyMigration(for: app)?.successorTeamID
    }

    /// Official iStat Menus ZIPs name patch releases that the signed app reports only through its build:
    /// 7.50.1 contains 7.50 / 2356 and 7.50.2 contains 7.50 / 2394. Keep these exact reviewed packaging
    /// exceptions instead of accepting arbitrary version mismatches or altering scanned versions.
    static let reviewedBundleReleases: [String: (version: String, build: String)] = [
        "7.50.1": ("7.50", "2356"),
        "7.50.2": ("7.50", "2394")
    ]
    public static func bundleRelease(for app: InstalledApp, sourceVersion: String, download: URL?) -> (version: String, build: String)? {
        guard app.bundleID == "com.bjango.istatmenus", app.teamID == "Y93TK974AT", let release = reviewedBundleReleases[sourceVersion],
              download?.absoluteString == "https://cdn.istatmenus.app/files/istatmenus7/versions/iStatMenus\(sourceVersion).zip" else { return nil }
        return release
    }

    /// Apps whose own updater reads a feed set at runtime, not `SUFeedURL`. These endpoints stage rollouts
    /// server-side, so they, not Homebrew, decide which version the developer currently offers.
    public static func officialFeed(for app: InstalledApp, installationID: String = anonymousInstallationID) -> URL? {
        guard !app.isAppStore, app.bundleID == "com.openai.codex", app.teamID == "2DC432GLL2" else { return nil }
        var components = URLComponents(string: "https://updates.oaistatic.com/codex/app/appcast")!
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // Upovi's own anonymous ID, never the app's: the rollout bucket may differ from the installed app's.
        components.queryItems = [.init(name: "installation_id", value: installationID), .init(name: "arch", value: architecture),
                                 .init(name: "app_version", value: app.version), .init(name: "beta", value: "false"),
                                 .init(name: "os-version", value: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")]
        return components.url
    }
    /// A random identifier kept per Upovi installation so staged-rollout feeds answer consistently.
    public static var anonymousInstallationID: String {
        let key = "officialFeedInstallationIDV1", defaults = UserDefaults.standard
        if let value = defaults.string(forKey: key), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
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
