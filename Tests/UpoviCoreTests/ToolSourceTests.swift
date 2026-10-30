import XCTest
@testable import UpoviCore

final class ToolSourceTests: XCTestCase {
    func testDiscoveryUsesNativeExecutableNamesAndRequiresCargoUpdate() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["brew", "npm", "pnpm", "uv", "pipx", "cargo", "cargo-install-update", "rustup"] {
            let path = root.appending(path: name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        let discovered = ToolSourceDiscovery.locations(home: root, path: root.path)
        XCTAssertEqual(discovered.count, ToolSource.allCases.count)
        XCTAssertEqual(discovered[.homebrew], root.appending(path: "brew"))
        XCTAssertEqual(discovered[.uv], root.appending(path: "uv"))
        for source in ToolSource.allCases { XCTAssertEqual(discovered[source]?.deletingLastPathComponent().path, root.path) }
    }
    func testDocumentedNativeInventoriesAndPinnedRustVersions() throws {
        let uv = try ToolSourceService.parseUV("ruff v0.9.0 [latest: 0.10.0]\n- ruff\nhttpie v3.2.1\n- http\n")
        XCTAssertEqual(uv.installed.count, 2); XCTAssertEqual(uv.updates.first?.name, "ruff")
        let rust = try ToolSourceService.parseRustup("stable-aarch64-apple-darwin - update available: 1.97.1 (hash date) -> 1.99.1 (hash date)\n1.90.0-aarch64-apple-darwin - up to date : 1.90.0\nrustup - up to date : 1.28.0")
        XCTAssertEqual(rust.updates.map(\.name), ["stable-aarch64-apple-darwin"])
        let cargo = try ToolSourceService.parseCargo("Package Installed Latest Needs update\nchecksums v0.5.0 v0.5.2 Yes\ntreesize v0.2.0 v0.2.0 No")
        XCTAssertEqual(cargo.installed.count, 2); XCTAssertEqual(cargo.updates.first?.available, "0.5.2")
        XCTAssertThrowsError(try ToolSourceService.parseUV("unexpected output"))
        XCTAssertThrowsError(try ToolSourceService.parseRustup("unexpected output"))
        XCTAssertThrowsError(try ToolSourceService.parseCargo("unexpected output"))
        let pinned = try ToolSourceService.parseUV("server v2.2.2 [required: ==2.2.2] [latest: 2.2.6]\n- server")
        XCTAssertTrue(pinned.updates.isEmpty); XCTAssertEqual(pinned.held, ["server"])
    }
    func testNamesCannotBecomeOptionsPathsOrShellCommands() {
        XCTAssertTrue(ToolSourceService.validName("@scope/tool", source: .npm))
        XCTAssertTrue(ToolSourceService.validName("tap/tools/package", source: .homebrew))
        for value in ["--global", "../package", "/tmp/tool", "tool;echo bad", "tool\nnext", "https://bad.example/tool"] {
            for source in ToolSource.allCases { XCTAssertFalse(ToolSourceService.validName(value, source: source), value) }
        }
        let clean = ToolSourceService.sanitized("https://user:secret@example.invalid/path _authToken=secret Bearer secret")
        XCTAssertFalse(clean.contains("secret"))
    }
    func testNpmUsesGlobalExactVersionArgumentsAndVerifiesTheInstalledResult() async throws {
        let runner = NpmToolReplies()
        let service = ToolSourceService(runner: { try await runner.run($0) })
        let result = try await service.update(.npm, executable: URL(fileURLWithPath: "/fixture/npm"), expectedContext: "/fixture/global")
        XCTAssertEqual(result.installed["@scope/tool"], "2.0.0")
        XCTAssertTrue(result.updates.isEmpty)
        let commands = await runner.commands
        XCTAssertEqual(commands.filter(\.updating).map(\.arguments), [["install", "--global", "--no-fund", "--no-audit", "--", "@scope/tool@2.0.0"]])
        XCTAssertTrue(commands.filter { $0.arguments.first == "outdated" }.allSatisfy { $0.successCodes.contains(1) })
        XCTAssertTrue(commands.allSatisfy { $0.executable.path == "/fixture/npm" })
    }
    func testChangedGlobalScopeAndUnconfirmedInstallationNeverSucceed() async throws {
        let changed = NpmToolReplies()
        do {
            _ = try await ToolSourceService(runner: { try await changed.run($0) }).update(.npm, executable: URL(fileURLWithPath: "/fixture/npm"), expectedContext: "/other/prefix")
            XCTFail("Changed scope must block writes")
        } catch { }
        let changedCommands = await changed.commands
        XCTAssertFalse(changedCommands.contains(where: \.updating))
        let failed = NpmToolReplies(installWorks: false)
        do {
            _ = try await ToolSourceService(runner: { try await failed.run($0) }).update(.npm, executable: URL(fileURLWithPath: "/fixture/npm"), expectedContext: nil)
            XCTFail("Exit zero without a version change cannot be success")
        } catch { }
    }
    func testHomebrewUsesFormulaOwnershipAndKeepsPinnedPackagesOut() async throws {
        let replies = BrewToolReplies()
        let service = ToolSourceService(runner: { try await replies.run($0) })
        let result = try await service.update(.homebrew, executable: URL(fileURLWithPath: "/fixture/brew"), expectedContext: nil)
        XCTAssertTrue(result.updates.isEmpty)
        let commands = await replies.commands
        XCTAssertEqual(commands.filter(\.updating).map(\.arguments), [["update"], ["upgrade", "--formula"]])
        XCTAssertFalse(commands.contains { $0.arguments.contains("--cask") || $0.arguments.contains("--force") })
    }
    func testProcessCommandAcceptsDocumentedNonzeroReadStatusAndUsesNeutralDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
        let data = try await ProcessCommand().run("/bin/sh", ["-c", "pwd; exit 1"], successCodes: [0, 1], currentDirectory: root)
        XCTAssertEqual(URL(fileURLWithPath: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
    }
    func testOtherNativeManagersUseScopedCommandsAndRecheckVersions() async throws {
        for source in [ToolSource.uv, .pipx, .cargo, .rustup] {
            let replies = OtherToolReplies(source: source)
            let result = try await ToolSourceService(runner: { try await replies.run($0) }).update(source, executable: URL(fileURLWithPath: "/fixture/manager"), expectedContext: nil)
            XCTAssertTrue(result.updates.isEmpty)
            let commands = await replies.commands
            let writes = commands.filter(\.updating).map(\.arguments)
            switch source {
            case .uv: XCTAssertEqual(writes, [["tool", "upgrade", "foo"]])
            case .pipx: XCTAssertEqual(writes, [["upgrade", "foo"]])
            case .cargo: XCTAssertEqual(writes, [["install-update", "foo"]])
            case .rustup: XCTAssertEqual(writes, [["update", "--no-self-update", "stable-aarch64-apple-darwin"]])
            default: XCTFail("Unexpected manager")
            }
        }
    }
    func testEmptyPnpmJsonArrayIsAValidGlobalInventory() async throws {
        let service = ToolSourceService { command in
            if command.arguments.first == "root" { return Data("/fixture/pnpm".utf8) }
            if command.arguments.first == "list" { return Data("[{}]".utf8) }
            if command.arguments.first == "outdated" { return Data("[]".utf8) }
            XCTFail("Empty global inventory must not install tools")
            return Data()
        }
        let result = try await service.update(.pnpm, executable: URL(fileURLWithPath: "/fixture/pnpm"), expectedContext: "/fixture/pnpm")
        XCTAssertTrue(result.installed.isEmpty); XCTAssertTrue(result.updates.isEmpty)
    }
}

private actor NpmToolReplies {
    var commands: [ToolCommand] = []
    let installWorks: Bool
    var installed = false
    init(installWorks: Bool = true) { self.installWorks = installWorks }
    func run(_ command: ToolCommand) throws -> Data {
        commands.append(command)
        let result: String
        switch command.arguments.first {
        case "prefix": result = "/fixture/global\n"
        case "list": result = #"{"dependencies":{"@scope/tool":{"version":"VERSION"}}}"#.replacingOccurrences(of: "VERSION", with: installed ? "2.0.0" : "1.0.0")
        case "outdated": result = installed ? "{}" : #"{"@scope/tool":{"current":"1.0.0","latest":"2.0.0","wanted":"2.0.0"}}"#
        case "install": installed = installWorks; result = "updated"
        default: throw PeerError.invalid("Unexpected command")
        }
        return Data(result.utf8)
    }
}
private actor BrewToolReplies {
    var commands: [ToolCommand] = []
    var upgraded = false
    func run(_ command: ToolCommand) throws -> Data {
        commands.append(command)
        if command.arguments.first == "list" { return Data((upgraded ? "tool 2.0\npinned 1.0" : "tool 1.0\npinned 1.0").utf8) }
        if command.arguments.first == "outdated" {
            return Data((upgraded ? #"{"formulae":[{"name":"pinned","current_version":"2.0","pinned":true}]}"# : #"{"formulae":[{"name":"tool","current_version":"2.0"},{"name":"pinned","current_version":"2.0","pinned":true}]}"#).utf8)
        }
        if command.arguments == ["upgrade", "--formula"] { upgraded = true }
        return Data()
    }
}

private actor OtherToolReplies {
    let source: ToolSource
    var updated = false
    var commands: [ToolCommand] = []
    init(source: ToolSource) { self.source = source }
    func run(_ command: ToolCommand) throws -> Data {
        commands.append(command)
        if command.updating { updated = true; return Data() }
        let version = updated ? "2.0.0" : "1.0.0"
        let output: String
        switch source {
        case .uv: output = "foo v" + version + (updated ? "" : " [latest: 2.0.0]") + "\n- foo"
        case .pipx:
            if command.arguments.contains("--help") { output = "--skip-maintenance" }
            else if command.arguments.first == "list" { output = #"{"venvs":{"foo":{"metadata":{"main_package":{"package":"foo","package_version":"VERSION","pinned":false}}}}}"#.replacingOccurrences(of: "VERSION", with: version) }
            else { output = updated ? "[]" : #"[{"name":"foo","version":"1.0.0","latest_version":"2.0.0"}]"# }
        case .cargo: output = "Package Installed Latest Needs update\nfoo v" + version + " v2.0.0 " + (updated ? "No" : "Yes")
        case .rustup: output = "stable-aarch64-apple-darwin - " + (updated ? "up to date : 2.0.0" : "update available: 1.0.0 (hash date) -> 2.0.0 (hash date)")
        default: throw PeerError.invalid("Unexpected manager")
        }
        return Data(output.utf8)
    }
}
