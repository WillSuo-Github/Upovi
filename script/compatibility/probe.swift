// Explicit developer-run acceptance only. Never launches apps or installs system components.
import AppKit
import Foundation
@testable import UpoviCore

@main struct CompatibilityProbe {
    static var files: FileManager { .default }
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    static func bundles(in extraction: URL, bundleID: String) -> [URL] {
        var matches: [URL] = []
        if let iterator = files.enumerator(at: extraction, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            for case let path as URL in iterator {
                if path.pathExtension == "app" {
                    iterator.skipDescendants()
                    if path.resolvingSymlinksInPath() == path, AppScanner.read(path)?.bundleID == bundleID { matches.append(path) }
                } else if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { iterator.skipDescendants() }
            }
        }
        return matches
    }
    static func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func requireRoot(_ root: URL) throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.path.hasPrefix(repository.appending(path: ".local").path + "/"), root.resolvingSymlinksInPath() == root,
              (try? String(contentsOf: root.appending(path: "explicit-acceptance-root"), encoding: .utf8)) == root.path else {
            throw PeerError.invalid("An explicitly initialized, unlinked repository .local case directory is required")
        }
    }
    static func inspectPayload(root: URL, archive: URL, cask: CaskMetadata) async throws {
        try requireRoot(root)
        guard archive.deletingLastPathComponent() == root, archive.resolvingSymlinksInPath() == archive,
              let descriptor = cask.download, let expectedSHA = descriptor.sha256,
              !cask.applicationNames.isEmpty else { throw PeerError.invalid("Use an isolated direct-app cask with an independent checksum") }
        var evidence: [String: Any] = ["schemaVersion": 1, "token": cask.token, "testedAt": Date().ISO8601Format(),
            "hostOS": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": architecture, "sourceURL": descriptor.url.absoluteString,
            "sourceSHA256": expectedSHA, "stage": "archiveIntegrity", "payloadVerified": false,
            "upgradeVerified": false, "firstLaunchTested": false, "systemComponentsTested": false]
        let extraction = root.appending(path: "Extracted")
        guard !files.fileExists(atPath: extraction.path) else { throw PeerError.invalid("Use a fresh inspection directory") }
        var mounted = false
        do {
            let observedSHA = try BundleVerifier.sha256(of: archive)
            evidence["observedSHA256"] = observedSHA
            guard observedSHA == expectedSHA else { throw PeerError.invalid("Cask archive checksum mismatch") }
            evidence["stage"] = "extract"
            if DownloadDescriptor.sniffFormat(of: archive) == "zip" { try ArchiveExtractor.extractZIP(archive, to: extraction) }
            else if DownloadDescriptor.sniffFormat(of: archive) == "dmg" {
                try files.createDirectory(at: extraction, withIntermediateDirectories: false)
                _ = try await ProcessCommand().run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", extraction.path, archive.path])
                mounted = true
            } else { throw PeerError.invalid("Package requires a disposable VM or unsupported archive format") }
            let paths = applicationBundles(in: extraction).filter { cask.applicationNames.contains($0.lastPathComponent) }
            guard !paths.isEmpty else { throw PeerError.invalid("No application matches the declared cask bundle filename") }
            var apps: [[String: Any]] = []
            for path in paths {
                guard let app = AppScanner.read(path), !app.isAppStore, let executable = Bundle(url: path)?.executableURL else {
                    throw PeerError.invalid("Cannot read a direct developer application")
                }
                evidence["stage"] = "developerSignature"
                try BundleVerifier.checkDeveloperIDSignature(path, like: app)
                evidence["stage"] = "nativeExecutable"
                try MachOCompatibility.validate(executable)
                evidence["stage"] = "gatekeeper"
                try await ApplicationInstallation.assess(path)
                var record: [String: Any] = ["bundleID": app.bundleID, "application": path.lastPathComponent, "version": app.version,
                             "build": app.build, "teamID": app.teamID ?? "", "executableSHA256": try BundleVerifier.sha256(of: executable)]
                if let feed = app.feedURL, feed.user == nil, feed.password == nil, feed.query == nil, feed.fragment == nil {
                    record["publicAppcastURL"] = feed.absoluteString
                }
                apps.append(record)
            }
            evidence["applications"] = apps; evidence["payloadVerified"] = true; evidence["stage"] = "complete"
            evidence["mappingReviewRequired"] = true
        } catch { evidence["errorKind"] = DiagnosticIssue(error).kind.rawValue; evidence["error"] = error.localizedDescription }
        if mounted {
            do { _ = try await ProcessCommand().run("/usr/bin/hdiutil", ["detach", extraction.path]); mounted = false }
            catch { evidence["cleanupError"] = "Inspection image could not be detached" }
        }
        if !mounted, files.fileExists(atPath: extraction.path) { try files.removeItem(at: extraction) }
        evidence["temporaryCopiesRemoved"] = !mounted; evidence["terminal"] = true
        try write(evidence, to: root.appending(path: "result.json")); UpoviLogManager.shared.flush()
        print("\(cask.token): payloadVerified=\(evidence["payloadVerified"] ?? false); upgradeVerified=false")
        if evidence["payloadVerified"] as? Bool != true || mounted { exit(2) }
    }
    static func applicationBundles(in root: URL) -> [URL] {
        var matches: [URL] = []
        if let iterator = files.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            for case let path as URL in iterator {
                if path.pathExtension == "app" {
                    iterator.skipDescendants()
                    if path.resolvingSymlinksInPath() == path { matches.append(path) }
                } else if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { iterator.skipDescendants() }
            }
        }
        return matches
    }
    static func inspectExternalBaseline(root: URL, archive: URL, sourceURL: URL, signature: Data?) async throws {
        try requireRoot(root)
        guard archive.deletingLastPathComponent() == root, archive.resolvingSymlinksInPath() == archive,
              sourceURL.scheme == "https", sourceURL.user == nil, sourceURL.password == nil, sourceURL.fragment == nil else {
            throw PeerError.invalid("Use an isolated baseline archive and its actual public HTTPS source")
        }
        let extraction = root.appending(path: "Extracted")
        guard !files.fileExists(atPath: extraction.path) else { throw PeerError.invalid("Use a fresh baseline inspection root") }
        var evidence: [String: Any] = ["schemaVersion": 1, "testedAt": Date().ISO8601Format(), "stage": "oldArchive",
            "oldArchiveSHA256": try BundleVerifier.sha256(of: archive), "oldSourceURL": sourceURL.absoluteString,
            "upgradeVerified": false, "productReviewRequired": true, "firstLaunchTested": false]
        var mounted = false
        do {
            if DownloadDescriptor.sniffFormat(of: archive) == "zip" { try ArchiveExtractor.extractZIP(archive, to: extraction) }
            else if DownloadDescriptor.sniffFormat(of: archive) == "dmg" {
                try files.createDirectory(at: extraction, withIntermediateDirectories: false)
                _ = try await ProcessCommand().run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", extraction.path, archive.path])
                mounted = true
            } else { throw PeerError.invalid("Only ZIP and DMG baselines are accepted; packages require a disposable VM") }
            let paths = applicationBundles(in: extraction).filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && AppScanner.read($0) != nil
            }
            guard paths.count == 1, let path = paths.first, let app = AppScanner.read(path), !app.isAppStore,
                  let executable = Bundle(url: path)?.executableURL else { throw PeerError.invalid("Baseline has no unique developer application") }
            evidence["stage"] = "oldDeveloperSignature"
            try BundleVerifier.checkDeveloperIDSignature(path, like: app)
            evidence["bundleID"] = app.bundleID; evidence["oldVersion"] = app.version; evidence["oldBuild"] = app.build
            evidence["oldTeamID"] = app.teamID ?? ""; evidence["application"] = path.lastPathComponent
            evidence["oldSignatureVerified"] = true; evidence["oldExecutableSHA256"] = try BundleVerifier.sha256(of: executable)
            if let signature {
                evidence["stage"] = "oldEnclosureSignature"
                try BundleVerifier.verifyArchive(archive, descriptor: .init(url: sourceURL, edSignature: signature), app: app)
                evidence["oldEnclosureSignatureVerified"] = true
            }
            if let feed = app.feedURL { evidence["embeddedFeedURL"] = feed.absoluteString }
            if let infoData = try? Data(contentsOf: path.appending(path: "Contents/Info.plist")),
               let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] {
                evidence["bundlePackageType"] = info["CFBundlePackageType"] as? String ?? ""
                evidence["backgroundOnly"] = info["LSBackgroundOnly"] as? Bool ?? false
            }
            do {
                if let source = try ElectronUpdateSource.installed(in: app) {
                    switch source {
                    case .generic(let url): evidence["embeddedElectronFeed"] = url.absoluteString
                    case .github(let repo): evidence["embeddedGitHubRepository"] = repo
                    }
                }
            } catch { evidence["embeddedSourceIssue"] = DiagnosticIssue(error).kind.rawValue }
            evidence["baselineInspected"] = true; evidence["stage"] = "complete"
        } catch { evidence["errorKind"] = DiagnosticIssue(error).kind.rawValue; evidence["error"] = error.localizedDescription }
        if mounted {
            do { _ = try await ProcessCommand().run("/usr/bin/hdiutil", ["detach", extraction.path]); mounted = false }
            catch { evidence["cleanupError"] = "Baseline image could not be detached" }
        }
        if !mounted, files.fileExists(atPath: extraction.path) { try files.removeItem(at: extraction) }
        evidence["temporaryCopiesRemoved"] = !mounted; evidence["terminal"] = true
        try write(evidence, to: root.appending(path: "result.json")); UpoviLogManager.shared.flush()
        print("Baseline inspected=\(evidence["baselineInspected"] as? Bool == true); product review required; upgradeVerified=false")
        if evidence["baselineInspected"] as? Bool != true || mounted { exit(2) }
    }
    static func main() async {
        do { try await run() }
        catch { print("Probe failed: \(error.localizedDescription)"); exit(1) }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        func option(_ name: String) throws -> String {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { throw PeerError.invalid("Missing \(name)") }
            return args[i + 1]
        }
        let casks = try JSONDecoder().decode([CaskMetadata].self, from: Data(contentsOf: URL(fileURLWithPath: option("--catalog"))))
        if args.contains("external-baseline") {
            guard let url = URL(string: try option("--old-url")) else { throw PeerError.invalid("Invalid baseline source URL") }
            let signature: Data?
            if args.contains("--old-ed-signature") {
                guard let value = Data(base64Encoded: try option("--old-ed-signature")), value.count == 64 else { throw PeerError.invalid("Invalid old enclosure proof") }
                signature = value
            } else { signature = nil }
            try await inspectExternalBaseline(root: URL(fileURLWithPath: option("--root")).standardizedFileURL,
                archive: URL(fileURLWithPath: option("--old-archive")).standardizedFileURL, sourceURL: url, signature: signature)
            return
        }
        if args.contains("appcast-audit") {
            let root = URL(fileURLWithPath: try option("--root")).standardizedFileURL
            try requireRoot(root)
            let inputs = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "inputs.json"))) as? [[String: Any]] ?? []
            var pairs: [[String: Any]] = [], held: [[String: String]] = []
            let independent = args.contains("--independent-sources")
            for input in inputs where input["downloaded"] as? Bool == true {
                guard let token = input["token"] as? String, token.range(of: #"^[a-z0-9][a-z0-9+_-]{0,100}$"#, options: .regularExpression) != nil else { continue }
                let cask = casks.first(where: { $0.token == token && $0.disabled != true })
                guard independent || (cask?.applicationNames.isEmpty == false) else { continue }
                do {
                    let file = root.appending(path: token + ".xml")
                    guard file.resolvingSymlinksInPath() == file else { throw PeerError.invalid("Linked appcast input") }
                    let data = try Data(contentsOf: file)
                    guard data.count <= 3_000_000 else { throw PeerError.invalid("Oversized appcast") }
                    if independent {
                        let text = String(decoding: data, as: UTF8.self).lowercased()
                        guard !text.contains("<!doctype"), !text.contains("<!entity") else { throw PeerError.invalid("Research feed contains unsupported declarations") }
                    }
                    let offers = try AppcastReader.read(data).filter { offer in
                        guard let download = offer.download else { return false }
                        return ["zip", "dmg"].contains(download.url.pathExtension.lowercased()) &&
                            download.url.user == nil && download.url.password == nil && download.url.fragment == nil
                    }
                    let sorted = offers.sorted { left, right in
                        if let order = VersionOrder.compare(left.version, right.version), order != .orderedSame { return order == .orderedDescending }
                        return VersionOrder.compare(left.build, right.build) == .orderedDescending
                    }
                    guard let newest = sorted.first, let old = sorted.dropFirst().first(where: { offer in
                        newest.isNewer(than: .init(name: "Baseline", bundleID: "app.discovery.baseline", version: offer.version, build: offer.build, path: "/discovery")) &&
                            offer.download?.url != newest.download?.url
                    }), let url = old.download?.url else { throw PeerError.invalid("No distinct older signed enclosure") }
                    if independent {
                        pairs.append(["token": token, "kind": "externalAppcastResearch", "productReviewRequired": true,
                            "oldURL": url.absoluteString, "oldDeclaredVersion": old.version, "oldDeclaredBuild": old.build,
                            "oldEDSignature": old.download?.edSignature?.base64EncodedString() ?? "",
                            "discoveryNewestDeclaredVersion": newest.version, "sourceRepository": input["sourceRepository"] ?? "",
                            "sourceDescription": input["sourceDescription"] ?? "", "sourceURL": input["sourceURL"] ?? "",
                            "feedSnapshotSHA256": input["sha256"] ?? "", "sourceGitBlobSHA": input["sourceGitBlobSHA"] ?? "",
                            "provenance": "Immutable public appcast research lead; actual signed baseline identity, product-source review and full production upgrade acceptance still required."])
                        continue
                    }
                    guard let cask else { continue }
                    pairs.append(["token": token, "cask": token, "bundleID": cask.bundleIDs.count == 1 ? cask.bundleIDs[0] : "",
                        "oldVersion": "", "discoverBaseline": true, "oldURL": url.absoluteString,
                        "oldReleaseURL": input["appcastURL"] ?? "", "oldDeclaredVersion": old.version, "oldDeclaredBuild": old.build,
                        "feedSnapshotSHA256": input["sha256"] ?? "", "provenance": "Actual older stable Sparkle enclosure parsed by production AppcastReader; baseline Apple signature and live source/install/restore still required."])
                } catch { held.append(["token": token, "issue": DiagnosticIssue(error).kind.rawValue]) }
            }
            try write(["schemaVersion": 1, "unverifiedPairs": pairs, "held": held, "verifiedApps": 0], to: root.appending(path: "discovered.json"))
            print("Appcast discovery: \(pairs.count) unverified pairs; \(held.count) held; zero upgrade claims")
            return
        }
        if args.contains("audit") {
            let rows: [[String: Any]] = casks.map { cask in
                var platforms: [[String: Any]] = []
                for os in [14, 15, 26, 27] {
                    for intel in [false, true] {
                        let descriptor = cask.download(intel: intel, osMajor: os)
                        platforms.append(["architecture": intel ? "x86_64" : "arm64", "macOSMajor": os,
                            "version": cask.platformVersion(intel: intel, osMajor: os),
                            "checksumDescriptorAvailable": descriptor != nil,
                            "url": descriptor?.url.absoluteString ?? "", "sha256": descriptor?.sha256 ?? ""])
                    }
                }
                return ["token": cask.token, "declaredAppNames": cask.applicationNames,
                    "declaredBundleIDs": cask.bundleIDs, "disabled": cask.disabled == true,
                    "declaredIdentityPathReferences": cask.bundleIdentityReferences,
                    "platforms": platforms, "payloadVerified": false, "upgradeVerified": false]
            }
            try write(["schemaVersion": 1, "parser": "UpoviCore.CaskMetadata", "rows": rows],
                      to: URL(fileURLWithPath: option("--output")))
            print("Audited \(rows.count) metadata records; no binaries downloaded or installed")
            return
        }
        if args.contains("payload") {
            guard let cask = casks.first(where: { $0.token == (try? option("--cask")) }), cask.disabled != true else {
                throw PeerError.invalid("Missing active cask identity")
            }
            try await inspectPayload(root: URL(fileURLWithPath: option("--root")).standardizedFileURL,
                                     archive: URL(fileURLWithPath: option("--archive")).standardizedFileURL, cask: cask)
            return
        }
        guard args.contains("upgrade") else { throw PeerError.invalid("Use audit, payload or upgrade") }
        let channelName = args.contains("--channel") ? try option("--channel") : "stable"
        guard let channel = ReleaseChannel(rawValue: channelName) else { throw PeerError.invalid("Use stable or beta as the explicit test channel") }
        let root = URL(fileURLWithPath: try option("--root")).standardizedFileURL
        try requireRoot(root)
        let archive = URL(fileURLWithPath: try option("--old-archive")).standardizedFileURL
        guard archive.deletingLastPathComponent() == root, archive.resolvingSymlinksInPath() == archive else {
            throw PeerError.invalid("Old archive must be an unlinked file directly inside the case directory")
        }
        let expectedID = try option("--bundle-id"), expectedVersion = try option("--old-version")
        let discovery = args.contains("--discover-baseline")
        let discoveryCask: CaskMetadata?
        if discovery {
            let token = try option("--cask")
            guard let selected = casks.first(where: { $0.token == token && $0.disabled != true }),
                  !selected.applicationNames.isEmpty else { throw PeerError.invalid("Baseline discovery requires a direct-app cask identity") }
            discoveryCask = selected
        } else { discoveryCask = nil }
        let extraction = root.appending(path: "Extracted"), applications = root.appending(path: "Applications")
        guard !files.fileExists(atPath: extraction.path), !files.fileExists(atPath: applications.path) else {
            throw PeerError.invalid("Use a fresh case directory; prior copies may contain recovery evidence")
        }
        var evidence: [String: Any] = ["schemaVersion": 1, "testedAt": ISO8601DateFormatter().string(from: Date()),
            "bundleID": expectedID, "fromVersion": expectedVersion, "hostOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": architecture, "releaseChannel": channel.rawValue, "sourceVerified": false, "payloadVerified": false, "installationPassed": false,
            "restorePassed": false, "postInstallCurrent": false, "upgradeVerified": false,
            "firstLaunchTested": false, "systemComponentsTested": false,
            "scope": "isolated bundle replacement and restore; no first launch, privileged installation or user-data migration",
            "oldArchiveSHA256": try BundleVerifier.sha256(of: archive), "stage": "oldArchive"]
        let resultURL = root.appending(path: "result.json")
        func save() throws { try write(evidence, to: resultURL) }
        let configuration = URLSessionConfiguration.ephemeral
        if let index = args.firstIndex(of: "--proxy-port"), index + 1 < args.count,
           let port = Int(args[index + 1]), (1...65535).contains(port) {
            configuration.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
                "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port]
        }
        let client = SourceHTTPClient(cooldownURL: root.deletingLastPathComponent().appending(path: "github-cooldown.json"), transport: { url, limit, headers in
            try await HTTPTransfer.metadata(from: url, limit: limit, headers: headers, configuration: configuration)
        })
        let publicGitHubFault = args.contains("--fault-github-api-rate-limit-other-metadata-offline")
        if publicGitHubFault { evidence["injectedMetadataFault"] = "githubAPI429-otherSourcesOffline" }
        let fetch: @Sendable (URL, Int) async throws -> Data = { url, limit in
            if publicGitHubFault {
                if url.host == "api.github.com" { throw HTTPStatusError(statusCode: 429, rateLimited: true) }
                if url.host != "github.com" { throw URLError(.notConnectedToInternet) }
            }
            return try await client.data(from: url, limit: limit)
        }
        let cache = ArtifactDownloadCache(directory: root.appending(path: "Cache"), configuration: configuration)
        let downloads = DownloadCoordinator(cache: cache, storageURL: root.appending(path: "downloads.json"))
        let installer = UpdateInstaller(journalDirectory: root.appending(path: "Journal"), downloads: downloads)
        var mounted = false
        var preparedID: UUID?
        var installedReceipt: InstallationReceipt?
        var original: InstalledApp?
        var originalSHA: String?
        do {
            let format = DownloadDescriptor.sniffFormat(of: archive)
            if format == "zip" { try ArchiveExtractor.extractZIP(archive, to: extraction) }
            else if format == "dmg" {
                try files.createDirectory(at: extraction, withIntermediateDirectories: false)
                _ = try await ProcessCommand().run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", extraction.path, archive.path])
                mounted = true
            } else { throw PeerError.invalid("Only ZIP and DMG old archives are accepted; PKG requires a disposable VM") }
            let matches: [URL]
            if let discoveryCask {
                matches = applicationBundles(in: extraction).filter { path in
                    discoveryCask.applicationNames.contains(path.lastPathComponent) &&
                        (expectedID.isEmpty || AppScanner.read(path)?.bundleID == expectedID)
                }
            } else { matches = bundles(in: extraction, bundleID: expectedID) }
            guard matches.count == 1 else { throw PeerError.invalid("Old archive has no unique main application identity") }
            try files.createDirectory(at: applications, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let target = applications.appending(path: matches[0].lastPathComponent)
            try files.copyItem(at: matches[0], to: target)
            if mounted { _ = try await ProcessCommand().run("/usr/bin/hdiutil", ["detach", extraction.path]); mounted = false }
            guard let app = AppScanner.read(target) else { throw PeerError.invalid("Cannot read the old application") }
            evidence["observedOldVersion"] = app.version; evidence["observedOldBuild"] = app.build
            guard (app.version == expectedVersion || (discovery && expectedVersion.isEmpty)),
                  let executable = Bundle(url: target)?.executableURL else { throw PeerError.invalid("Old application version or executable mismatch") }
            try BundleVerifier.checkSignature(target, like: app)
            // An observed old archive hash is provenance, not independent source proof.
            // The real Apple-anchored signature (or exact reviewed legacy migration) binds the baseline.
            if ApplicationSourceCatalog.legacyMigration(for: app) == nil { try BundleVerifier.checkDeveloperIDSignature(target, like: app) }
            if args.contains("--reviewed-team-id"), app.teamID != (try option("--reviewed-team-id")) {
                throw PeerError.invalid("Baseline developer differs from the reviewed external application")
            }
            if args.contains("--reviewed-application"), target.lastPathComponent != (try option("--reviewed-application")) {
                throw PeerError.invalid("Baseline filename differs from the reviewed external application")
            }
            if args.contains("--old-ed-signature") {
                guard let signature = Data(base64Encoded: try option("--old-ed-signature")), signature.count == 64,
                      let sourceURL = URL(string: try option("--old-url")) else { throw PeerError.invalid("Invalid reviewed old enclosure proof") }
                try BundleVerifier.verifyArchive(archive, descriptor: .init(url: sourceURL, edSignature: signature), app: app)
                evidence["oldEnclosureSignatureVerified"] = true
            }
            original = app; originalSHA = try BundleVerifier.sha256(of: executable)
            evidence["bundleID"] = app.bundleID; evidence["fromVersion"] = app.version
            evidence["oldBuild"] = app.build; evidence["oldTeamID"] = app.teamID ?? ""; evidence["oldSignatureVerified"] = true
            evidence["stage"] = "source"; try save()
            let result = await UpdateChecker.check(app, override: .init(releaseChannel: channel), fetch: fetch,
                                                  catalog: { app in publicGitHubFault ? nil : CaskCatalog.resolve(app, in: casks) })
            evidence["sourceStatus"] = result.status.rawValue
            evidence["checkedSources"] = result.checks.filter { $0.outcome == .checked }.map { $0.source.rawValue }
            evidence["sourceChecks"] = result.checks.map { ["source": $0.source.rawValue, "outcome": $0.outcome.rawValue] }
            guard let item = BulkUpdatePlan.make(apps: [app], results: [app.id: result], ignored: []).first, item.canInstall else {
                throw PeerError.invalid("Live production source check did not select an installable update: \(result.note)")
            }
            evidence["sourceVerified"] = true; evidence["selectedVersion"] = item.candidate.version
            evidence["selectedBuild"] = item.candidate.build; evidence["selectedSource"] = item.candidate.source
            evidence["selectedReleaseChannel"] = item.candidate.releaseChannel?.rawValue ?? "stable"
            evidence["selectedIsPrerelease"] = item.candidate.isPrerelease
            evidence["selectedStablePackagingReviewed"] = item.candidate.isReviewedStablePackaging == true
            evidence["downloadURL"] = item.candidate.download?.url.absoluteString ?? ""
            evidence["sourceSHA256"] = item.candidate.download?.sha256 ?? ""
            evidence["sourceSHA512"] = item.candidate.download?.sha512 ?? ""
            evidence["stage"] = "prepare"; try save()
            let prepared = try await installer.prepare(app: app, candidate: item.candidate, progress: { _, _ in })
            preparedID = prepared.id; evidence["payloadVerified"] = true
            evidence["installedVersion"] = prepared.replacement.version; evidence["installedBuild"] = prepared.replacement.build
            evidence["newTeamID"] = prepared.replacement.teamID ?? ""; evidence["archiveIntegrityVerified"] = prepared.archiveIntegrityVerified
            evidence["stage"] = "install"; try save()
            let receipt = try await installer.install(prepared.id, requireNotRunning: true)
            preparedID = nil; installedReceipt = receipt
            guard let updated = AppScanner.read(target), updated.version == prepared.replacement.version,
                  updated.build == prepared.replacement.build else { throw PeerError.invalid("Installed application does not match prepared version") }
            try BundleVerifier.checkDeveloperIDSignature(target, like: app)
            try ApplicationInstallation.verifyFinalized(target)
            evidence["installationPassed"] = true; evidence["stage"] = "postInstallCheck"; try save()
            let refreshed = await UpdateChecker.check(updated, override: .init(releaseChannel: channel), fetch: fetch,
                                                     catalog: { app in publicGitHubFault ? nil : CaskCatalog.resolve(app, in: casks) })
            evidence["postInstallSourceStatus"] = refreshed.status.rawValue
            evidence["postInstallCurrent"] = refreshed.candidates.isEmpty && refreshed.checks.contains { $0.outcome == .checked }
            evidence["stage"] = "restore"; try save()
            try await installer.restore(receipt)
            guard let restored = AppScanner.read(target), restored.version == app.version, restored.build == app.build,
                  let restoredExecutable = Bundle(url: target)?.executableURL,
                  try BundleVerifier.sha256(of: restoredExecutable) == originalSHA else { throw PeerError.invalid("Restored baseline differs") }
            try BundleVerifier.checkSignature(target, like: app)
            installedReceipt = nil
            evidence["restorePassed"] = true
            evidence["upgradeVerified"] = evidence["postInstallCurrent"] as? Bool == true
            evidence["stage"] = "complete"; try save()
        } catch {
            evidence["errorKind"] = DiagnosticIssue(error).kind.rawValue
            evidence["error"] = error.localizedDescription
            if let receipt = installedReceipt {
                do {
                    try await installer.restore(receipt)
                    if let original, let executable = Bundle(url: URL(fileURLWithPath: original.path))?.executableURL {
                        let restoredSHA = try BundleVerifier.sha256(of: executable)
                        let restored = AppScanner.read(URL(fileURLWithPath: original.path))
                        try BundleVerifier.checkSignature(URL(fileURLWithPath: original.path), like: original)
                        evidence["restorePassed"] = restored?.version == original.version && restored?.build == original.build && restoredSHA == originalSHA
                    }
                } catch { evidence["recoveryError"] = error.localizedDescription }
            }
            try save()
        }
        if let preparedID { await installer.discard(preparedID) }
        if mounted {
            do { _ = try await ProcessCommand().run("/usr/bin/hdiutil", ["detach", extraction.path]); mounted = false }
            catch { evidence["cleanupError"] = "Old image could not be detached" }
        }
        // Preserve failed restore artifacts; do not silently erase recovery evidence.
        let recoveryRequired = installedReceipt != nil && evidence["restorePassed"] as? Bool != true
        if !mounted && !recoveryRequired {
            for name in ["Applications", "Extracted", "Cache"] {
                let path = root.appending(path: name)
                if files.fileExists(atPath: path.path) { try files.removeItem(at: path) }
            }
            evidence["temporaryCopiesRemoved"] = true
        } else { evidence["temporaryCopiesRemoved"] = false }
        evidence["terminal"] = true
        try save(); UpoviLogManager.shared.flush()
        print("\(expectedID): stage=\(evidence["stage"] ?? "unknown") upgradeVerified=\(evidence["upgradeVerified"] ?? false)")
        if evidence["upgradeVerified"] as? Bool != true { exit(2) }
    }
}
