import Foundation
import Darwin
import ObjectiveC.runtime

/// Positive evidence from the current user's Store cache. An absent entry is never proof that
/// an app is current: the cache may be empty, stale, signed out, or not initialized yet.
public struct StoreUpdateAvailability: Codable, Sendable {
    public enum RefreshFailure: String, Codable, Error, Sendable { case notEntitled, unavailable, failed }
    public struct FailureMessage: Codable, Sendable {
        public let refreshFailure: RefreshFailure
        public init(_ failure: RefreshFailure) { refreshFailure = failure }
    }
    public struct Offer: Codable, Sendable {
        public let storeID: UInt64
        public let bundleID: String
        public let version: String
        public init(storeID: UInt64, bundleID: String, version: String) {
            self.storeID = storeID; self.bundleID = bundleID; self.version = version
        }
    }
    public let offers: [Offer]
    public let refreshedAt: Date?
    public init(offers: [Offer], refreshedAt: Date? = nil) { self.offers = offers; self.refreshedAt = refreshedAt }
    public func confirms(_ app: InstalledApp, storeID: UInt64, version: String) -> Bool {
        let matches = offers.filter { $0.storeID == storeID }
        return matches.count == 1 && matches[0].bundleID == app.bundleID &&
            VersionOrder.compare(matches[0].version, version) == .orderedSame
    }
    public static func query(using helper: URL, refresh: Bool = true) async throws -> Self {
        let data = try await ProcessCommand().run(helper.path, [refresh ? "--refresh-updates" : "--cached-updates"], timeoutSeconds: refresh ? 55 : 5, maximumOutputBytes: 1_000_000)
        if let failure = try? JSONDecoder().decode(FailureMessage.self, from: data) { throw failure.refreshFailure }
        let value = try JSONDecoder().decode(Self.self, from: data)
        if refresh {
            guard let date = value.refreshedAt, Date().timeIntervalSince(date) >= -5, Date().timeIntervalSince(date) <= 120 else {
                throw RefreshFailure.failed
            }
        }
        guard value.offers.count <= 2000, value.offers.allSatisfy({ $0.storeID > 0 && $0.storeID < UInt64(Int64.max) &&
            !$0.bundleID.isEmpty && $0.bundleID.count <= 255 && $0.version.count <= 128 }) else {
            throw PeerError.invalid("Invalid native Store update metadata")
        }
        return value
    }
    /// Read-only refresh in a disposable process. The callback ABI is the system's
    /// ASDUpdatesServiceProtocol reloadFromServerInBackgroundWithCompletionBlock: encoding:
    /// void (^)(NSArray *, NSError *). No install, purchase, cancel or authorization API is used.
    @MainActor public static func refreshInHelper() async throws -> Self {
        guard geteuid() != 0,
              dlopen("/System/Library/PrivateFrameworks/AppStoreDaemon.framework/AppStoreDaemon", RTLD_LAZY | RTLD_LOCAL) != nil,
              let type = NSClassFromString("ASDUpdatesService"),
              let shared = class_getClassMethod(type, NSSelectorFromString("defaultService")),
              Self.objectGetter(shared),
              let refresh = class_getInstanceMethod(type, NSSelectorFromString("reloadFromServerInBackgroundWithCompletionBlock:")),
              method_getNumberOfArguments(refresh) == 3,
              let encoding = method_getTypeEncoding(refresh), String(cString: encoding).hasPrefix("v"),
              argumentType(refresh, 2) == "@?", callbackMatchesSystemProtocol() else { throw RefreshFailure.unavailable }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        guard let service = unsafeBitCast(method_getImplementation(shared), to: Getter.self)(type as AnyObject, NSSelectorFromString("defaultService"))?.takeUnretainedValue() else { throw RefreshFailure.unavailable }
        typealias Callback = @convention(block) @Sendable (NSArray?, NSError?) -> Void
        typealias Refresh = @convention(c) (AnyObject, Selector, Callback) -> Void
        return try await withCheckedThrowingContinuation { continuation in
            let once = StoreRefreshCompletion(continuation)
            let callback: Callback = { values, error in
                if let error {
                    once.finish(.failure(error.domain == "ASDErrorDomain" && error.code == 505 ? RefreshFailure.notEntitled : RefreshFailure.failed))
                    return
                }
                guard let rows = values as? [NSObject], rows.count <= 2000 else { once.finish(.failure(RefreshFailure.failed)); return }
                var offers: [Offer] = []
                for row in rows {
                    guard let id = integer(row, "storeItemIdentifier"), id > 0,
                          let bundle = object(row, "bundleIdentifier") as? String, !bundle.isEmpty, bundle.count <= 255,
                          let dictionary = object(row, "updateDictionary") as? [String: Any] else { once.finish(.failure(RefreshFailure.failed)); return }
                    // Unknown version metadata remains unconfirmed. Never substitute an external
                    // version identifier or installed bundle version for a marketing version.
                    let versions = Set(["displayVersion", "CFBundleShortVersionString", "version"].compactMap { dictionary[$0] as? String }.filter { !$0.isEmpty })
                    let version = versions.count == 1 ? versions.first! : ""
                    guard version.count <= 128 else { once.finish(.failure(RefreshFailure.failed)); return }
                    if dictionary["isStaged"] as? Bool == true { continue }
                    offers.append(.init(storeID: UInt64(id), bundleID: bundle, version: version))
                }
                once.finish(.success(.init(offers: offers, refreshedAt: Date())))
            }
            unsafeBitCast(method_getImplementation(refresh), to: Refresh.self)(service, NSSelectorFromString("reloadFromServerInBackgroundWithCompletionBlock:"), callback)
            // The parent also terminates an unresponsive helper. This bounds a normal callback loss.
            DispatchQueue.global().asyncAfter(deadline: .now() + 45) { once.finish(.failure(RefreshFailure.failed)) }
        }
    }
    private static func callbackMatchesSystemProtocol() -> Bool {
        guard let proto = NSProtocolFromString("ASDUpdatesServiceProtocol"),
              let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_protocol_getMethodTypeEncoding") else { return false }
        typealias Encoding = @convention(c) (AnyObject, Selector, Bool, Bool) -> UnsafePointer<CChar>?
        let get = unsafeBitCast(address, to: Encoding.self)
        guard let value = get(proto as AnyObject, NSSelectorFromString("reloadFromServerInBackgroundWithCompletionBlock:"), true, true) else { return false }
        return String(cString: value).contains("@?<v@?@\"NSArray\"@\"NSError\">")
    }
    private static func objectGetter(_ method: Method) -> Bool {
        guard let encoding = method_getTypeEncoding(method) else { return false }
        return String(cString: encoding).hasPrefix("@") && method_getNumberOfArguments(method) == 2
    }
    private static func argumentType(_ method: Method, _ index: UInt32) -> String {
        guard let value = method_copyArgumentType(method, index) else { return "" }
        defer { free(value) }; return String(cString: value)
    }
    private static func integer(_ receiver: AnyObject, _ name: String) -> Int64? {
        guard let type = object_getClass(receiver), let method = class_getInstanceMethod(type, NSSelectorFromString(name)),
              let encoding = method_getTypeEncoding(method), String(cString: encoding).hasPrefix("q"), method_getNumberOfArguments(method) == 2 else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int64
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(receiver, NSSelectorFromString(name))
    }
    /// Called only in a disposable, unprivileged helper. The private system interface is optional;
    /// missing selectors, unavailable cache, helper crashes and timeouts all leave updates manual.
    /// No refresh, purchase, download, cancellation or installation selector is invoked here.
    public static func readCachedUpdatesInHelper() throws -> Self {
        guard geteuid() != 0,
              dlopen("/System/Library/PrivateFrameworks/CommerceKit.framework/CommerceKit", RTLD_LAZY | RTLD_LOCAL) != nil,
              let type = NSClassFromString("CKUpdateController"),
              let shared = class_getClassMethod(type, NSSelectorFromString("sharedUpdateController")),
              let encoding = method_getTypeEncoding(shared), String(cString: encoding).hasPrefix("@"), method_getNumberOfArguments(shared) == 2 else {
            throw PeerError.unavailable("Native Store update cache is unavailable")
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let getShared = unsafeBitCast(method_getImplementation(shared), to: Getter.self)
        guard let controller = getShared(type as AnyObject, NSSelectorFromString("sharedUpdateController"))?.takeUnretainedValue(),
              let updates = object(controller, "availableUpdates") as? [NSObject], updates.count <= 2000 else {
            throw PeerError.unavailable("Native Store update cache has not been initialized")
        }
        var offers: [Offer] = []
        for update in updates {
            guard !boolean(update, "isStaged"),
                  let id = object(update, "itemIdentifier") as? NSNumber,
                  let bundle = object(update, "bundleID") as? String,
                  let version = object(update, "bundleVersion") as? String,
                  id.uint64Value > 0, id.uint64Value < UInt64(Int64.max), !bundle.isEmpty, bundle.count <= 255,
                  !version.isEmpty, version.count <= 128 else { continue }
            offers.append(.init(storeID: id.uint64Value, bundleID: bundle, version: version))
        }
        return .init(offers: offers)
    }
    private static func object(_ receiver: AnyObject, _ name: String) -> AnyObject? {
        guard let type = object_getClass(receiver), let method = class_getInstanceMethod(type, NSSelectorFromString(name)),
              let encoding = method_getTypeEncoding(method), String(cString: encoding).hasPrefix("@"),
              method_getNumberOfArguments(method) == 2 else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(receiver, NSSelectorFromString(name))?.takeUnretainedValue()
    }
    private static func boolean(_ receiver: AnyObject, _ name: String) -> Bool {
        guard let type = object_getClass(receiver), let method = class_getInstanceMethod(type, NSSelectorFromString(name)),
              let encoding = method_getTypeEncoding(method), ["B", "c"].contains(String(cString: encoding).prefix(1).description),
              method_getNumberOfArguments(method) == 2 else { return true }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(receiver, NSSelectorFromString(name))
    }
}

/// Some framework failures can deliver both an XPC error and a late callback.
private final class StoreRefreshCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<StoreUpdateAvailability, any Error>?
    init(_ continuation: CheckedContinuation<StoreUpdateAvailability, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<StoreUpdateAvailability, any Error>) {
        lock.lock(); let saved = continuation; continuation = nil; lock.unlock()
        saved?.resume(with: result)
    }
}
