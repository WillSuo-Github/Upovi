// Explicit disposable-VM acceptance. Never run against a daily application installation.
import Foundation
import UpoviCore

@main struct PrivilegedVMAcceptance {
    static func main() async throws {
        guard FileManager.default.fileExists(atPath: "/private/var/upovi-acceptance/disposable-vm") else { throw PeerError.invalid("Disposable VM marker is required; never use a daily installation") }
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { throw PeerError.invalid("Use plan|restore-plan|summary and an explicit output/transaction") }
        let target = URL(fileURLWithPath: "/Applications/zoom.us.app")
        switch args[0] {
        case "plan":
            guard let app = AppScanner.read(target), app.bundleID == "us.zoom.xos", app.version == "7.2.1 (88329)" else { throw PeerError.invalid("Only the disposable VM's old official Zoom fixture is allowed") }
            try BundleVerifier.checkSignature(target, like: app)
            try await UpdateInstaller.requestApplicationQuit(app)
            let plan = AdministratorInstallPlan(operation: .package, application: app, version: "7.2.2 (88465)", build: "7.2.2.88465",
                artifactPath: "/Volumes/My Shared Files/upovi/NewZoom.pkg", sha256: "ff15d926ef5a714c6683cc23ed628a7c2fc43d080a88ac54af4e200ba03a2456")
            try plan.validate(); try JSONEncoder().encode(plan).write(to: URL(fileURLWithPath: args[1]), options: .atomic)
            print(plan.id.uuidString)
        case "restore-plan":
            guard args.count == 3, let id = UUID(uuidString: args[1]) else { throw PeerError.invalid("Explicit transaction UUID and output required") }
            let file = URL(fileURLWithPath: "/Library/Application Support/Upovi/PrivilegedInstallations/\(id.uuidString)/receipt.json")
            let stored = try JSONDecoder().decode(AdministratorInstallAttempt.self, from: Data(contentsOf: file))
            guard stored.plan.application.path == target.path else { throw PeerError.invalid("Unexpected recovery target") }
            try await UpdateInstaller.requestApplicationQuit(stored.plan.application)
            let plan = AdministratorInstallPlan(id: id, operation: .restore, application: stored.plan.application, version: stored.plan.version, build: stored.plan.build)
            try JSONEncoder().encode(plan).write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        case "summary":
            guard let id = UUID(uuidString: args[1]) else { throw PeerError.invalid("Explicit transaction UUID required") }
            let job = URL(fileURLWithPath: "/Library/Application Support/Upovi/PrivilegedInstallations/\(id.uuidString)")
            let stored = try JSONDecoder().decode(AdministratorInstallAttempt.self, from: Data(contentsOf: job.appending(path: "receipt.json")))
            guard stored.plan.application.path == target.path else { throw PeerError.invalid("Unexpected transaction target") }
            let app = AppScanner.read(target)
            let result: [String: Any] = ["state": stored.state, "transactionID": id.uuidString,
                "version": app?.version ?? "missing", "build": app?.build ?? "missing",
                "signatureValid": (try? BundleVerifier.checkSignature(target, like: stored.plan.application)) != nil,
                "originalBackupExists": FileManager.default.fileExists(atPath: job.appending(path: "Original.app").path),
                "packageInstallerLogExists": FileManager.default.fileExists(atPath: job.appending(path: "installer.log").path)]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        default: throw PeerError.invalid("Unknown VM acceptance command")
        }
    }
}
