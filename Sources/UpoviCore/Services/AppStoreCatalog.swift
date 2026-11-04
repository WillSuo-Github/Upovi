import Foundation

public struct StoreApplication: Codable, Sendable {
    public let adamID: UInt64
    public let bundleID: String
    public let path: String
    public let version: String
    public let newVersion: String?
    public let storeRegion: String?
    public init(adamID: UInt64, bundleID: String, path: String, version: String, newVersion: String? = nil, storeRegion: String? = nil) {
        self.adamID = adamID; self.bundleID = bundleID; self.path = path; self.version = version; self.newVersion = newVersion; self.storeRegion = storeRegion
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
    private struct Snapshot: Sendable {
        let entries: [StoreApplication]
        var lookupError: (any Error)? = nil
        var regionalErrors: [UInt64: any Error] = [:]
        var availability: StoreUpdateAvailability? = nil
    }
    private struct ProductIdentity: Decodable { let adamID: UInt64 }
    private let execute: @Sendable ([String]) async throws -> Data
    private let regionalLookup: (@Sendable ([UInt64], String) async throws -> [StoreProduct])?
    private let nativeAvailability: (@Sendable () async throws -> StoreUpdateAvailability)?
    private let available: Bool
    private var snapshot = Snapshot(entries: [])
    private var loadedAt: Date?
    private var failedAt: Date?
    private var pending: (UUID, Task<Snapshot, any Error>)?
    public init() {
        let bridge = Bundle.main.url(forAuxiliaryExecutable: "UpoviStoreBridge")
        available = bridge != nil
        regionalLookup = { try await Self.lookup($0, region: $1) }
        let helper = Bundle.main.url(forAuxiliaryExecutable: "UpoviStoreInstaller")
        nativeAvailability = {
            guard let helper else { throw PeerError.unavailable("Native Store status helper is unavailable") }
            return try await StoreUpdateAvailability.query(using: helper)
        }
        execute = { args in
            guard let bridge else { throw PeerError.unavailable("App Store update bridge is unavailable") }
            return try await Self.command(bridge, arguments: args)
        }
    }
    public init(execute: @escaping @Sendable ([String]) async throws -> Data,
                regionalLookup: (@Sendable ([UInt64], String) async throws -> [StoreProduct])? = nil,
                nativeAvailability: (@Sendable () async throws -> StoreUpdateAvailability)? = nil) {
        self.execute = execute; self.regionalLookup = regionalLookup; self.nativeAvailability = nativeAvailability; available = true
    }
    public init(bridge: URL) {
        available = true
        execute = { try await Self.command(bridge, arguments: $0) }
        regionalLookup = { try await Self.lookup($0, region: $1) }
        let helper = bridge.deletingLastPathComponent().appending(path: "UpoviStoreInstaller")
        nativeAvailability = { try await StoreUpdateAvailability.query(using: helper) }
    }
    static func lookup(_ ids: [UInt64], region: String) async throws -> [StoreProduct] {
        guard !ids.isEmpty, ids.count <= 50, ids.allSatisfy({ $0 > 0 && $0 < UInt64(Int64.max) }),
              region.range(of: #"^[A-Z]{2}$"#, options: .regularExpression) != nil else { throw PeerError.invalid("Invalid Store lookup") }
        var url = URLComponents(string: "https://itunes.apple.com/lookup")!
        // The same Store ID/bundle can have different mobile and native Mac versions.
        // Never fall back to an unfiltered mobile lookup, even if it says it can run on a Mac.
        url.queryItems = [.init(name: "id", value: ids.map(String.init).joined(separator: ",")), .init(name: "country", value: region),
                          .init(name: "entity", value: "desktopSoftware"), .init(name: "media", value: "software")]
        return try decodeLookup(await UpdateChecker.fetch(url.url!, limit: 2_000_000))
    }
    static func decodeLookup(_ data: Data) throws -> [StoreProduct] {
        guard data.count <= 2_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = object["resultCount"] as? Int, let rows = object["results"] as? [[String: Any]],
              count == rows.count, count <= 50 else { throw PeerError.invalid("Invalid Store lookup response") }
        return rows.map { row in
            let devices = row["supportedDevices"] as? [String]
            let kind = row["kind"] as? String
            let native = kind == "mac-software" || devices == ["MacDesktop-MacDesktop"]
            return StoreProduct(adamID: row["trackId"] as? UInt64 ?? 0, bundleID: row["bundleId"] as? String ?? "",
                version: row["version"] as? String ?? "", minimumOSVersion: row["minimumOsVersion"] as? String ?? "",
                kind: native ? kind : nil, supportedDevices: native ? devices : nil)
        }
    }
    public static func command(_ bridge: URL, arguments: [String], timeout: TimeInterval = 60,
                               environment: [String: String]? = nil) async throws -> Data {
        var env = environment ?? ProcessInfo.processInfo.environment
        env["MAS_NO_AUTO_INDEX"] = "1"
        // Pinned mas 7 emits valid JSON rows and exits with the number of failed lookups.
        // Only read-only numeric-ID lookups accept this partial-result convention. Each row
        // still needs exact identity/platform validation; list and installation remain strict.
        let ids = arguments.dropFirst()
        let partialLookup = arguments.first == "lookup" && !ids.isEmpty && ids.count <= 2000 &&
            ids.allSatisfy { UInt64($0).map { $0 > 0 && $0 < UInt64(Int64.max) } == true }
        let codes: Set<Int32> = partialLookup ? Set((0...min(ids.count, 255)).map(Int32.init)) : [0]
        return try await ProcessCommand().run(bridge.path, arguments, timeoutSeconds: timeout, environment: env, maximumOutputBytes: 2_000_000, successCodes: codes)
    }
    public static func decode(_ data: Data) throws -> [StoreApplication] {
        guard data.count <= 2_000_000, String(data: data, encoding: .utf8) != nil else { throw PeerError.invalid("Invalid App Store metadata") }
        let rows = try data.split(separator: 0x0A).filter { !$0.isEmpty }.map { try JSONDecoder().decode(StoreApplication.self, from: Data($0)) }
        guard rows.count <= 2000, rows.allSatisfy({ $0.adamID < UInt64(Int64.max) && !$0.bundleID.isEmpty && $0.bundleID.count <= 255 && $0.path.utf8.count <= 4096 && $0.path.hasPrefix("/") && !$0.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && $0.version.count <= 128 && ($0.newVersion?.count ?? 0) <= 128 }) else {
            throw PeerError.invalid("Unsafe App Store metadata")
        }
        return rows
    }
    public func invalidate() { loadedAt = nil; failedAt = nil; pending = nil }
    public func check(_ app: InstalledApp) async -> SourceResult {
        guard available else { return .init(appID: app.id, candidates: [], note: String(localized: "请使用包含商店更新组件的完整 Upovi 应用包。"), status: .appStore, checks: [.init(.appStore, .manual)]) }
        do {
            let loaded = try await load()
            let entries = loaded.entries
            let matches = entries.filter { $0.matches(app) }
            guard matches.count == 1, let entry = matches.first,
                  (entry.adamID == 0 || entries.filter({ $0.adamID == entry.adamID }).count == 1) else { throw PeerError.invalid("App Store identity is missing or ambiguous") }
            if entry.adamID == 0 {
                return .init(appID: app.id, candidates: [], note: String(localized: "此安装没有可确认的商店标识，可能来自 TestFlight。请使用原分发渠道更新；不会自动替换。"), status: .appStore, checks: [.init(.appStore, .manual)])
            }
            guard let target = entry.newVersion else {
                if let error = loaded.lookupError { throw error }
                if let error = loaded.regionalErrors[entry.adamID] { throw error }
                if let hint = ManualUpdateSource.forStoreBundle(app.bundleID, storeID: entry.adamID) {
                    return .init(appID: app.id, candidates: [], note: hint.note, status: .unsupported, manualURL: hint.url, checks: [.init(.appStore, .manual)])
                }
                return .init(appID: app.id, candidates: [], note: String(localized: "未查到与此安装完全匹配且兼容的商店版本，可能受商店地区、下架或系统要求影响。请在 App Store 中确认；其他应用的检测结果不受影响。"), status: .failed,
                             checks: [.init(.appStore, .failed, error: PeerError.unavailable("No exact compatible Store release was confirmed"))])
            }
            let newer = VersionOrder.isNewer(version: target, than: app)
            if newer, nativeAvailability != nil, loaded.availability?.confirms(app, storeID: entry.adamID, version: target) != true {
                return .init(appID: app.id, candidates: [], note: String(localized: "公开商店版本为 \(target)，但本机商店尚未确认向此安装提供该更新。请使用原下载账户在 App Store 中确认；此版本暂不计入可用更新。"),
                             status: .appStore, manualURL: URL(string: "https://apps.apple.com/app/id\(entry.adamID)"), checks: [.init(.appStore, .manual)],
                             appStoreID: entry.storeRegion == nil ? entry.adamID : nil)
            }
            let storeID: UInt64? = entry.storeRegion == nil ? entry.adamID : nil
            let url = entry.storeRegion.map { "https://apps.apple.com/\($0.lowercased())/app/id\(entry.adamID)" } ?? "https://apps.apple.com/app/id\(entry.adamID)"
            let candidates: [UpdateCandidate] = newer ? [.init(version: target, source: "App Store", isCommunity: false,
                url: URL(string: url), appStoreID: storeID)] : []
            let note = entry.storeRegion.map { String(localized: "已核对 \($0) 地区的 Mac App Store 公开版本。如需更新，请使用原下载账户所在地区的 App Store；公开信息可能存在同步延迟。") }
                ?? String(localized: "已检查公开商店版本，信息可能存在同步延迟。可在 Upovi 中发起更新，可能要求 Apple 账户或管理员认证。")
            return .init(appID: app.id, candidates: candidates, note: note, status: newer ? .updates : .current, checks: [.init(.appStore, .checked)], appStoreID: storeID)
        } catch {
            return .init(appID: app.id, candidates: [], note: String(localized: "商店检测未完成，无法读取本机商店清单或查询服务暂不可用。请稍后重试；不会将检测失败视为已经最新。"), status: .failed, checks: [.init(.appStore, .failed, error: error)])
        }
    }
    private func load() async throws -> Snapshot {
        try Task.checkCancellation()
        if let failedAt, Date().timeIntervalSince(failedAt) < 60 { throw PeerError.unavailable("Store metadata is temporarily unavailable") }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < (snapshot.lookupError == nil ? 300 : 60) { return snapshot }
        let request: (UUID, Task<Snapshot, any Error>)
        if let pending { request = pending }
        else {
            let execute = execute, regionalLookup = regionalLookup, nativeAvailability = nativeAvailability
            request = (UUID(), Task {
                let installed = try Self.decode(await execute(["list"]))
                guard installed.contains(where: { $0.adamID > 0 }) else { return Snapshot(entries: installed) }
                let products: Data
                do {
                    products = try await execute(["lookup"] + Array(Set(installed.filter { $0.adamID > 0 }.map { String($0.adamID) })).sorted())
                } catch {
                    if error is CancellationError { throw error }
                    try Task.checkCancellation()
                    // Keep known manual/TestFlight installations independent of catalog outages.
                    return Snapshot(entries: installed, lookupError: error)
                }
                guard String(data: products, encoding: .utf8) != nil, products.count <= 2_000_000 else { throw PeerError.invalid("Invalid Store catalog") }
                var identities: [UInt64: Int] = [:], releases: [StoreProduct] = []
                for row in products.split(separator: 0x0A) where !row.isEmpty {
                    // A malformed product cannot erase unrelated valid products. Count identities
                    // before decoding the rest so a malformed duplicate cannot hide ambiguity.
                    guard let identity = try? JSONDecoder().decode(ProductIdentity.self, from: Data(row)) else { continue }
                    identities[identity.adamID, default: 0] += 1
                    if let product = try? JSONDecoder().decode(StoreProduct.self, from: Data(row)) { releases.append(product) }
                }
                var recoveredRegions: [UInt64: String] = [:], regionalErrors: [UInt64: any Error] = [:]
                if let regionalLookup {
                    let missing = installed.filter { $0.adamID > 0 && identities[$0.adamID] == nil &&
                        ApplicationSourceCatalog.appStoreRegionHints[$0.bundleID] != nil }
                    let regions = Array(Set(missing.flatMap { ApplicationSourceCatalog.appStoreRegionHints[$0.bundleID] ?? [] })).sorted()
                    var pending = Set(missing.map(\.adamID))
                    for storefront in regions {
                        let ids = Array(Set(missing.filter { pending.contains($0.adamID) &&
                            ApplicationSourceCatalog.appStoreRegionHints[$0.bundleID]?.contains(storefront) == true }.map(\.adamID))).sorted()
                        for start in stride(from: 0, to: ids.count, by: 50) {
                            try Task.checkCancellation()
                            let batch = Array(ids[start..<min(start + 50, ids.count)])
                            do {
                                let products = try await regionalLookup(batch, storefront)
                                for id in batch {
                                    let matches = products.filter { $0.adamID == id }
                                    guard !matches.isEmpty else { continue }
                                    let installs = installed.filter { $0.adamID == id }
                                    guard matches.count == 1, installs.count == 1, let item = installs.first,
                                          (try? matches[0].validate(for: .init(name: "", bundleID: item.bundleID, version: item.version, path: item.path, isAppStore: true), storeID: id)) != nil else {
                                        continue
                                    }
                                    releases.append(matches[0]); identities[id] = 1; recoveredRegions[id] = storefront; pending.remove(id)
                                }
                            } catch {
                                if error is CancellationError { throw error }; try Task.checkCancellation()
                                for id in batch { regionalErrors[id] = error }
                            }
                        }
                    }
                }
                let entries = installed.map { item in
                    let match = releases.filter { $0.adamID == item.adamID && $0.bundleID == item.bundleID }
                    let probe = InstalledApp(name: "", bundleID: item.bundleID, version: item.version, path: item.path, isAppStore: true)
                    let compatible = identities[item.adamID] == 1 && match.count == 1 && (try? match[0].validate(for: probe, storeID: item.adamID)) != nil
                    return StoreApplication(adamID: item.adamID, bundleID: item.bundleID, path: item.path, version: item.version,
                                            newVersion: compatible ? match[0].version : nil, storeRegion: recoveredRegions[item.adamID])
                }
                let availability = try? await nativeAvailability?()
                return Snapshot(entries: entries, regionalErrors: regionalErrors, availability: availability)
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
