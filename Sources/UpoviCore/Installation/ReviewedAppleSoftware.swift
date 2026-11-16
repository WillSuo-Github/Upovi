import Foundation
import Security

/// Exact official Apple releases whose signed bundles omit CFBundlePackageType.
/// This is not a general exemption for Apple-looking names, teams or spctl failures.
enum ReviewedAppleSoftware {
    static func executableSHA256(for app: InstalledApp) -> String? {
        guard !app.isAppStore, app.bundleID == "com.apple.IconComposer", app.teamID == "59GAB85EFG" else { return nil }
        switch (app.version, app.build) {
        case ("1.1", "59"): return "99e1891f62bbcaf0363b79e0ff468de5ebe0bde7c30b6d08e2392b8591ffb1ac"
        case ("1.2", "76"): return "56c80b894211187f131420d0d463dca0300964d5ed10447a491ce080f8cb146f"
        default: return nil
        }
    }

    /// A pin is only an additional restriction: Apple's own signature, including every
    /// architecture, nested code and sealed resources, must still validate with revocation checks.
    static func verifyIfReviewed(_ url: URL) throws -> Bool {
        try Task.checkCancellation()
        guard let app = AppScanner.read(url), let expectedHash = executableSHA256(for: app) else { return false }
        let executable = url.appending(path: "Contents/MacOS/Icon Composer")
        let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              try BundleVerifier.sha256(of: executable) == expectedHash else {
            throw PeerError.invalid("Application does not match the reviewed Apple executable")
        }
        var code: SecStaticCode?, requirement: SecRequirement?
        let expression = "anchor apple and identifier \"com.apple.IconComposer\""
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures |
                kSecCSCheckNestedCode | SecCSFlags.enforceRevocationChecks.rawValue), requirement) == errSecSuccess else {
            throw PeerError.invalid("Application does not have the reviewed Apple software signature")
        }
        try Task.checkCancellation()
        return true
    }
}
