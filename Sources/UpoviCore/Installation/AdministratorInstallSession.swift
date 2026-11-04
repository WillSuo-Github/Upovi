import Darwin
import Foundation

/// A short-lived capability for exactly the updates confirmed by the user.
/// Requests contain typed plans, never shell commands supplied after authorization.
public struct AdministratorInstallSession: Codable, Sendable {
    public let id: UUID
    public let userID: UInt32
    public let parentPID: Int32
    public let requestsPath: String
    public let items: [BulkUpdateItem]
    public let hostTeam: String
    public var results: URL { URL(fileURLWithPath: "/private/var/tmp/Upovi-session-\(id.uuidString)") }

    public init(items: [BulkUpdateItem], requests: URL, hostTeam: String) {
        id = UUID(); userID = getuid(); parentPID = getpid()
        requestsPath = (try? CanonicalFilePath.resolve(requests)) ?? requests.path
        self.items = items.map { item in
            var candidate = item.candidate
            candidate.releaseNotes = nil
            return .init(application: item.application, candidate: candidate, manualReason: item.manualReason)
        }
        self.hostTeam = hostTeam
    }

    public enum Request: Codable, Sendable {
        case application(AdministratorInstallPlan)
        case store(AppStoreUpdatePlan)
        public var application: InstalledApp {
            switch self { case .application(let p): p.application; case .store(let p): p.application }
        }
    }
    public struct Result: Codable, Sendable {
        public let status: Int
        public let output: Data
        public init(status: Int, output: Data) { self.status = status; self.output = output }
    }

    public func validate() throws {
        guard userID >= 500, parentPID > 1, !items.isEmpty, items.count <= 500,
              Set(items.map(\.id)).count == items.count,
              requestsPath.hasPrefix("/private/var/folders/"), requestsPath.utf8.count < 4096,
              try CanonicalFilePath.resolve(URL(fileURLWithPath: requestsPath)) == requestsPath else {
            throw PeerError.invalid("Invalid installation session")
        }
        _ = try AdministratorAuthorization.requirement(hostTeam: hostTeam)
        for item in items {
            guard item.canInstall, !item.candidate.isCommunity else { throw PeerError.invalid("Unconfirmed installation session item") }
            if item.application.isAppStore {
                guard let storeID = item.candidate.appStoreID else { throw PeerError.invalid("Missing Store identity") }
                try AppStoreUpdatePlan(application: item.application, storeID: storeID, version: item.candidate.version,
                    userID: userID, receiptRecovery: item.candidate.storeReceiptRecovery).validate()
            } else {
                // Validate identity/destination now, before the download artifact exists.
                try AdministratorInstallPlan(operation: .inspect, application: item.application, version: item.candidate.version).validate()
            }
        }
    }

    public func validate(_ request: Request, index: Int) throws {
        guard items.indices.contains(index) else { throw PeerError.invalid("Unknown session item") }
        let item = items[index], candidate = item.candidate
        guard request.application == item.application else { throw PeerError.invalid("Session application changed") }
        switch request {
        case .application(let plan):
            try plan.validate()
            let operation: AdministratorInstallPlan.Operation = candidate.download?.url.pathExtension.lowercased() == "pkg" ? .package : .application
            let incoming = InstalledApp(name: plan.application.name, bundleID: plan.application.bundleID,
                version: plan.version, build: plan.build, path: plan.application.path, teamID: plan.application.teamID)
            guard !item.application.isAppStore, plan.operation == operation,
                  BundleVerifier.matchesSelectedVersion(incoming, replacing: item.application, expectedVersion: candidate.version,
                    expectedBuild: candidate.build, buildIsAuthoritative: candidate.comparesUsingBuild, allowPrerelease: candidate.releaseChannel == .beta),
                  (plan.permitsPrerelease == true) == (candidate.releaseChannel == .beta) else {
                throw PeerError.invalid("Installation is outside the authorized selection")
            }
        case .store(let plan):
            try plan.validate()
            guard item.application.isAppStore, plan.userID == userID, plan.storeID == candidate.appStoreID,
                  plan.version == candidate.version, plan.receiptRecovery == candidate.storeReceiptRecovery else {
                throw PeerError.invalid("Store installation is outside the authorized selection")
            }
        }
    }

    public func bootstrap(helper: URL, storeHelper: URL, bridge: URL) throws -> String {
        let q = AdministratorAuthorization.shellQuote
        let encoded = try JSONEncoder().encode(self).base64EncodedString()
        var command = """
        set -eu
        umask 077
        work=$(/usr/bin/mktemp -d /private/var/tmp/upovi-authorized.XXXXXX)
        trap '/bin/rm -rf "$work"' EXIT
        /bin/cp \(q(helper.path)) "$work/UpoviInstaller"
        /usr/bin/printf '%s' \(q(encoded)) | /usr/bin/base64 -D > "$work/session.json"
        /usr/sbin/chown -R 0:0 "$work"
        /bin/chmod 700 "$work" "$work/UpoviInstaller"
        /bin/chmod 600 "$work/session.json"
        /usr/bin/codesign --verify --strict --all-architectures -R \(q(try AdministratorAuthorization.requirement(hostTeam: hostTeam))) "$work/UpoviInstaller"
        """
        if items.contains(where: { $0.application.isAppStore }) {
            command += "\n" + """
            /usr/bin/ditto \(q(storeHelper.path)) "$work/UpoviStoreInstaller.app"
            /bin/cp \(q(bridge.path)) "$work/UpoviStoreBridge"
            /usr/sbin/chown -R 0:0 "$work"
            /bin/chmod -R go-w "$work"
            /usr/bin/codesign --verify --strict --all-architectures -R \(q(try AppStoreUpdatePlan.requirement(identifier: "app.upovi.StoreInstaller", hostTeam: hostTeam))) "$work/UpoviStoreInstaller.app"
            /usr/bin/codesign --verify --strict --all-architectures -R \(q(try AppStoreUpdatePlan.requirement(identifier: "app.upovi.StoreBridge", hostTeam: hostTeam))) "$work/UpoviStoreBridge"
            """
        }
        return command + "\n\"$work/UpoviInstaller\" --session \"$work/session.json\" \"$work\""
    }

    /// Read through a pinned directory descriptor; never follow user-controlled links or devices.
    public static func readRequest(directory: Int32, name: String, owner: UInt32) throws -> Data? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw PeerError.invalid("Unsafe session request") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == owner, info.st_size <= 65536, info.st_mode & 0o022 == 0 else {
            throw PeerError.invalid("Unsafe session request file")
        }
        let data = try handle.read(upToCount: 65537) ?? Data()
        guard data.count <= 65536 else { throw PeerError.invalid("Oversized session request") }
        return data
    }

    /// Called only by the verified root-owned helper. Installs are serialized; downloads stay unprivileged.
    public func serve(work: URL) async throws {
        guard geteuid() == 0 else { throw PeerError.invalid("Administrator authorization is required") }
        try validate()
        let directory = open(requestsPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw PeerError.invalid("Missing session request directory") }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == userID, info.st_mode & 0o077 == 0 else {
            throw PeerError.invalid("Unsafe session request directory")
        }
        // mkdir must fail for any pre-existing path, including a symlink. Only root controls results.
        guard mkdir(results.path, 0o711) == 0 else { throw PeerError.invalid("Session result path already exists") }
        defer { try? FileManager.default.removeItem(at: results) }
        guard chmod(results.path, 0o711) == 0 else { throw PeerError.unavailable("Cannot expose session results") }
        try publish(Data(), name: "ready")
        var handled = Set<Int>()
        let deadline = Date().addingTimeInterval(6 * 3600)
        while Date() < deadline, kill(parentPID, 0) == 0 {
            if try Self.readRequest(directory: directory, name: "finish", owner: userID) != nil { return }
            let stopped = try Self.readRequest(directory: directory, name: "stop", owner: userID) != nil
            for index in items.indices where !handled.contains(index) {
                guard let data = try Self.readRequest(directory: directory, name: "\(index).json", owner: userID) else { continue }
                handled.insert(index)
                let result: Result
                if stopped { result = .init(status: -1, output: Data()) }
                else {
                    do {
                        let request = try JSONDecoder().decode(Request.self, from: data)
                        try validate(request, index: index)
                        let planFile = work.appending(path: "request.json")
                        let command: String
                        switch request {
                        case .application(let plan):
                            try JSONEncoder().encode(plan).write(to: planFile, options: .atomic)
                            command = try AdministratorAuthorization.command(helper: work.appending(path: "UpoviInstaller"), plan: planFile, hostTeam: hostTeam)
                        case .store(let plan):
                            try JSONEncoder().encode(plan).write(to: planFile, options: .atomic)
                            command = try AppStoreUpdatePlan.authorizationCommand(helper: work.appending(path: "UpoviStoreInstaller.app"),
                                bridge: work.appending(path: "UpoviStoreBridge"), plan: planFile, hostTeam: hostTeam)
                        }
                        let output = try await ProcessCommand().run("/bin/sh", ["-c", command], timeoutSeconds: 2100,
                            outputFile: work.appending(path: "installer.log"), maximumOutputBytes: 65536)
                        result = .init(status: 0, output: output)
                    } catch {
                        let log = (try? Data(contentsOf: work.appending(path: "installer.log"))) ?? Data()
                        result = .init(status: 1, output: log.isEmpty ? Data(error.localizedDescription.utf8) : Data(log.prefix(65536)))
                    }
                }
                try? FileManager.default.removeItem(at: work.appending(path: "installer.log"))
                try publish(try JSONEncoder().encode(result), name: "\(index).json")
                // Recheck cancellation between every installation, including already prepared requests.
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PeerError.unavailable("Installation authorization session expired")
    }

    private func publish(_ data: Data, name: String) throws {
        let fd = open(results.appending(path: name).path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PeerError.unavailable("Cannot publish session result") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data)
        guard fchown(fd, userID, gid_t.max) == 0 else { throw PeerError.unavailable("Cannot assign session result") }
    }
}
