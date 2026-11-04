// Run only in the explicitly marked disposable Upovi VM; never against daily applications.
import Darwin
import Foundation
import UpoviCore

@main struct AuthorizationSessionAcceptance {
    static func main() async throws {
        _ = try await ProcessCommand().run("/usr/bin/sudo", ["-n", "/bin/test", "-f", "/private/var/upovi-acceptance/disposable-vm"], outputFile: URL(fileURLWithPath: "/tmp/Upovi-session-marker.log"))
        guard getuid() >= 500, CommandLine.arguments.count == 4 else { throw PeerError.invalid("Use signed-bundle old-app new-app as the VM's normal user") }
        let bundle = URL(fileURLWithPath: CommandLine.arguments[1]), old = URL(fileURLWithPath: CommandLine.arguments[2]), new = URL(fileURLWithPath: CommandLine.arguments[3])
        guard let original = AppScanner.read(old), let replacement = AppScanner.read(new),
              original.bundleID == "com.knollsoft.Rectangle", original.version == "2.0.3", replacement.version == "2.0.4",
              let team = AdministratorAuthorization.teamID(at: bundle) else { throw PeerError.invalid("Only official Rectangle acceptance fixtures and a signed Upovi bundle are allowed") }
        try BundleVerifier.checkSignature(old, like: original); try BundleVerifier.checkSignature(new, like: original)
        let base = FileManager.default.temporaryDirectory.appending(path: "Upovi-session-acceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let requests = base.appending(path: "requests")
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let names = ["A", "B", "C", "D"]
        let targets = names.map { URL(fileURLWithPath: "/Applications/Upovi Authorization Acceptance \($0).app") }
        for target in targets {
            guard !FileManager.default.fileExists(atPath: target.path) else { throw PeerError.invalid("Acceptance target already exists") }
        }
        var plans: [AdministratorInstallPlan] = []
        var session: AdministratorInstallSession?
        var process: Task<Data, any Error>?
        do {
            for (index, target) in targets.enumerated() {
                _ = try await ProcessCommand().run("/usr/bin/sudo", ["-n", "/usr/bin/ditto", old.path, target.path], outputFile: base.appending(path: "copy.log"))
                guard let application = AppScanner.read(target) else { throw PeerError.invalid("Missing acceptance target") }
                let staged = base.appending(path: "Prepared-\(index).app")
                try FileManager.default.copyItem(at: new, to: staged)
                plans.append(.init(operation: .application, application: application, version: replacement.version,
                    build: replacement.build, artifactPath: staged.resolvingSymlinksInPath().path))
            }
            let items = plans.map { BulkUpdateItem(application: $0.application,
                candidate: .init(version: $0.version, build: $0.build, source: "Acceptance", isCommunity: false, url: nil,
                    download: .init(url: URL(string: "https://example.invalid/fixture.zip")!, sha256: String(repeating: "a", count: 64))), manualReason: nil) }
            let selected = AdministratorInstallSession(items: items, requests: requests, hostTeam: team)
            session = selected
            let command = try selected.bootstrap(helper: bundle.appending(path: "Contents/MacOS/UpoviInstaller"),
                storeHelper: bundle.appending(path: "Contents/Helpers/UpoviStoreInstaller.app"), bridge: bundle.appending(path: "Contents/MacOS/UpoviStoreBridge"))
            // This VM's established passwordless sudo replaces only the human password dialog.
            // One root process runs the exact signed-helper bootstrap used by the production session.
            process = Task { try await ProcessCommand().run("/usr/bin/sudo", ["-n", "/bin/sh", "-c", command], timeoutSeconds: 180,
                outputFile: base.appending(path: "session.log")) }
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: selected.results.appending(path: "ready").path) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard FileManager.default.fileExists(atPath: selected.results.appending(path: "ready").path) else {
                throw PeerError.unavailable("Session did not become ready")
            }
            func submit(_ request: AdministratorInstallSession.Request, index: Int) async throws -> AdministratorInstallSession.Result {
                try JSONEncoder().encode(request).write(to: requests.appending(path: "\(index).json"), options: .atomic)
                for _ in 0..<2400 {
                    if let data = try? Data(contentsOf: selected.results.appending(path: "\(index).json")),
                       let result = try? JSONDecoder().decode(AdministratorInstallSession.Result.self, from: data) { return result }
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw PeerError.unavailable("Session result timed out")
            }
            let first = try await submit(.application(plans[0]), index: 0)
            guard first.status == 0 else { throw PeerError.unavailable("First install failed: " + String(decoding: first.output, as: UTF8.self)) }
            // A late download arrives after the first privileged install is already complete.
            try await Task.sleep(for: .seconds(1))
            let second = try await submit(.application(plans[1]), index: 1)
            guard second.status == 0 else { throw PeerError.unavailable("Second install failed: " + String(decoding: second.output, as: UTF8.self)) }
            let altered = AdministratorInstallPlan(operation: .application, application: plans[2].application, version: "99.0",
                build: "999", artifactPath: plans[2].artifactPath)
            let rejected = try await submit(.application(altered), index: 2)
            guard rejected.status != 0 else { throw PeerError.invalid("Unconfirmed version was accepted") }
            try Data().write(to: requests.appending(path: "stop"), options: .atomic)
            let cancelled = try await submit(.application(plans[3]), index: 3)
            guard cancelled.status == -1 else { throw PeerError.invalid("Stopped session started another installation") }
            for (index, target) in targets.enumerated() {
                guard let current = AppScanner.read(target), current.version == (index < 2 ? "2.0.4" : "2.0.3") else { throw PeerError.invalid("Unexpected acceptance target version") }
                try BundleVerifier.checkSignature(target, like: original)
            }
            try Data().write(to: requests.appending(path: "finish"), options: .atomic)
            _ = try await process?.value
            guard !FileManager.default.fileExists(atPath: selected.results.path) else { throw PeerError.invalid("Session results were not removed") }
            print("{\"rootBootstraps\":1,\"installed\":2,\"lateSubmissionPassed\":true,\"unconfirmedVersionRejected\":true,\"stopPassed\":true,\"signaturesValid\":true,\"sessionExited\":true}")
        } catch {
            for name in ["copy.log", "session.log"] {
                if let log = try? String(contentsOf: base.appending(path: name), encoding: .utf8) { fputs("\(name): \(log)\n", stderr) }
            }
            if session != nil { try? Data().write(to: requests.appending(path: "finish"), options: .atomic) }
            _ = try? await process?.value
            try await cleanup(targets: targets, plans: plans, base: base)
            throw error
        }
        try await cleanup(targets: targets, plans: plans, base: base)
    }
    private static func cleanup(targets: [URL], plans: [AdministratorInstallPlan], base: URL) async throws {
        for target in targets { _ = try await ProcessCommand().run("/usr/bin/sudo", ["-n", "/bin/rm", "-rf", target.path]) }
        for plan in plans {
            _ = try await ProcessCommand().run("/usr/bin/sudo", ["-n", "/bin/rm", "-rf", "/Library/Application Support/Upovi/PrivilegedInstallations/\(plan.id.uuidString)"])
        }
        try FileManager.default.removeItem(at: base)
    }
}
