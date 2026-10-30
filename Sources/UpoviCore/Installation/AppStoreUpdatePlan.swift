import Foundation
import Darwin

public struct AppStoreUpdatePlan: Codable, Sendable {
    public let id: UUID
    public let application: InstalledApp
    public let storeID: UInt64
    public let version: String
    public let userID: UInt32
    public let receiptRecovery: StoreReceiptRecovery?
    public init(id: UUID = UUID(), application: InstalledApp, storeID: UInt64, version: String, userID: UInt32, receiptRecovery: StoreReceiptRecovery? = nil) {
        self.id = id; self.application = application; self.storeID = storeID; self.version = version; self.userID = userID; self.receiptRecovery = receiptRecovery
    }
    public func validate() throws {
        try receiptRecovery?.validate()
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
        AdministratorAuthorization.script(command: try authorizationCommand(helper: helper, bridge: bridge, plan: plan, hostTeam: hostTeam))
    }
    public static func authorizationCommand(helper: URL, bridge: URL, plan: URL, hostTeam: String) throws -> String {
        let helperRequirement = try requirement(identifier: "app.upovi.StoreInstaller", hostTeam: hostTeam)
        let bridgeRequirement = try requirement(identifier: "app.upovi.StoreBridge", hostTeam: hostTeam)
        let q = AdministratorAuthorization.shellQuote
        let command = """
        set -eu
        umask 077
        work=$(/usr/bin/mktemp -d /private/var/tmp/upovi-store-authorized.XXXXXX)
        trap '/bin/rm -rf "$work"' EXIT
        /usr/bin/ditto \(q(helper.path)) "$work/UpoviStoreInstaller.app"
        /bin/cp \(q(bridge.path)) "$work/UpoviStoreBridge"
        /bin/cp \(q(plan.path)) "$work/plan.json"
        /usr/sbin/chown -R 0:0 "$work"
        /bin/chmod 755 "$work"
        /bin/chmod -R a+rX,go-w "$work/UpoviStoreInstaller.app"
        /bin/chmod 700 "$work/UpoviStoreBridge"
        /bin/chmod 600 "$work/plan.json"
        /usr/bin/codesign --verify --strict --all-architectures -R \(q(helperRequirement)) "$work/UpoviStoreInstaller.app"
        /usr/bin/codesign --verify --strict --all-architectures -R \(q(bridgeRequirement)) "$work/UpoviStoreBridge"
        console=$(/usr/bin/stat -f %u /dev/console)
        /bin/launchctl asuser "$console" "$work/UpoviStoreInstaller.app/Contents/MacOS/UpoviStoreInstaller" "$work/plan.json" "$work/UpoviStoreBridge"
        """
        return command
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
    public func updateArguments(for product: StoreProduct) throws -> [String]? {
        try validate()
        guard receiptRecovery == nil else { throw PeerError.invalid("Receipt recovery must not start a download") }
        try product.validate(for: application, storeID: storeID)
        guard VersionOrder.compare(product.version, version) != .orderedAscending else {
            throw PeerError.unavailable("The selected update is not currently available from the App Store")
        }
        guard VersionOrder.compare(product.version, application.version) == .orderedDescending else { return nil }
        // --accurate probes the download queue and cancels its probe asynchronously. Starting an update
        // immediately afterwards races that cancellation. Identity and compatibility were checked above.
        return ["update", "--force", String(storeID)]
    }
}

public struct AppStoreUpdateReceipt: Codable, Sendable {
    public let plan: AppStoreUpdatePlan
    public var state: String
    public var updatedAt: Date
    public var installedApplication: InstalledApp?
    public var failure: StoreInstallationFailure?
    public init(plan: AppStoreUpdatePlan, state: String) { self.plan = plan; self.state = state; updatedAt = Date() }
}

/// A bounded diagnostic crosses the administrator boundary with the receipt.
public struct StoreInstallationFailure: Codable, Sendable {
    public let stage: String
    public let message: String
    public let domain: String
    public let code: Int
    public init(stage: String, error: any Error, detail: String? = nil) {
        self.stage = stage
        let ns = error as NSError
        domain = ns.domain; code = ns.code
        let cleaned = Self.sanitized(detail ?? "")
        if let start = cleaned.range(of: "Error:") { message = String(cleaned[start.lowerBound...]) }
        else if cleaned.contains("Error Domain=") { message = cleaned }
        else { message = Self.sanitized(error.localizedDescription) }
    }
    public var requiresAppManagement: Bool {
        message.contains("Operation not permitted") || message.contains("NSCocoaErrorDomain Code=513") ||
            (domain == NSCocoaErrorDomain && code == 513) || (domain == NSPOSIXErrorDomain && [1, 13].contains(code))
    }
    public func recoverableReceiptPath(application: InstalledApp) -> String? {
        let pattern = #"Failed to copy receipt[^\n]* from '([^']+)' to '([^']+)'"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let sourceRange = Range(match.range(at: 1), in: message), let targetRange = Range(match.range(at: 2), in: message),
              String(message[targetRange]) == application.path + "/Contents/_MASReceipt/receipt" else { return nil }
        return String(message[sourceRange])
    }
    public static func sanitized(_ text: String) -> String {
        String(text.suffix(4096))
            .replacingOccurrences(of: #"\x1B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+"#, with: "<redacted-email>", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct StoreInstallationError: LocalizedError, Sendable {
    public let failure: StoreInstallationFailure
    public init(_ failure: StoreInstallationFailure) { self.failure = failure }
    public var errorDescription: String? {
        if failure.requiresAppManagement {
            return String(localized: "请在系统设置的“隐私与安全 → 应用程序管理”中允许 Upovi Installer，然后重试。应用主程序可能已更新，重试将优先完成安装收尾。")
        }
        return String(localized: "商店更新未完成：\(failure.message)")
    }
}

public struct AppStoreAlreadyCurrent: Error, Sendable { public init() { } }
