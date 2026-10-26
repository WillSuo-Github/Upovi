import Foundation

public struct StoreApplication: Codable, Sendable {
    public let adamID: UInt64
    public let bundleID: String
    public let path: String
    public let version: String
    public let newVersion: String?
    public init(adamID: UInt64, bundleID: String, path: String, version: String, newVersion: String? = nil) {
        self.adamID = adamID; self.bundleID = bundleID; self.path = path; self.version = version; self.newVersion = newVersion
    }
    public func matches(_ app: InstalledApp) -> Bool {
        guard bundleID == app.bundleID else { return false }
        if path == app.path { return true }
        let fm = FileManager.default
        guard let a = try? fm.attributesOfItem(atPath: path), let b = try? fm.attributesOfItem(atPath: app.path),
              let ad = a[.systemNumber] as? NSNumber, let bd = b[.systemNumber] as? NSNumber,
              let ai = a[.systemFileNumber] as? NSNumber, let bi = b[.systemFileNumber] as? NSNumber else { return false }
        return ad == bd && ai == bi
    }
}

public struct StoreProduct: Decodable, Sendable {
    public let adamID: UInt64
    public let bundleID: String
    public let version: String
    public let minimumOSVersion: String
    public let kind: String?
    public let supportedDevices: [String]?
    public func validate(for app: InstalledApp, storeID: UInt64) throws {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard adamID == storeID, bundleID == app.bundleID, version.count <= 128,
              kind == "mac-software" || supportedDevices?.contains("MacDesktop-MacDesktop") == true,
              SourceVersion.comparable(version, installed: app.version),
              minimumOSVersion.count <= 64, minimumOSVersion.range(of: #"^\d+(?:\.\d+)*$"#, options: .regularExpression) != nil,
              VersionOrder.compare(minimumOSVersion, "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") != .orderedDescending else {
            throw PeerError.invalid("The Store product is not an exact compatible Mac application")
        }
    }
}

public actor AppStoreCatalog {
    public static let shared = AppStoreCatalog()
    private let execute: @Sendable ([String]) async throws -> Data
    private let available: Bool
    private var snapshot: [StoreApplication] = []
    private var loadedAt: Date?
    private var failedAt: Date?
    private var pending: (UUID, Task<[StoreApplication], any Error>)?
    public init() {
        let bridge = Bundle.main.url(forAuxiliaryExecutable: "UpoviStoreBridge")
        available = bridge != nil
        execute = { args in
            guard let bridge else { throw PeerError.unavailable("App Store update bridge is unavailable") }
            return try await Self.command(bridge, arguments: args)
        }
    }
    public init(execute: @escaping @Sendable ([String]) async throws -> Data) { self.execute = execute; available = true }
    public static func command(_ bridge: URL, arguments: [String], timeout: TimeInterval = 60,
                               environment: [String: String]? = nil) async throws -> Data {
        var env = environment ?? ProcessInfo.processInfo.environment
        env["MAS_NO_AUTO_INDEX"] = "1"
        return try await ProcessCommand().run(bridge.path, arguments, timeoutSeconds: timeout, environment: env, maximumOutputBytes: 2_000_000)
    }
    public static func decode(_ data: Data) throws -> [StoreApplication] {
        guard data.count <= 2_000_000, String(data: data, encoding: .utf8) != nil else { throw PeerError.invalid("Invalid App Store metadata") }
        let rows = try data.split(separator: 0x0A).filter { !$0.isEmpty }.map { try JSONDecoder().decode(StoreApplication.self, from: Data($0)) }
        guard rows.count <= 2000, rows.allSatisfy({ $0.adamID < UInt64(Int64.max) && !$0.bundleID.isEmpty && $0.bundleID.count <= 255 && $0.path.utf8.count <= 4096 && $0.path.hasPrefix("/") && !$0.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && $0.version.count <= 128 && ($0.newVersion?.count ?? 0) <= 128 }) else {
            throw PeerError.invalid("Unsafe App Store metadata")
        }
        return rows
    }
    public func invalidate() { loadedAt = nil; pending = nil }
    public func check(_ app: InstalledApp) async -> SourceResult {
        guard available else { return .init(appID: app.id, candidates: [], note: "请使用包含商店更新组件的完整 Upovi 应用包。", status: .appStore, checks: [.init(.appStore, .manual)]) }
        do {
            let entries = try await load()
            let matches = entries.filter { $0.matches(app) }
            guard matches.count == 1, let entry = matches.first,
                  (entry.adamID == 0 || entries.filter({ $0.adamID == entry.adamID }).count == 1) else { throw PeerError.invalid("App Store identity is missing or ambiguous") }
            if entry.adamID == 0 {
                return .init(appID: app.id, candidates: [], note: "此安装没有可确认的商店标识，可能来自 TestFlight。请使用原分发渠道更新；不会自动替换。", status: .appStore, checks: [.init(.appStore, .manual)])
            }
            guard let target = entry.newVersion else { throw PeerError.unavailable("No exact compatible Store release was confirmed") }
            let newer = VersionOrder.isNewer(version: target, than: app)
            let candidates: [UpdateCandidate] = newer ? [.init(version: target, source: "App Store", isCommunity: false,
                url: URL(string: "https://apps.apple.com/app/id\(entry.adamID)"), appStoreID: entry.adamID)] : []
            return .init(appID: app.id, candidates: candidates, note: "已检查公开商店版本，信息可能存在同步延迟。可在 Upovi 中发起更新，可能要求 Apple 账户或管理员认证。", status: newer ? .updates : .current, checks: [.init(.appStore, .checked)], appStoreID: entry.adamID)
        } catch {
            return .init(appID: app.id, candidates: [], note: "商店更新检测未完成。请确认系统支持商店更新组件，且应用已被 Spotlight 索引；不会将检测失败视为已经最新。", status: .failed, checks: [.init(.appStore, .failed, error: error)])
        }
    }
    private func load() async throws -> [StoreApplication] {
        try Task.checkCancellation()
        if let failedAt, Date().timeIntervalSince(failedAt) < 60 { throw PeerError.unavailable("Store metadata is temporarily unavailable") }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 300 { return snapshot }
        let request: (UUID, Task<[StoreApplication], any Error>)
        if let pending { request = pending }
        else {
            let execute = execute
            request = (UUID(), Task {
                let installed = try Self.decode(await execute(["list"]))
                guard installed.contains(where: { $0.adamID > 0 }) else { return installed }
                let products = try await execute(["lookup"] + Array(Set(installed.filter { $0.adamID > 0 }.map { String($0.adamID) })).sorted())
                guard String(data: products, encoding: .utf8) != nil, products.count <= 2_000_000 else { throw PeerError.invalid("Invalid Store catalog") }
                let releases = try products.split(separator: 0x0A).filter { !$0.isEmpty }.map { try JSONDecoder().decode(StoreProduct.self, from: Data($0)) }
                return installed.map { item in
                    let match = releases.filter { $0.adamID == item.adamID && $0.bundleID == item.bundleID }
                    let probe = InstalledApp(name: "", bundleID: item.bundleID, version: item.version, path: item.path, isAppStore: true)
                    let compatible = match.count == 1 && (try? match[0].validate(for: probe, storeID: item.adamID)) != nil
                    return StoreApplication(adamID: item.adamID, bundleID: item.bundleID, path: item.path, version: item.version,
                                            newVersion: compatible ? match[0].version : nil)
                }
            })
            pending = request
        }
        do {
            let value = try await request.1.value; try Task.checkCancellation()
            guard pending?.0 == request.0 else { return try await load() }
            snapshot = value; loadedAt = Date(); failedAt = nil; pending = nil; return value
        } catch { if pending?.0 == request.0 { pending = nil; failedAt = error is CancellationError ? nil : Date() }; throw error }
    }
}
