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
        // Apple's desktopSoftware metadata can include a Watch remote companion (Keynote).
        // A Mac must still be explicit; mixed iPhone/iPad releases remain unconfirmed because
        // their public version/system requirements can belong to the mobile product.
        let devices = supportedDevices ?? []
        let macWithWatchCompanion = devices.contains("MacDesktop-MacDesktop") && devices.allSatisfy {
            $0 == "MacDesktop-MacDesktop" || $0.range(of: #"^Watch[0-9]+(?:,[0-9]+)?-Watch[0-9]+(?:,[0-9]+)?$"#, options: .regularExpression) != nil
        }
        guard adamID == storeID, bundleID == app.bundleID, version.count <= 128,
              kind == "mac-software" || (kind == "software" && macWithWatchCompanion),
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
        var outdated: [StoreApplication] = []
        var outdatedErrors: [UInt64: any Error] = [:]
    }
    private struct Detection: Sendable {
        let id: UInt64
        let entries: [StoreApplication]
        let error: (any Error)?
    }
    private struct ProductIdentity: Decodable { let adamID: UInt64 }
    private let execute: @Sendable ([String]) async throws -> Data
    private let available: Bool
    private var snapshot = Snapshot(entries: [])
    private var loadedAt: Date?
    private var failedAt: Date?
    private var pending: (UUID, Task<Snapshot, any Error>)?
    public init() {
        let bridge = Bundle.main.url(forAuxiliaryExecutable: "UpoviStoreBridge")
        available = bridge != nil
        execute = { args in
            guard let bridge else { throw PeerError.unavailable("App Store update bridge is unavailable") }
            return try await Self.command(bridge, arguments: args)
        }
    }
    public init(execute: @escaping @Sendable ([String]) async throws -> Data) {
        self.execute = execute; available = true
    }
    public init(bridge: URL) {
        available = true
        execute = { try await Self.command(bridge, arguments: $0) }
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
        let operation = UpoviLogOperation("store.check", category: .sources, details: UpoviDiagnosticContext.application(app))
        return await UpoviDiagnosticContext.$operationID.withValue(operation.id) {
            let result = await evaluate(app)
            let cancelled = result.checks.contains { $0.issue?.kind == .cancelled }
            operation.finish(cancelled ? "cancelled" : result.status.rawValue, details: UpoviDiagnosticContext.sourceResult(result),
                             level: result.status == .failed && !cancelled ? .warning : .info)
            return result
        }
    }
    private func evaluate(_ app: InstalledApp) async -> SourceResult {
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
            guard entry.version == app.version else { throw PeerError.invalid("Store inventory changed; check sources again") }
            guard let target = entry.newVersion else {
                if let error = loaded.lookupError { throw error }
                if let hint = ManualUpdateSource.forStoreBundle(app.bundleID, storeID: entry.adamID) {
                    return .init(appID: app.id, candidates: [], note: hint.note, status: .unsupported, manualURL: hint.url, checks: [.init(.appStore, .manual)])
                }
                return .init(appID: app.id, candidates: [], note: String(localized: "未查到与此安装完全匹配且兼容的商店版本，可能受商店地区、下架或系统要求影响。请在 App Store 中确认；其他应用的检测结果不受影响。"), status: .failed,
                             checks: [.init(.appStore, .failed, error: PeerError.unavailable("No exact compatible Store release was confirmed"))])
            }
            let newer = VersionOrder.isNewer(version: target, than: app)
            if newer, let error = loaded.outdatedErrors[entry.adamID] { throw error }
            let offers = loaded.outdated.filter { $0.adamID == entry.adamID }
            guard offers.count <= 1 else { throw PeerError.invalid("Ambiguous mas update metadata") }
            if let offer = offers.first {
                guard offer.matches(app), offer.version == entry.version, let version = offer.newVersion,
                      newer, VersionOrder.compare(version, target) == .orderedSame else {
                    throw PeerError.invalid("mas update metadata does not match the installed application and compatible Store product")
                }
            } else if newer {
                return .init(appID: app.id, candidates: [], note: String(localized: "商店目录与更新检测结果尚未一致，请在 App Store 中确认后重新检查。"),
                             status: .appStore, manualURL: URL(string: "https://apps.apple.com/app/id\(entry.adamID)"),
                             checks: [.init(.appStore, .manual)], appStoreID: entry.adamID)
            }
            let url = "https://apps.apple.com/app/id\(entry.adamID)"
            let candidates: [UpdateCandidate] = newer ? [.init(version: target, source: "App Store", isCommunity: false,
                url: URL(string: url), appStoreID: entry.adamID)] : []
            let note = String(localized: "已通过商店更新工具检查公开版本，信息可能存在同步延迟。安装时由 Apple 确认可用更新，可能要求账户或管理员认证。")
            return .init(appID: app.id, candidates: candidates, note: note, status: newer ? .updates : .current, checks: [.init(.appStore, .checked)], appStoreID: entry.adamID)
        } catch {
            return .init(appID: app.id, candidates: [], note: String(localized: "商店检测未完成，无法读取本机商店清单或查询服务暂不可用。请稍后重试；不会将检测失败视为已经最新。"), status: .failed, checks: [.init(.appStore, .failed, error: error)])
        }
    }
    private func load() async throws -> Snapshot {
        try Task.checkCancellation()
        if let failedAt, Date().timeIntervalSince(failedAt) < 60 { throw PeerError.unavailable("Store metadata is temporarily unavailable") }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < (snapshot.lookupError == nil && snapshot.outdatedErrors.isEmpty ? 300 : 60) { return snapshot }
        let request: (UUID, Task<Snapshot, any Error>)
        if let pending { request = pending }
        else {
            let execute = execute
            request = (UUID(), Task {
                let installed = try Self.decode(await execute(["list"]))
                UpoviLog.sources.info("event=store.inventoryLoaded entries=\(installed.count)")
                guard installed.contains(where: { $0.adamID > 0 }) else { return Snapshot(entries: installed) }
                let products: Data
                do {
                    products = try await execute(["lookup"] + Array(Set(installed.filter { $0.adamID > 0 }.map { String($0.adamID) })).sorted())
                } catch {
                    if error is CancellationError { throw error }
                    try Task.checkCancellation()
                    UpoviLog.sources.warning("event=store.lookupFailed \(UpoviDiagnosticContext.errorSummary(error))")
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
                let entries = installed.map { item in
                    let match = releases.filter { $0.adamID == item.adamID && $0.bundleID == item.bundleID }
                    let probe = InstalledApp(name: "", bundleID: item.bundleID, version: item.version, path: item.path, isAppStore: true)
                    let compatible = identities[item.adamID] == 1 && match.count == 1 && (try? match[0].validate(for: probe, storeID: item.adamID)) != nil
                    return StoreApplication(adamID: item.adamID, bundleID: item.bundleID, path: item.path, version: item.version,
                                            newVersion: compatible ? match[0].version : nil)
                }
                // Exact compatible catalog results already establish when no newer public version
                // exists. Only newer versions need mas's independent, read-only offer confirmation.
                // Isolate each ID: one failed TLS/request must not invalidate unrelated apps.
                // Accurate mode starts/cancels downloads and must never run during a scan.
                let ids = Array(Set(entries.filter { item in
                    item.newVersion.map { VersionOrder.compare($0, item.version) == .orderedDescending } == true
                }.map(\.adamID))).sorted()
                UpoviLog.sources.info("event=store.catalogLoaded entries=\(entries.count) products=\(releases.count) confirmations=\(ids.count)")
                var outdated: [StoreApplication] = [], errors: [UInt64: any Error] = [:]
                await withTaskGroup(of: Detection.self) { group in
                    func enqueue(_ id: UInt64) {
                        group.addTask {
                            let operation = UpoviLogOperation("store.confirmation", category: .sources,
                                details: "app=\(UpoviDiagnosticContext.applicationID(entries.first { $0.adamID == id }?.path ?? "unknown"))")
                            return await UpoviDiagnosticContext.$operationID.withValue(operation.id) {
                                do {
                                    let offers = try Self.decode(await execute(["outdated", "--inaccurate", "--check-min-os", String(id)]))
                                    guard offers.allSatisfy({ $0.adamID == id }) else { throw PeerError.invalid("Unexpected Store offer identity") }
                                    operation.finish(details: "offers=\(offers.count)")
                                    return Detection(id: id, entries: offers, error: nil)
                                } catch {
                                    operation.fail(error)
                                    return Detection(id: id, entries: [], error: error)
                                }
                            }
                        }
                    }
                    var remaining = ids.makeIterator()
                    for _ in 0..<4 { if let id = remaining.next() { enqueue(id) } }
                    for await detection in group {
                        if let error = detection.error { errors[detection.id] = error }
                        else { outdated += detection.entries }
                        if let id = remaining.next() { enqueue(id) }
                    }
                }
                if errors.values.contains(where: { UpoviDiagnosticContext.isCancellation($0) }) { throw CancellationError() }
                UpoviLog.sources.info("event=store.confirmationsCompleted requested=\(ids.count) offers=\(outdated.count) failures=\(errors.count)")
                return Snapshot(entries: entries, outdated: outdated, outdatedErrors: errors)
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
