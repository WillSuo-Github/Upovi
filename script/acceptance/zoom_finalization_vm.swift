// Exact-package acceptance, restricted to the existing explicitly marked disposable Upovi VM.
import Darwin
import Foundation
import UpoviCore

@main struct ZoomFinalizationAcceptance {
    static func main() async throws {
        _ = try await ProcessCommand().run("/usr/bin/sudo", ["-n", "/bin/test", "-f", "/private/var/upovi-acceptance/disposable-vm"])
        guard getuid() >= 500, CommandLine.arguments.count == 3 else { throw PeerError.invalid("Use signed-bundle exact-Zoom-package as the normal VM user") }
        let bundle = URL(fileURLWithPath: CommandLine.arguments[1]), package = URL(fileURLWithPath: CommandLine.arguments[2])
        let target = URL(fileURLWithPath: "/Applications/zoom.us.app")
        guard let original = AppScanner.read(target), original.bundleID == "us.zoom.xos", original.version == "7.2.1 (88329)",
              let team = AdministratorAuthorization.teamID(at: bundle) else { throw PeerError.invalid("Unexpected VM baseline or unsigned Upovi bundle") }
        try BundleVerifier.checkSignature(target, like: original)
        let hash = "4c26ebed8bd29ce258ac9dbe0f2b327fad0a0734246ea588339a2cc5fd10533e"
        guard try BundleVerifier.sha256(of: package) == hash else { throw PeerError.invalid("Use the exact package from the reported failure") }
        let requests = FileManager.default.temporaryDirectory.appending(path: "Upovi-zoom-acceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let plan = AdministratorInstallPlan(operation: .package, application: original, version: "7.2.5.90525", artifactPath: package.path, sha256: hash)
        let candidate = UpdateCandidate(version: plan.version, source: "Acceptance", isCommunity: false, url: nil,
            download: .init(url: URL(string: "https://example.invalid/Zoom.pkg")!, sha256: hash))
        let session = AdministratorInstallSession(items: [.init(application: original, candidate: candidate, manualReason: nil)], requests: requests, hostTeam: team)
        let bootstrap = try session.bootstrap(helper: bundle.appending(path: "Contents/MacOS/UpoviInstaller"),
            storeHelper: bundle.appending(path: "Contents/Helpers/UpoviStoreInstaller.app"), bridge: bundle.appending(path: "Contents/MacOS/UpoviStoreBridge"))
        let process = Task { try await ProcessCommand().run("/usr/bin/sudo", ["-n", "/bin/sh", "-c", bootstrap], timeoutSeconds: 1200,
            outputFile: requests.appending(path: "session.log")) }
        var installed = false
        do {
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: session.results.appending(path: "ready").path) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard FileManager.default.fileExists(atPath: session.results.appending(path: "ready").path) else { throw PeerError.unavailable("Session did not become ready") }
            try JSONEncoder().encode(AdministratorInstallSession.Request.application(plan)).write(to: requests.appending(path: "0.json"), options: .atomic)
            var receipt: AdministratorInstallAttempt?
            for _ in 0..<12000 {
                if let data = try? Data(contentsOf: session.results.appending(path: "0.json")),
                   let result = try? JSONDecoder().decode(AdministratorInstallSession.Result.self, from: data) {
                    guard result.status == 0 else { throw PeerError.unavailable("Zoom helper failed: " + String(decoding: result.output, as: UTF8.self)) }
                    receipt = try JSONDecoder().decode(AdministratorInstallAttempt.self, from: result.output)
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let receipt, receipt.state == "installed", receipt.finalizationFailure == nil,
                  let current = AppScanner.read(target), current.version == "7.2.5 (90525)", current.build == "7.2.5.90525" else {
                throw PeerError.unavailable("Zoom finalization was not confirmed: \(receipt?.state ?? "no result"), \(receipt?.finalizationFailure?.message ?? "")")
            }
            try BundleVerifier.checkDeveloperIDSignature(target, like: original)
            try ApplicationInstallation.verifyFinalized(target)
            installed = true
            print("{\"packageSHA256\":\"\(hash)\",\"rootBootstraps\":1,\"from\":\"\(original.version)\",\"to\":\"\(current.version)\",\"state\":\"installed\",\"signaturePassed\":true,\"finalizationPassed\":true}")
        } catch {
            try? Data().write(to: requests.appending(path: "finish"), options: .atomic)
            _ = try? await process.value
            if let current = AppScanner.read(target), current.version == "7.2.5 (90525)" {
                try await restore(plan, bundle: bundle, team: team, requests: requests)
            }
            throw error
        }
        try Data().write(to: requests.appending(path: "finish"), options: .atomic)
        _ = try await process.value
        if installed { try await restore(plan, bundle: bundle, team: team, requests: requests) }
        _ = try await ProcessCommand().run("/usr/bin/sudo", ["-n", "/bin/rm", "-rf", "/Library/Application Support/Upovi/PrivilegedInstallations/\(plan.id.uuidString)"])
        try FileManager.default.removeItem(at: requests)
    }
    private static func restore(_ plan: AdministratorInstallPlan, bundle: URL, team: String, requests: URL) async throws {
        let restore = AdministratorInstallPlan(id: plan.id, operation: .restore, application: plan.application, version: plan.version)
        let input = requests.appending(path: "restore.json")
        try JSONEncoder().encode(restore).write(to: input, options: .atomic)
        let command = try AdministratorAuthorization.command(helper: bundle.appending(path: "Contents/MacOS/UpoviInstaller"), plan: input, hostTeam: team)
        let output = try await ProcessCommand().run("/usr/bin/sudo", ["-n", "/bin/sh", "-c", command], timeoutSeconds: 180,
            outputFile: requests.appending(path: "restore.log"))
        let receipt = try JSONDecoder().decode(AdministratorInstallAttempt.self, from: output)
        guard receipt.state == "restored", let app = AppScanner.read(URL(fileURLWithPath: plan.application.path)),
              app.version == plan.application.version, app.build == plan.application.build else { throw PeerError.invalid("The disposable VM baseline was not restored") }
        try BundleVerifier.checkSignature(URL(fileURLWithPath: app.path), like: plan.application)
        print("{\"baselineRestored\":true,\"signaturePassed\":true}")
    }
}
