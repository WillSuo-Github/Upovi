import Foundation
import UpoviCore
import Darwin

@main
struct UpoviPeer {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(1) }
    }

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { print(usage); return }
        func option(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        func required(_ name: String) throws -> String {
            guard let value = option(name) else { throw PeerError.invalid("Missing \(name)") }; return value
        }
        func identity() throws -> PeerIdentity {
            try JSONDecoder().decode(PeerIdentity.self, from: Data(contentsOf: URL(fileURLWithPath: required("--identity"))))
        }
        let bootstrap: [DHTEndpoint]
        if let endpoint = option("--bootstrap"), let colon = endpoint.lastIndex(of: ":"), let port = UInt16(endpoint[endpoint.index(after: colon)...]), port > 0 {
            bootstrap = [.init(host: String(endpoint[..<colon]), port: port)]
        } else { bootstrap = DHTClient.publicBootstrap }
        let dht = DHTClient(bootstrap: bootstrap, allowLocal: args.contains("--allow-local"))
        // CLI runs are isolated unless a durable diagnostic state file is explicitly selected.
        let history = CommunityHistory(storageURL: option("--state-file").map { URL(fileURLWithPath: $0) })
        let community = CommunityNetwork(dht: dht, history: history)
        switch command {
        case "scan":
            let apps = await Task.detached { AppScanner.scan() }.value
            for app in apps { print("\(app.name)\t\(app.bundleID)\t\(app.version)\t\(app.build)") }
            print("apps=\(apps.count)")
        case "check-sources":
            let apps: [InstalledApp]
            if let path = option("--app"), let app = AppScanner.read(URL(fileURLWithPath: path)) { apps = [app] }
            else { apps = AppScanner.scan() }
            var results: [SourceResult] = []
            await withTaskGroup(of: SourceResult.self) { group in
                var iterator = apps.makeIterator()
                for _ in 0..<5 { if let app = iterator.next() { group.addTask { await UpdateChecker.check(app) } } }
                for await result in group {
                    results.append(result)
                    if let app = iterator.next() { group.addTask { await UpdateChecker.check(app) } }
                }
            }
            let counts = Dictionary(grouping: results, by: { $0.status.rawValue }).mapValues(\.count)
            let summary: [String: Int] = counts.merging(["applications": apps.count, "updateCandidates": results.reduce(0) { $0 + $1.candidates.count }]) { _, b in b }
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            if let path = option("--summary-file") { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
            if args.contains("--verbose") {
                for result in results.sorted(by: { $0.appID < $1.appID }) { print("\(result.status.rawValue)\t\(result.note)") }
            }
        case "install-check":
            let appPath = try required("--app")
            guard let app = AppScanner.read(URL(fileURLWithPath: appPath)),
                  let url = URL(string: try required("--url")) else { throw PeerError.invalid("Invalid installation test input") }
            let folder = URL(fileURLWithPath: try required("--journal-directory"))
            let installer = UpdateInstaller(journalDirectory: folder)
            let candidate = UpdateCandidate(version: try required("--version"), source: "Explicit diagnostic source", isCommunity: false, url: url,
                download: .init(url: url, sha256: try required("--sha256")))
            let prepared = try await installer.prepare(app: app, candidate: candidate, progress: { _, _ in })
            print("archive_integrity=valid developer_signature=valid gatekeeper=accepted prepared_version=\(prepared.replacement.version)")
            if args.contains("--apply") {
                let receipt = try await installer.install(prepared.id)
                print("installation=completed backup_retained=true")
                if args.contains("--restore") { try await installer.restore(receipt); print("restore=completed") }
            } else { await installer.discard(prepared.id) }
        case "identity":
            let path = try required("--output")
            guard !FileManager.default.fileExists(atPath: path) else { throw PeerError.invalid("Refusing to overwrite identity") }
            let own = PeerIdentity()
            try JSONEncoder().encode(own).write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            try Data(own.invitation.url.utf8).write(to: URL(fileURLWithPath: path + ".invite"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + ".invite")
            print("identity=\(own.invitation.shortID) invitation_file=\(path).invite")
        case "probe":
            let peer = PeerIdentity().invitation
            let result = try await dht.lookup(publicKey: peer.publicKey, salt: Data("upovi-connectivity-probe".utf8))
            print("dht_responders=\(result.responders)")
        case "share-public", "discover":
            let app = InstalledApp(name: "Synthetic fixture", bundleID: try required("--bundle"),
                version: option("--version") ?? "0.0", build: option("--build") ?? "", path: "/synthetic",
                teamID: option("--team") ?? "SYNTHETIC", isAppStore: option("--channel") == "app-store")
            if command == "share-public" {
                let own = try identity()
                try await community.prepare(apps: [app], sharingIdentity: own)
                let result = try await community.publish(app)
                FileHandle.standardOutput.write(Data("public_announcements=\(result.announcements) storage_acknowledgements=\(result.storage) directory_acknowledgements=\(result.directory) publisher_id=\(own.invitation.shortID)\n".utf8))
                let seconds = min(600, max(1, Int(option("--duration") ?? "60") ?? 60))
                try await Task.sleep(for: .seconds(seconds))
                await community.stopSharing()
            } else {
                // No invitation, publisher key, endpoint, or read secret is accepted here.
                let result = try await community.discover(app)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                for observation in result.observations {
                    print(String(decoding: try encoder.encode(observation.report), as: UTF8.self))
                }
                print("automatic_publishers=\(result.observations.count) discovered_endpoints=\(result.endpoints) unreachable=\(result.unreachable) directory_candidates=\(result.directoryCandidates) failed_records=\(result.failedRecords) rejected_reports=\(result.rejectedReports) dht_publishers=\(result.dhtPublishers) direct_publishers=\(result.directPublishers) dht_responders=\(result.responders)")
                if let path = option("--evidence-file") {
                    let evidence = DiscoveryEvidence(bundleID: app.bundleID, observations: result.observations.map {
                        .init(publisherID: $0.shortID, report: $0.report)
                    }, dhtPublishers: result.dhtPublishers, directPublishers: result.directPublishers,
                        rejectedReports: result.rejectedReports, failedRecords: result.failedRecords,
                        unreachableEndpoints: result.unreachable)
                    try encoder.encode(evidence).write(to: URL(fileURLWithPath: path), options: .atomic)
                }
                if args.contains("--require-report"), result.observations.isEmpty { throw PeerError.unavailable("No automatically discovered publisher returned a valid report") }
            }
        case "publish":
            let own = try identity()
            let app: InstalledApp
            if let path = option("--app") {
                guard let installed = AppScanner.read(URL(fileURLWithPath: path)) else { throw PeerError.invalid("Cannot read application") }
                app = installed
            } else {
                app = InstalledApp(name: "Synthetic fixture", bundleID: try required("--bundle"), version: try required("--version"),
                                   build: option("--build") ?? "", path: "/synthetic", teamID: "SYNTHETIC")
            }
            let count = try await dht.publish(identity: own, report: VersionReport(app: app))
            print("published_bundle=\(app.bundleID) storage_acknowledgements=\(count)")
        case "fetch":
            let invite = try String(contentsOfFile: required("--invite"), encoding: .utf8)
            let peer = try PeerInvitation(url: invite)
            let bundle = try required("--bundle")
            let channel = option("--channel") ?? "developer"
            let result = try await dht.lookup(publicKey: peer.publicKey, salt: peer.salt(bundleID: bundle, channel: channel))
            guard let record = result.record else { throw PeerError.unavailable("No record found; responders=\(result.responders)") }
            let report = try VersionReport.open(record, from: peer, bundleID: bundle, channel: channel)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            print("signature=valid dht_responders=\(result.responders)")
        default: throw PeerError.invalid(usage)
        }
    }

    static let usage = """
    UpoviPeer scan
    UpoviPeer install-check --app <path> --url <https-archive> --version <version> --sha256 <hash> --journal-directory <path> [--apply] [--restore]
    UpoviPeer check-sources [--app <path>] [--summary-file <path>] [--verbose]
    UpoviPeer identity --output <private-key-file>
    UpoviPeer probe
    UpoviPeer share-public --identity <file> --bundle <synthetic-id> --version <version> [--duration 60]
    UpoviPeer discover --bundle <id> [--team <team-id>] [--require-report]
    UpoviPeer publish --identity <file> --bundle <synthetic-id> --version <version>
    UpoviPeer publish --identity <file> --app <explicit-application-path>
    UpoviPeer fetch --invite <invitation-file> --bundle <id> [--channel developer|app-store]
    Network commands accept --bootstrap host:port and --allow-local for isolated tests.
    Public commands accept --state-file <path> for persistent replay and publication history.
    Discover accepts --evidence-file <path> to save public observations and separate DHT/direct counts.
    Identity and invitation files contain secrets. Never commit them.
    """
}

private struct DiscoveryEvidence: Encodable {
    struct Observation: Encodable {
        let publisherID: String
        let report: VersionReport
    }
    let recordedAt = Date()
    let bundleID: String
    let observations: [Observation]
    let dhtPublishers: Int
    let directPublishers: Int
    let rejectedReports: Int
    let failedRecords: Int
    let unreachableEndpoints: Int
}
