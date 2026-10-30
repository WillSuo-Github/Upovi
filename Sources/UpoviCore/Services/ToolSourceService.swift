import Foundation

public struct ToolCommand: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let successCodes: Set<Int32>
    public let updating: Bool
}

/// Native package managers retain ownership of global tools, registries, constraints and credentials.
/// No command uses a shell, sudo, a project directory, or installs a missing manager/plugin.
public struct ToolSourceService: Sendable {
    public typealias Runner = @Sendable (ToolCommand) async throws -> Data
    private let run: Runner
    public init(runner: @escaping Runner = ToolSourceService.systemRun) { run = runner }

    public static func systemRun(_ command: ToolCommand) async throws -> Data {
        let work = URL.applicationSupportDirectory.appending(path: "Upovi/ToolSources/Work")
        for directory in [work.deletingLastPathComponent().deletingLastPathComponent(), work.deletingLastPathComponent(), work] {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
               attributes[.type] as? FileAttributeType != .typeDirectory { throw PeerError.invalid("Linked or invalid package-manager workspace") }
        }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: work.deletingLastPathComponent().path)
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        environment["PATH"] = ([command.executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
            home.appending(path: ".cargo/bin").path, home.appending(path: ".local/bin").path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"] +
            (environment["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        for (key, value) in ["HOMEBREW_NO_AUTO_UPDATE":"1", "HOMEBREW_NO_INSTALL_CLEANUP":"1", "HOMEBREW_NO_ANALYTICS":"1",
                              "NONINTERACTIVE":"1", "NPM_CONFIG_UPDATE_NOTIFIER":"false", "NO_COLOR":"1", "UV_NO_PROGRESS":"1",
                              "PIP_DISABLE_PIP_VERSION_CHECK":"1", "PIP_NO_INPUT":"1"] {
            environment[key] = value
        }
        let log = command.updating ? work.deletingLastPathComponent().appending(path: UUID().uuidString + ".log") : nil
        do {
            let result = try await ProcessCommand().run(command.executable.path, command.arguments,
                timeoutSeconds: command.updating ? 3600 : 180, outputFile: log, environment: environment,
                maximumOutputBytes: 8_000_000, successCodes: command.successCodes, currentDirectory: work)
            if let log { try? FileManager.default.removeItem(at: log) }
            return result
        } catch {
            let detail = log.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(sanitized)
            if let log { try? FileManager.default.removeItem(at: log) }
            if error is CancellationError { throw error }
            throw PeerError.unavailable(detail?.isEmpty == false ? detail! : error.localizedDescription)
        }
    }

    public static func sanitized(_ value: String) -> String {
        StoreInstallationFailure.sanitized(value)
            .replacingOccurrences(of: #"https?://[^\s/@]+:[^\s/@]+@"#, with: "https://<redacted>@", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(bearer\s+|(?:_authToken|token|password)=)[^\s]+"#, with: "$1<redacted>", options: .regularExpression)
    }
    private func command(_ source: URL, _ args: [String], updating: Bool = false, codes: Set<Int32> = [0]) async throws -> Data {
        try await run(.init(executable: source, arguments: args, successCodes: codes, updating: updating))
    }
    private func text(_ source: URL, _ args: [String], updating: Bool = false, codes: Set<Int32> = [0]) async throws -> String {
        String(decoding: try await command(source, args, updating: updating, codes: codes), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["error"] == nil else {
            throw PeerError.invalid("Package manager returned an invalid inventory")
        }
        return value
    }
    public static func validName(_ name: String, source: ToolSource) -> Bool {
        let pattern: String = switch source {
        case .npm, .pnpm: #"^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$"#
        case .homebrew: #"^[A-Za-z0-9][A-Za-z0-9+_.@-]*(?:/[A-Za-z0-9][A-Za-z0-9+_.@-]*){0,2}$"#
        default: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#
        }
        return name.count <= 255 && name.range(of: pattern, options: .regularExpression) != nil
    }
    private static func validVersion(_ version: String) -> Bool {
        version.count <= 128 && version.range(of: #"^[0-9][A-Za-z0-9.+_~-]*$"#, options: .regularExpression) != nil
    }

    public func check(_ source: ToolSource, executable: URL) async throws -> ToolSnapshot {
        switch source {
        case .homebrew:
            let inventory = try await text(executable, ["list", "--formula", "--versions"])
            var installed: [String: String] = [:]
            for line in inventory.split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
                if fields.count >= 2 { installed[fields[0]] = fields.dropFirst().joined(separator: ", ") }
            }
            let data = try await command(executable, ["outdated", "--formula", "--json=v2"])
            let value = try object(data)
            guard let formulae = value["formulae"] as? [[String: Any]] else { throw PeerError.invalid("Missing Homebrew inventory") }
            let updates = formulae.compactMap { item -> ToolPackage? in
                guard item["pinned"] as? Bool != true, let name = item["name"] as? String,
                      let current = installed[name], let latest = item["current_version"] as? String else { return nil }
                return .init(name: name, installed: current, available: latest)
            }
            return .init(source: source, installed: installed, updates: updates, held: formulae.filter { $0["pinned"] as? Bool == true }.compactMap { $0["name"] as? String })
        case .npm, .pnpm:
            let context = try await text(executable, source == .npm ? ["prefix", "--global"] : ["root", "--global"])
            guard context.hasPrefix("/"), !context.contains("\n") else { throw PeerError.invalid("Invalid global package scope") }
            let data = try await command(executable, ["list", "--global", "--depth=0", "--json"])
            let json = try JSONSerialization.jsonObject(with: data)
            let roots = (json as? [[String: Any]]) ?? ((json as? [String: Any]).map { [$0] } ?? [])
            guard !roots.isEmpty, !roots.contains(where: { $0["error"] != nil }) else { throw PeerError.invalid("Invalid global JavaScript inventory") }
            var installed: [String: String] = [:]
            for root in roots {
                for (name, item) in root["dependencies"] as? [String: [String: Any]] ?? [:] {
                    if let version = item["version"] as? String { installed[name] = version }
                }
            }
            let outdatedData = try await command(executable, ["outdated", "--global", "--json"], codes: [0, 1])
            let decoded: Any = outdatedData.isEmpty ? [String: Any]() : try JSONSerialization.jsonObject(with: outdatedData)
            let raw: [String: Any]
            if let dictionary = decoded as? [String: Any], dictionary["error"] == nil { raw = dictionary }
            else if let rows = decoded as? [[String: Any]] {
                var values: [String: Any] = [:]
                for row in rows {
                    guard let name = (row["packageName"] ?? row["name"]) as? String else { throw PeerError.invalid("Invalid global package update metadata") }
                    values[name] = row
                }
                raw = values
            } else { throw PeerError.invalid("Invalid global package update metadata") }
            let updates = try raw.compactMap { name, value -> ToolPackage? in
                // npm and Corepack supplied by Node/Homebrew remain owned by that runtime's installer.
                guard !(source == .npm && Self.isRuntimeOwned(name, prefix: context)), let current = installed[name] else { return nil }
                guard Self.validName(name, source: source), let entry = value as? [String: Any],
                      let latest = (entry["latest"] ?? entry["latestVersion"] ?? entry["wanted"]) as? String,
                      Self.validVersion(latest) else { throw PeerError.invalid("Unsupported global package update target") }
                guard latest != current else { return nil }
                return .init(name: name, installed: current, available: latest)
            }
            return .init(source: source, context: context, installed: installed, updates: updates,
                         held: source == .npm ? installed.keys.filter { Self.isRuntimeOwned($0, prefix: context) }.sorted() : [])
        case .uv:
            return try Self.parseUV(try await text(executable, ["tool", "list", "--show-version-specifiers", "--outdated", "--color", "never"]))
        case .pipx:
            let listHelp = try await text(executable, ["list", "--help"])
            guard listHelp.contains("--skip-maintenance") else { throw PeerError.unavailable("Update pipx first: this version cannot check tools without automatic shared-library maintenance") }
            let skipMaintenance = ["--skip-maintenance"]
            let value = try object(await command(executable, ["list", "--json"] + skipMaintenance))
            guard let venvs = value["venvs"] as? [String: [String: Any]] else { throw PeerError.invalid("Missing pipx inventory") }
            var installed: [String: String] = [:], updates: [ToolPackage] = [], held: [String] = []
            for (name, entry) in venvs.sorted(by: { $0.key < $1.key }) {
                guard Self.validName(name, source: .pipx), let metadata = entry["metadata"] as? [String: Any],
                      let package = metadata["main_package"] as? [String: Any], let version = package["package_version"] as? String,
                      let packageName = package["package"] as? String else { throw PeerError.invalid("Invalid pipx package metadata") }
                installed[name] = version
                if package["pinned"] as? Bool == true { held.append(name); continue }
                let data = try await command(executable, ["runpip"] + skipMaintenance + [name, "list", "--outdated", "--format=json"])
                guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw PeerError.invalid("Invalid pipx update metadata") }
                if let row = rows.first(where: { ($0["name"] as? String)?.lowercased().replacingOccurrences(of: "_", with: "-") == packageName.lowercased().replacingOccurrences(of: "_", with: "-") }),
                   let latest = row["latest_version"] as? String { updates.append(.init(name: name, installed: version, available: latest)) }
            }
            return .init(source: source, installed: installed, updates: updates, held: held)
        case .cargo:
            return try Self.parseCargo(try await text(executable, ["install-update", "--list"]))
        case .rustup:
            return try Self.parseRustup(try await text(executable, ["check"], codes: [0, 100]))
        }
    }

    public func update(_ source: ToolSource, executable: URL, expectedContext: String?) async throws -> ToolSnapshot {
        let before = try await check(source, executable: executable)
        if let expectedContext, before.context != expectedContext { throw PeerError.invalid("Global package scope changed; check again before updating") }
        for item in before.updates {
            guard Self.validName(item.name, source: source) else { throw PeerError.invalid("Invalid global package name") }
        }
        switch source {
        case .homebrew:
            _ = try await command(executable, ["update"], updating: true)
            _ = try await command(executable, ["upgrade", "--formula"], updating: true)
        case .npm, .pnpm:
            if !before.updates.isEmpty {
                let packages = try before.updates.map { item in
                    guard Self.validVersion(item.available) else { throw PeerError.invalid("Invalid JavaScript target version") }
                    return item.name + "@" + item.available
                }
                _ = try await command(executable, (source == .npm ? ["install", "--global", "--no-fund", "--no-audit", "--"] : ["add", "--global", "--"]) + packages, updating: true)
            }
        case .uv:
            for item in before.updates { _ = try await command(executable, ["tool", "upgrade", item.name], updating: true) }
        case .pipx:
            for item in before.updates { _ = try await command(executable, ["upgrade", item.name], updating: true) }
        case .cargo:
            if !before.updates.isEmpty { _ = try await command(executable, ["install-update"] + before.updates.map(\.name), updating: true) }
        case .rustup:
            if !before.updates.isEmpty { _ = try await command(executable, ["update", "--no-self-update"] + before.updates.map(\.name), updating: true) }
        }
        let after = try await check(source, executable: executable)
        guard after.context == before.context else { throw PeerError.invalid("Global package scope changed during update") }
        for item in before.updates {
            guard let version = after.installed[item.name], version != item.installed,
                  !after.updates.contains(where: { $0.name == item.name }) else {
                throw PeerError.unavailable("Package manager did not confirm the selected update: " + item.name)
            }
        }
        guard after.updates.isEmpty else { throw PeerError.unavailable("Package manager still reports available global tool updates") }
        return after
    }

    public static func parseUV(_ text: String) throws -> ToolSnapshot {
        var installed: [String: String] = [:], updates: [ToolPackage] = [], held: [String] = []
        let expression = try NSRegularExpression(pattern: #"^([A-Za-z0-9][A-Za-z0-9._-]*) v(\S+)(?: \[required: ([^\]]+)\])?(?: \[latest: v?([^\]]+)\])?$"#)
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("- ") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let n = Range(match.range(at: 1), in: line), let v = Range(match.range(at: 2), in: line) else { throw PeerError.invalid("Unsupported uv tool inventory") }
            let name = String(line[n]), version = String(line[v]); installed[name] = version
            if Range(match.range(at: 3), in: line) != nil { held.append(name); continue }
            if let latest = Range(match.range(at: 4), in: line) { updates.append(.init(name: name, installed: version, available: String(line[latest]))) }
        }
        return .init(source: .uv, installed: installed, updates: updates, held: held)
    }
    public static func isRuntimeOwned(_ name: String, prefix: String) -> Bool {
        guard ["npm", "corepack"].contains(name) else { return false }
        let package = URL(fileURLWithPath: prefix).appending(path: "lib/node_modules").appending(path: name).resolvingSymlinksInPath().path
        return package.contains("/Cellar/") || package.contains("/.volta/tools/image/")
    }
    public static func parseCargo(_ text: String) throws -> ToolSnapshot {
        var installed: [String: String] = [:], updates: [ToolPackage] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 4, ["Yes", "No"].contains(fields[3]), fields[1].hasPrefix("v"), fields[2].hasPrefix("v") else { continue }
            let version = String(fields[1].dropFirst()), latest = String(fields[2].dropFirst())
            installed[fields[0]] = version
            if fields[3] == "Yes" { updates.append(.init(name: fields[0], installed: version, available: latest)) }
        }
        guard !installed.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.contains("Package") || text.contains("No packages") else {
            throw PeerError.invalid("Unsupported Cargo update inventory")
        }
        return .init(source: .cargo, installed: installed, updates: updates)
    }
    public static func parseRustup(_ text: String) throws -> ToolSnapshot {
        var installed: [String: String] = [:], updates: [ToolPackage] = []
        for line in text.split(separator: "\n").map(String.init) {
            let fields = line.components(separatedBy: " - ")
            guard fields.count == 2 else { continue }
            let name = fields[0]
            guard ["stable", "beta", "nightly"].contains(name.components(separatedBy: "-")[0]) else { continue }
            let versions = fields[1].components(separatedBy: " -> ")
            let current = versions[0].components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
            if let current { installed[name] = current }
            if versions.count == 2, let current, let latest = versions[1].split(separator: " ").first {
                updates.append(.init(name: name, installed: current, available: String(latest)))
            }
        }
        guard !installed.isEmpty || text.contains("no updatable toolchains") || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PeerError.invalid("Unsupported Rust toolchain inventory")
        }
        return .init(source: .rustup, installed: installed, updates: updates)
    }
}
