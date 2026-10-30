import Foundation

public enum ToolSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case homebrew, npm, pnpm, uv, pipx, cargo, rustup
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .homebrew: "Homebrew"
        case .npm: "npm"
        case .pnpm: "pnpm"
        case .uv: "uv tools"
        case .pipx: "pipx"
        case .cargo: "Cargo"
        case .rustup: String(localized: "Rust 工具链")
        }
    }
    public var executableName: String { self == .homebrew ? "brew" : rawValue }
}

public struct ToolPackage: Codable, Hashable, Sendable {
    public let name: String
    public let installed: String
    public let available: String
    public init(name: String, installed: String, available: String) {
        self.name = name; self.installed = installed; self.available = available
    }
}

public struct ToolSnapshot: Codable, Sendable {
    public let source: ToolSource
    public let date: Date
    public let context: String
    public let installed: [String: String]
    public let updates: [ToolPackage]
    public let held: [String]
    public init(source: ToolSource, context: String = "", installed: [String: String], updates: [ToolPackage], held: [String] = []) {
        self.source = source; date = Date(); self.context = context; self.installed = installed; self.updates = updates; self.held = held
    }
}

public struct ToolUpdateRecord: Codable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case running, succeeded, failed, interrupted }
    public let id: UUID
    public let source: ToolSource
    public let startedAt: Date
    public var finishedAt: Date?
    public var state: State
    public var detail: String
    public init(source: ToolSource) {
        id = UUID(); self.source = source; startedAt = Date(); state = .running; detail = ""
    }
}

public enum ToolSourceDiscovery {
    public static func locations(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> [ToolSource: URL] {
        let defaults = ["/opt/homebrew/bin", "/usr/local/bin", home.appending(path: ".local/bin").path,
                        home.appending(path: ".cargo/bin").path, home.appending(path: ".volta/bin").path,
                        home.appending(path: "Library/pnpm").path, home.appending(path: ".local/share/pnpm").path,
                        "/opt/homebrew/opt/rustup/bin"]
        let paths = path.split(separator: ":").map(String.init).filter {
            $0.hasPrefix("/") && !$0.contains("/codex-runtimes/") && !$0.contains("/.codex/")
        } + defaults
        func find(_ name: String) -> URL? {
            paths.map { URL(fileURLWithPath: $0).appending(path: name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        return Dictionary(uniqueKeysWithValues: ToolSource.allCases.compactMap { source in
            guard let executable = find(source.executableName), source != .cargo || find("cargo-install-update") != nil else { return nil }
            return (source, executable)
        })
    }
}
