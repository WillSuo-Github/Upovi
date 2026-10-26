import Foundation
import Darwin

public struct AppStoreUpdatePlan: Codable, Sendable {
    public let id: UUID
    public let application: InstalledApp
    public let storeID: UInt64
    public let version: String
    public let userID: UInt32
    public init(id: UUID = UUID(), application: InstalledApp, storeID: UInt64, version: String, userID: UInt32) {
        self.id = id; self.application = application; self.storeID = storeID; self.version = version; self.userID = userID
    }
    public func validate() throws {
        let app = application, target = URL(fileURLWithPath: app.path).standardizedFileURL
        guard app.isAppStore, storeID > 0, storeID < UInt64(Int64.max), userID >= 500,
              !app.bundleID.isEmpty, app.bundleID.count <= 255, version.count <= 128,
              app.path.utf8.count <= 4096, !app.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              target.path == app.path, target.deletingLastPathComponent().path == "/Applications", target.pathExtension == "app",
              target.resolvingSymlinksInPath().path == target.path,
              let team = app.teamID, team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil,
              VersionOrder.compare(version, app.version) != .orderedAscending else {
            throw PeerError.invalid("A Store update requires one signed installed App Store application directly in /Applications and a current-or-newer selected version")
        }
    }
    public static func requirement(identifier: String, hostTeam: String) throws -> String {
        guard ["app.upovi.StoreInstaller", "app.upovi.StoreBridge"].contains(identifier),
              hostTeam.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else { throw PeerError.invalid("Invalid Store helper signing identity") }
        return "=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(hostTeam)\""
    }
    public static func authorizationScript(helper: URL, bridge: URL, plan: URL, hostTeam: String) throws -> String {
        let helperRequirement = try requirement(identifier: "app.upovi.StoreInstaller", hostTeam: hostTeam)
        let bridgeRequirement = try requirement(identifier: "app.upovi.StoreBridge", hostTeam: hostTeam)
        let q = AdministratorAuthorization.shellQuote
        let command = """
        set -eu
        umask 077
        work=$(/usr/bin/mktemp -d /private/var/tmp/upovi-store-authorized.XXXXXX)
        trap '/bin/rm -rf "$work"' EXIT
        /bin/cp \(q(helper.path)) "$work/UpoviStoreInstaller"
        /bin/cp \(q(bridge.path)) "$work/UpoviStoreBridge"
        /bin/cp \(q(plan.path)) "$work/plan.json"
        /usr/sbin/chown 0:0 "$work" "$work/UpoviStoreInstaller" "$work/UpoviStoreBridge" "$work/plan.json"
        /bin/chmod 700 "$work" "$work/UpoviStoreInstaller" "$work/UpoviStoreBridge"
        /bin/chmod 600 "$work/plan.json"
        /usr/bin/codesign --verify --strict --all-architectures -R \(q(helperRequirement)) "$work/UpoviStoreInstaller"
        /usr/bin/codesign --verify --strict --all-architectures -R \(q(bridgeRequirement)) "$work/UpoviStoreBridge"
        "$work/UpoviStoreInstaller" "$work/plan.json" "$work/UpoviStoreBridge"
        """
        return "do shell script " + AdministratorAuthorization.appleScriptLiteral(command) + " with administrator privileges"
    }
    public func verifyCurrent(_ current: InstalledApp) throws {
        guard current.isAppStore, current.path == application.path, current.bundleID == application.bundleID,
              current.teamID == application.teamID, current.version == application.version, current.build == application.build else {
            throw PeerError.invalid("App Store application changed before installation")
        }
    }
    public func verifyInstalled(_ current: InstalledApp) throws {
        guard current.isAppStore, current.path == application.path, current.bundleID == application.bundleID,
              current.teamID == application.teamID, VersionOrder.compare(current.version, version) != .orderedAscending else {
            throw PeerError.invalid("The selected App Store update was not observed at the original installation path")
        }
    }
}

public struct AppStoreUpdateReceipt: Codable, Sendable {
    public let plan: AppStoreUpdatePlan
    public var state: String
    public var updatedAt: Date
    public var installedApplication: InstalledApp?
    public init(plan: AppStoreUpdatePlan, state: String) { self.plan = plan; self.state = state; updatedAt = Date() }
}

public struct AppStoreAlreadyCurrent: Error, Sendable { public init() { } }
