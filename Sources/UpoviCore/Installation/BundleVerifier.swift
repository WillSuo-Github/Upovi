import Foundation
import Security
import CryptoKit

public enum BundleVerifier {
    /// A changed app is only a successful no-op after checking its real path, exact identity and signature.
    public static func selectedUpdateIsInstalled(_ app: InstalledApp, candidate: UpdateCandidate) throws -> Bool {
        let target = URL(fileURLWithPath: app.path).standardizedFileURL
        guard !app.isAppStore, !candidate.isCommunity, let team = app.teamID, !team.isEmpty,
              target.resolvingSymlinksInPath().path == target.path,
              let current = AppScanner.read(target), !current.isAppStore,
              current.bundleID == app.bundleID, current.teamID == team else { return false }
        let order: ComparisonResult?
        if candidate.usesBuildVersion {
            guard !current.build.isEmpty, !candidate.build.isEmpty else { return false }
            order = VersionOrder.compare(current.build, candidate.build)
        } else {
            let version = VersionOrder.compare(current.version, candidate.version)
            if version == .orderedSame, !candidate.build.isEmpty {
                guard !current.build.isEmpty else { return false }
                order = VersionOrder.compare(current.build, candidate.build)
            } else { order = version }
        }
        guard order == .orderedSame || order == .orderedDescending else { return false }
        try checkDeveloperIDSignature(target, like: app)
        guard let verified = AppScanner.read(target) else { return false }
        return verified.bundleID == current.bundleID && verified.teamID == current.teamID && !verified.isAppStore
            && verified.version == current.version && verified.build == current.build
    }
    /// Apple-anchored Developer ID, rather than just an embedded team string, binds signature-only downloads.
    public static func checkDeveloperIDSignature(_ url: URL, like app: InstalledApp) throws {
        guard let team = ApplicationSourceCatalog.replacementTeam(for: app), team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil,
              app.bundleID.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else {
            throw PeerError.invalid("Invalid developer identity")
        }
        let expression = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(app.bundleID)\""
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw PeerError.invalid("Application does not have the expected Apple Developer ID signature")
        }
    }

    public static func validateDownload(_ archive: URL, descriptor: DownloadDescriptor, app: InstalledApp) throws {
        if descriptor.hasIntegrityProof { try verifyArchive(archive, descriptor: descriptor, app: app); return }
        guard descriptor.canVerify(for: app) else { throw PeerError.invalid("Missing download verification method") }
        // No archive proof exists. Revalidate the installed trust anchor now; the incoming app is checked after extraction.
        try checkDeveloperIDSignature(URL(fileURLWithPath: app.path), like: app)
    }
    public static func validate(_ url: URL, replacing app: InstalledApp, expectedVersion: String, expectedBuild: String) throws -> InstalledApp {
        guard let incoming = AppScanner.read(url), incoming.bundleID == app.bundleID,
              let team = ApplicationSourceCatalog.replacementTeam(for: app), incoming.teamID == team,
              !incoming.isAppStore, !app.isAppStore else { throw PeerError.invalid("Application identity or developer Team ID mismatch") }
        try checkSignature(url, like: app)
        let info = (try? Data(contentsOf: url.appending(path: "Contents/Info.plist"))).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            guard VersionOrder.compare(minimum, "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") != .orderedDescending else {
                throw PeerError.invalid("Update requires a newer macOS version")
            }
        }
        guard VersionOrder.compare(incoming.version, expectedVersion) == .orderedSame ||
                (expectedVersion == incoming.build && expectedBuild == incoming.build) ||
                (!incoming.build.isEmpty && expectedVersion == incoming.version + "." + incoming.build),
              expectedBuild.isEmpty || incoming.build == expectedBuild,
              VersionOrder.isNewer(version: incoming.version, build: incoming.build, than: app) else {
            throw PeerError.invalid("Downloaded application \(incoming.version) (\(incoming.build)) does not match selected update \(expectedVersion) (\(expectedBuild))")
        }
        return incoming
    }
    public static func checkSignature(_ url: URL, like app: InstalledApp) throws {
        guard let metadata = AppScanner.read(url), metadata.bundleID == app.bundleID else { throw PeerError.invalid("Backup signature identity mismatch") }
        if let legacy = ApplicationSourceCatalog.legacyMigration(for: app) {
            if metadata.teamID == nil {
                guard metadata.version == legacy.version, metadata.build == legacy.build,
                      let executable = Bundle(url: url)?.executableURL,
                      try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
                      try executable.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                      try sha256(of: executable) == legacy.executableSHA256 else {
                    throw PeerError.invalid("Legacy application does not match the reviewed official executable")
                }
            } else {
                guard metadata.teamID == legacy.successorTeamID else { throw PeerError.invalid("Legacy migration developer mismatch") }
                try checkDeveloperIDSignature(url, like: app)
                return
            }
        } else {
            guard let team = app.teamID, !team.isEmpty, metadata.teamID == team else { throw PeerError.invalid("Backup signature identity mismatch") }
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess else {
            throw PeerError.invalid("Application code signature is invalid")
        }
    }
    public static func verifyArchive(_ archive: URL, descriptor: DownloadDescriptor, app: InstalledApp) throws {
        guard descriptor.hasIntegrityProof else { throw PeerError.invalid("Missing archive integrity proof") }
        if let sha = descriptor.sha256 {
            let value = try sha256(of: archive)
            guard value.caseInsensitiveCompare(sha) == .orderedSame else { throw PeerError.invalid("Downloaded archive checksum mismatch") }
        }
        if let signature = descriptor.edSignature {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: app.path).appending(path: "Contents/Info.plist")),
                  let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let encoded = plist["SUPublicEDKey"] as? String, let raw = Data(base64Encoded: encoded),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
                  key.isValidSignature(signature, for: try Data(contentsOf: archive, options: .mappedIfSafe)) else {
                throw PeerError.invalid("Sparkle archive signature could not be verified against the installed application")
            }
        }
    }
    public static func sha256(of url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var hash = SHA256()
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty { try Task.checkCancellation(); hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
