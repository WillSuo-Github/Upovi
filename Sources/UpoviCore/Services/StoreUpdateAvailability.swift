import Foundation
import Darwin
import ObjectiveC.runtime

/// Positive evidence from the current user's Store cache. An absent entry is never proof that
/// an app is current: the cache may be empty, stale, signed out, or not initialized yet.
public struct StoreUpdateAvailability: Codable, Sendable {
    public struct Offer: Codable, Sendable {
        public let storeID: UInt64
        public let bundleID: String
        public let version: String
        public init(storeID: UInt64, bundleID: String, version: String) {
            self.storeID = storeID; self.bundleID = bundleID; self.version = version
        }
    }
    public let offers: [Offer]
    public init(offers: [Offer]) { self.offers = offers }
    public func confirms(_ app: InstalledApp, storeID: UInt64, version: String) -> Bool {
        let matches = offers.filter { $0.storeID == storeID }
        return matches.count == 1 && matches[0].bundleID == app.bundleID &&
            VersionOrder.compare(matches[0].version, version) == .orderedSame
    }
    public static func query(using helper: URL) async throws -> Self {
        let data = try await ProcessCommand().run(helper.path, ["--cached-updates"], timeoutSeconds: 5, maximumOutputBytes: 1_000_000)
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.offers.count <= 2000, value.offers.allSatisfy({ $0.storeID > 0 && $0.storeID < UInt64(Int64.max) &&
            !$0.bundleID.isEmpty && $0.bundleID.count <= 255 && !$0.version.isEmpty && $0.version.count <= 128 }) else {
            throw PeerError.invalid("Invalid native Store update metadata")
        }
        return value
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
