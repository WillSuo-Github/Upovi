import CryptoKit
import Foundation
import Security

public struct AdministratorInstallPlan: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case application, package, restore, discardBackup, inspect }
    public let id: UUID
    public let operation: Operation
    public let application: InstalledApp
    public let version: String
    public let build: String
    public let artifactPath: String
    public let sha256: String?

    public init(id: UUID = UUID(), operation: Operation, application: InstalledApp, version: String,
                build: String = "", artifactPath: String = "", sha256: String? = nil) {
        self.id = id; self.operation = operation; self.application = application; self.version = version
        self.build = build; self.artifactPath = artifactPath; self.sha256 = sha256
    }
    public func validate() throws {
        guard application.path.utf8.count <= 4096, artifactPath.utf8.count <= 4096,
              version.count <= 128, build.count <= 128, application.bundleID.count <= 255,
              !application.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !artifactPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PeerError.invalid("Administrator plan contains oversized or unsafe fields")
        }
        let target = URL(fileURLWithPath: application.path).standardizedFileURL
        guard target.deletingLastPathComponent().path == "/Applications", target.pathExtension == "app",
              application.path == target.path, target.resolvingSymlinksInPath().path == target.path,
              application.bundleID != "app.upovi.Upovi", !application.isAppStore,
              let team = application.teamID, team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
            throw PeerError.invalid("Administrator installation requires a signed direct-distribution app directly in /Applications")
        }
        guard ![.restore, .discardBackup, .inspect].contains(operation) else { return }
        let artifact = URL(fileURLWithPath: artifactPath).standardizedFileURL
        guard artifact.path == artifactPath, artifact.resolvingSymlinksInPath().path == artifact.path,
              artifactPath != application.path, VersionOrder.isNewer(version: version, build: build, than: application) else {
            throw PeerError.invalid("Invalid installation artifact or selected version")
        }
        if operation == .package {
            guard artifact.pathExtension.lowercased() == "pkg", let sha256,
                  sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else { throw PeerError.invalid("A PKG requires a verified SHA-256") }
        } else if artifact.pathExtension != "app" { throw PeerError.invalid("Expected a prepared application bundle") }
    }
}

public struct AdministratorInstallAttempt: Codable, Identifiable, Sendable {
    public let plan: AdministratorInstallPlan
    public var id: UUID { plan.id }
    public var state: String
    public var updatedAt: Date
    public var installedApplication: InstalledApp?
    public var backupBytes: Int64?
    public var backupBytesIsLowerBound: Bool?
    public var cleanupComplete: Bool?
    public init(plan: AdministratorInstallPlan, state: String) { self.plan = plan; self.state = state; updatedAt = Date() }
}

public enum AdministratorAuthorization {
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
    public static func requirement(hostTeam: String) throws -> String {
        guard hostTeam.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
            throw PeerError.invalid("Administrator installation requires a Developer ID signed Upovi build")
        }
        // codesign/csreq distinguish inline requirements from filenames using the leading '='.
        return "=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier \"app.upovi.Installer\" and certificate leaf[subject.OU] = \"\(hostTeam)\""
    }
    public static func script(helper: URL, plan: URL, hostTeam: String) throws -> String {
        let requirement = try requirement(hostTeam: hostTeam)
        let command = """
        set -eu
        umask 077
        work=$(/usr/bin/mktemp -d /private/var/tmp/upovi-authorized.XXXXXX)
        trap '/bin/rm -rf "$work"' EXIT
        /bin/cp \(shellQuote(helper.path)) "$work/UpoviInstaller"
        /usr/sbin/chown 0:0 "$work" "$work/UpoviInstaller"
        /bin/chmod 700 "$work" "$work/UpoviInstaller"
        /usr/bin/codesign --verify --strict --all-architectures -R \(shellQuote(requirement)) "$work/UpoviInstaller"
        /bin/cp \(shellQuote(plan.path)) "$work/plan.json"
        /usr/sbin/chown 0:0 "$work/plan.json"
        /bin/chmod 600 "$work/plan.json"
        "$work/UpoviInstaller" "$work/plan.json"
        """
        return "do shell script " + appleScriptLiteral(command) + " with administrator privileges"
    }
    public static func teamID(at url: URL) -> String? {
        var code: SecStaticCode?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
