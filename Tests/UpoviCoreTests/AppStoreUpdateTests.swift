import XCTest
@testable import UpoviCore

final class AppStoreUpdateTests: XCTestCase, @unchecked Sendable {
    private var app: InstalledApp { .init(name:"Store fixture",bundleID:"app.synthetic.store",version:"1",build:"10",path:"/Applications/Upovi Synthetic Store.app",teamID:"SYNTHETIC1",isAppStore:true) }
    private func candidate() -> UpdateCandidate { .init(version:"2",source:"App Store",isCommunity:false,url:nil,appStoreID:12345) }
    func testExactStoreMetadataCreatesCandidateAndRefreshesWholeSnapshot() async throws {
        let replies = StoreReplies()
        let catalog = AppStoreCatalog(execute: { try await replies.run($0) })
        let first = await catalog.check(app)
        XCTAssertEqual(first.status,.updates); XCTAssertEqual(first.candidates.first?.appStoreID,12345)
        XCTAssertNil(first.candidates.first?.download)
        _ = await catalog.check(app)
        let cachedCalls = await replies.calls; XCTAssertEqual(cachedCalls,2)
        await replies.changeVersion("3"); await catalog.invalidate()
        let refreshed = await catalog.check(app)
        XCTAssertEqual(refreshed.candidates.first?.version,"3")
        let newCalls = await replies.calls; XCTAssertEqual(newCalls,4)
    }
    func testMissingProductWrongIdentityUnsupportedPlatformAndFailureNeverBecomeCurrent() async {
        for mode in ["missing","wrong-bundle","ios","future-os","failure","duplicate"] {
            let replies = StoreReplies(mode:mode), catalog = AppStoreCatalog(execute: { try await replies.run($0) })
            let result = await catalog.check(app)
            XCTAssertEqual(result.status,.failed,mode); XCTAssertTrue(result.candidates.isEmpty,mode)
        }
    }
    func testTestFlightOrMissingStoreIDStaysManualWithoutLookingUpZero() async {
        let replies = StoreReplies(mode:"zero")
        let catalog = AppStoreCatalog(execute: { try await replies.run($0) })
        let result = await catalog.check(app)
        XCTAssertEqual(result.status,.appStore); XCTAssertTrue(result.candidates.isEmpty)
        let count = await replies.calls; XCTAssertEqual(count,1)
    }
    func testEqualPublishedVersionIsCheckedButDoesNotOfferAnInstall() async {
        let replies = StoreReplies(); await replies.changeVersion("1")
        let catalog = AppStoreCatalog(execute: { try await replies.run($0) })
        let result = await catalog.check(app)
        XCTAssertEqual(result.status,.current); XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.checks.first?.outcome,.checked)
    }
    func testPartialBridgeExitPreservesValidProductsAndIsolatesMissingMalformedAndAmbiguousRows() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Upovi-StoreLookup-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bridge = folder.appending(path: "bridge")
        let installed = (12345...12348).map { id in
            "{\"adamID\":\(id),\"bundleID\":\"app.synthetic.\(id)\",\"path\":\"/synthetic/\(id).app\",\"version\":\"1\"}"
        } + [#"{"adamID":0,"bundleID":"app.synthetic.manual","path":"/synthetic/manual.app","version":"1"}"#]
        let products = [
            #"{"adamID":12345,"bundleID":"app.synthetic.12345","version":"2","minimumOSVersion":"14","kind":"mac-software"}"#,
            #"{"adamID":12347,"bundleID":"app.synthetic.12347","version":2}"#,
            #"{"adamID":12348,"bundleID":"app.synthetic.12348","version":"2","minimumOSVersion":"14","kind":"mac-software"}"#,
            #"{"adamID":12348,"version":2}"#,
            "not-json"
        ]
        let script = """
        #!/bin/sh
        if [ "$1" = list ] && [ "$#" = 1 ]; then
          printf '%s\\n' '\(installed.joined(separator: "\n"))'
          exit 0
        fi
        printf '%s\\n' '\(products.joined(separator: "\n"))'
        exit 2
        """
        try Data(script.utf8).write(to: bridge)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        let catalog = AppStoreCatalog(execute: { try await AppStoreCatalog.command(bridge, arguments: $0) })
        for id in 12345...12348 {
            let fixture = InstalledApp(name: "Fixture", bundleID: "app.synthetic.\(id)", version: "1", path: "/synthetic/\(id).app", isAppStore: true)
            let result = await catalog.check(fixture)
            XCTAssertEqual(result.status, id == 12345 ? .updates : .failed, "ID \(id)")
            XCTAssertEqual(result.candidates.count, id == 12345 ? 1 : 0)
        }
        let manual = await catalog.check(.init(name: "Manual", bundleID: "app.synthetic.manual", version: "1", path: "/synthetic/manual.app", isAppStore: true))
        XCTAssertEqual(manual.status, .appStore)
        // The exception is never used for install/update commands or a failing inventory scan.
        for arguments in [["update", "12345", "12346"], ["list", "unused"], ["lookup", "12345"], ["lookup", "--bundle", "app.synthetic.store"]] {
            do { _ = try await AppStoreCatalog.command(bridge, arguments: arguments); XCTFail("Unexpected exit code must fail: \(arguments)") }
            catch { }
        }
    }
    func testStoreLookupOutageDoesNotTurnKnownManualInstallationsIntoFailures() async {
        let catalog = AppStoreCatalog(execute: { arguments in
            if arguments == ["list"] {
                return Data(#"""
                {"adamID":0,"bundleID":"app.synthetic.manual","path":"/synthetic/manual.app","version":"1"}
                {"adamID":12345,"bundleID":"app.synthetic.store","path":"/Applications/Upovi Synthetic Store.app","version":"1"}
                """#.utf8)
            }
            throw URLError(.notConnectedToInternet)
        })
        let failed = await catalog.check(app)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.checks.first?.issue?.kind, .offline)
        let manual = await catalog.check(.init(name: "Manual", bundleID: "app.synthetic.manual", version: "1", path: "/synthetic/manual.app", isAppStore: true))
        XCTAssertEqual(manual.status, .appStore)
        XCTAssertEqual(manual.checks.first?.outcome, .manual)
    }
    func testRegionalMacLookupRecoversSodaWithoutOfferingAnUpdateThroughTheWrongStorefront() async throws {
        let fixture = InstalledApp(name: "Soda", bundleID: "com.soda.music", version: "2.9.1", path: "/synthetic/Soda.app", isAppStore: true)
        for version in ["2.9.1", "2.9.2"] {
            let source = RegionalStoreReplies(version: version)
            let catalog = AppStoreCatalog(execute: { try await source.execute($0) }, regionalLookup: { try await source.lookup($0, region: $1) })
            let result = await catalog.check(fixture)
            XCTAssertEqual(result.status, version == fixture.version ? .current : .updates)
            XCTAssertEqual(result.checks.first?.outcome, .checked)
            XCTAssertNil(result.appStoreID)
            if version != fixture.version {
                XCTAssertEqual(result.candidates.first?.url?.absoluteString, "https://apps.apple.com/cn/app/id1605585211")
                XCTAssertNil(result.candidates.first?.appStoreID)
                XCTAssertNil(result.candidates.first?.download)
            }
            let regions = await source.regions
            XCTAssertEqual(regions, ["CN"])
        }
    }
    func testRegionalLookupErrorsMissingAndInvalidProductsRemainFailures() async throws {
        let fixture = InstalledApp(name: "Soda", bundleID: "com.soda.music", version: "2.9.1", path: "/synthetic/Soda.app", isAppStore: true)
        for mode in ["absent", "offline", "malformed", "wrong-bundle", "ios", "duplicate"] {
            let source = RegionalStoreReplies(version: "2.9.2")
            let catalog = AppStoreCatalog(execute: { try await source.execute($0) }, regionalLookup: { _, _ in
                if mode == "absent" { return [] }
                if mode == "offline" { throw URLError(.notConnectedToInternet) }
                if mode == "malformed" { return try AppStoreCatalog.decodeLookup(Data("not-json".utf8)) }
                let bundle = mode == "wrong-bundle" ? "app.synthetic.unrelated" : "com.soda.music"
                let kind = mode == "ios" ? "software" : "mac-software"
                let product = try JSONDecoder().decode(StoreProduct.self, from: Data("{\"adamID\":1605585211,\"bundleID\":\"\(bundle)\",\"version\":\"2.9.2\",\"minimumOSVersion\":\"14\",\"kind\":\"\(kind)\"}".utf8))
                return mode == "duplicate" ? [product, product] : [product]
            })
            let result = await catalog.check(fixture)
            XCTAssertEqual(result.status, .failed, mode)
            XCTAssertEqual(result.checks.first?.outcome, .failed, mode)
            if mode == "offline" { XCTAssertEqual(result.checks.first?.issue?.kind, .offline) }
            XCTAssertTrue(result.candidates.isEmpty, mode)
        }
    }
    func testConfirmedNotionStoreMigrationPointsToDeveloperInsteadOfRepeatingFailedLookups() async {
        let catalog = AppStoreCatalog(execute: { args in
            args == ["list"] ? Data(#"{"adamID":1559269364,"bundleID":"notion.id.NotionSafariExtension","path":"/synthetic/Notion.app","version":"1.0.3"}"#.utf8) : Data()
        }, regionalLookup: { _, _ in XCTFail("The vendor has documented the Store migration"); return [] })
        let result = await catalog.check(.init(name: "Notion", bundleID: "notion.id.NotionSafariExtension", version: "1.0.3", path: "/synthetic/Notion.app", isAppStore: true))
        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.manualURL?.absoluteString, "https://www.notion.com/web-clipper")
        XCTAssertEqual(result.checks.first?.outcome, .manual)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertNil(ManualUpdateSource.forStoreBundle("notion.id.NotionSafariExtension", storeID: 12345))
        XCTAssertNil(ManualUpdateSource.forStoreBundle("app.synthetic.unrelated", storeID: 1559269364))
    }
    func testDesktopLookupCannotConfuseTheMobileSodaVersionWithItsNativeMacVersion() throws {
        let fixture = InstalledApp(name: "Soda", bundleID: "com.soda.music", version: "2.9.1", path: "/synthetic/Soda.app", isAppStore: true)
        for (version, devices) in [("2.9.1", #"["MacDesktop-MacDesktop"]"#), ("21.4.0", #"["MacDesktop-MacDesktop","iPhone18,1"]"#)] {
            let data = Data("{\"resultCount\":1,\"results\":[{\"trackId\":1605585211,\"bundleId\":\"com.soda.music\",\"version\":\"\(version)\",\"minimumOsVersion\":\"10.13\",\"kind\":\"software\",\"supportedDevices\":\(devices)}]}".utf8)
            let product = try XCTUnwrap(AppStoreCatalog.decodeLookup(data).first)
            if version == "2.9.1" { XCTAssertNoThrow(try product.validate(for: fixture, storeID: 1605585211)) }
            else { XCTAssertThrowsError(try product.validate(for: fixture, storeID: 1605585211)) }
        }
        XCTAssertThrowsError(try AppStoreCatalog.decodeLookup(Data(#"{"resultCount":1,"results":[]}"#.utf8)))
    }
    func testStorePlanRejectsUnrelatedChannelsPathsAccountsAndStaleApps() throws {
        let plan = AppStoreUpdatePlan(application:app,storeID:12345,version:"2",userID:501)
        XCTAssertNoThrow(try plan.validate())
        for id in [UInt64(0),UInt64.max] { XCTAssertThrowsError(try AppStoreUpdatePlan(application:app,storeID:id,version:"2",userID:501).validate()) }
        XCTAssertThrowsError(try AppStoreUpdatePlan(application:app,storeID:12345,version:"2",userID:0).validate())
        XCTAssertThrowsError(try AppStoreUpdatePlan(application:app,storeID:12345,version:"0",userID:501).validate())
        for path in ["/Applications/Utilities/Fixture.app","/Users/synthetic/Applications/Fixture.app","/Applications/../Applications/Fixture.app"] {
            let other = InstalledApp(name:app.name,bundleID:app.bundleID,version:"1",path:path,teamID:app.teamID,isAppStore:true)
            XCTAssertThrowsError(try AppStoreUpdatePlan(application:other,storeID:12345,version:"2",userID:501).validate())
        }
        let direct = InstalledApp(name:app.name,bundleID:app.bundleID,version:"1",path:app.path,teamID:app.teamID)
        XCTAssertThrowsError(try AppStoreUpdatePlan(application:direct,storeID:12345,version:"2",userID:501).validate())
        let changed = InstalledApp(name:app.name,bundleID:app.bundleID,version:"2",build:"20",path:app.path,teamID:app.teamID,isAppStore:true)
        XCTAssertThrowsError(try plan.verifyCurrent(changed)); XCTAssertNoThrow(try plan.verifyInstalled(changed))
        XCTAssertThrowsError(try plan.verifyInstalled(app)); XCTAssertThrowsError(try plan.verifyInstalled(direct))
    }
    func testStoreCapabilityCannotComeFromCommunityAndBulkKeepsChannelSpecificClaims() async throws {
        let peer = UpdateCandidate(version:"999",source:"peer",isCommunity:true,url:nil,appStoreID:12345)
        XCTAssertNil(peer.appStoreID)
        let item = try XCTUnwrap(BulkUpdatePlan.make(apps:[app],results:[app.id:.init(appID:app.id,candidates:[candidate()],note:"",status:.updates)],ignored:[]).first)
        XCTAssertTrue(item.canInstall)
        let outcomes = await BulkUpdateRunner.run([item],shouldStop:{false},operation:{_ in},report:{_ in})
        XCTAssertEqual(outcomes.first?.status,.installed); XCTAssertEqual(outcomes.first?.detail, String(localized: "商店更新完成，不提供 Upovi 旧版备份"))
        let saved = BulkUpdateRecord(items:[item]); XCTAssertEqual(saved.entries.first?.item.candidate.appStoreID,12345)
        XCTAssertNil(saved.entries.first?.item.candidate.download)
    }
    func testMetadataRejectsMalformedOrOversizedIdentityWithoutExecutingAnything() throws {
        XCTAssertThrowsError(try AppStoreCatalog.decode(Data("not-json".utf8)))
        let json = #"{"adamID":12345,"bundleID":"app.synthetic.store","path":"relative","version":"1"}"#
        XCTAssertThrowsError(try AppStoreCatalog.decode(Data(json.utf8)))
        XCTAssertThrowsError(try AppStoreCatalog.decode(Data(repeating:32,count:2_000_001)))
    }
    func testJSONRecordSeparatorsDoNotSplitUnicodeLineSeparatorsInsideStrings() throws {
        let raw = "{\"adamID\":12345,\"bundleID\":\"app.synthetic.store\",\"path\":\"/Applications/Fixture.app\",\"version\":\"1\",\"name\":\"First\u{2028}Second\"}\n"
        XCTAssertEqual(try AppStoreCatalog.decode(Data(raw.utf8)).count,1)
    }
    func testAccurateNoOpIsACompletedCurrentTaskAndNotAnInstalledUpgrade() async throws {
        let value = UpdateCandidate(version:app.version,source:"App Store",isCommunity:false,url:nil,appStoreID:12345)
        XCTAssertNoThrow(try AppStoreUpdatePlan(application:app,storeID:12345,version:app.version,userID:501).validate())
        let item = BulkUpdateItem(application:app,candidate:value,manualReason:nil)
        let outcome = await BulkUpdateRunner.run([item],shouldStop:{false},operation:{_ in throw AppStoreAlreadyCurrent()},report:{_ in})
        XCTAssertEqual(outcome.first?.status,.current)
        var record = BulkUpdateRecord(items:[item]); record.update(app.id,phase:.current,detail:"Already current")
        XCTAssertTrue(record.retryIDs.isEmpty)
    }
    func testAuthorizationStagesBothSignedHelpersAndQuotesCallerPaths() throws {
        let script = try AppStoreUpdatePlan.authorizationScript(helper:URL(fileURLWithPath:"/synthetic/helper's tool"),bridge:URL(fileURLWithPath:"/synthetic/bridge"),plan:URL(fileURLWithPath:"/synthetic/plan"),hostTeam:"SYNTHETIC1")
        XCTAssertTrue(script.contains("app.upovi.StoreInstaller")); XCTAssertTrue(script.contains("app.upovi.StoreBridge"))
        XCTAssertTrue(script.contains("with administrator privileges")); XCTAssertTrue(script.contains("/usr/sbin/chown -R 0:0"))
        XCTAssertTrue(script.contains("/usr/bin/stat -f %u /dev/console"))
        XCTAssertTrue(script.contains("/bin/launchctl asuser"))
        XCTAssertTrue(script.contains("/bin/chmod 755"))
        XCTAssertTrue(script.contains("/bin/chmod -R a+rX,go-w"))
        XCTAssertTrue(script.contains("/bin/chmod 600"))
        XCTAssertThrowsError(try AppStoreUpdatePlan.requirement(identifier:"untrusted",hostTeam:"SYNTHETIC1"))
        XCTAssertThrowsError(try AppStoreUpdatePlan.requirement(identifier:"app.upovi.StoreBridge",hostTeam:"bad\"team"))
    }
    func testProcessCommandsRespectOutputBoundsAndReportCancellation() async throws {
        do { _ = try await ProcessCommand().run("/usr/bin/printf",["1234567890"],maximumOutputBytes:4); XCTFail("Oversized output must fail") } catch { }
        do { _ = try await ProcessCommand().run("/bin/sh", ["-c", "kill -TERM $$"], successCodes: [15]); XCTFail("A signal is never a partial lookup exit code") } catch { }
        let command = ProcessCommand(); command.cancel()
        do { _ = try await command.run("/usr/bin/true",[]); XCTFail("Cancelled command cannot launch") } catch { XCTAssertTrue(error is CancellationError) }
    }
}

private actor StoreReplies {
    var calls = 0
    var version = "2"
    let mode: String
    init(mode:String="normal") { self.mode = mode }
    func changeVersion(_ value:String) { version = value }
    func run(_ args:[String]) throws -> Data {
        calls += 1
        if args[0] == "list" {
            let id = mode == "zero" ? 0 : 12345
            let row = "{\"adamID\":\(id),\"bundleID\":\"app.synthetic.store\",\"path\":\"/Applications/Upovi Synthetic Store.app\",\"version\":\"1\"}"
            return Data((mode == "duplicate" ? row+"\n"+row : row).utf8)
        }
        if mode == "failure" { throw URLError(.notConnectedToInternet) }
        if mode == "missing" { return Data() }
        let bundle = mode == "wrong-bundle" ? "app.synthetic.unrelated" : "app.synthetic.store"
        let devices = mode == "ios" ? "iPhone14,1" : "MacDesktop-MacDesktop"
        let minimum = mode == "future-os" ? "999" : "14"
        return Data("{\"adamID\":12345,\"bundleID\":\"\(bundle)\",\"version\":\"\(version)\",\"minimumOSVersion\":\"\(minimum)\",\"kind\":\"software\",\"supportedDevices\":[\"\(devices)\"]}".utf8)
    }
}

private actor RegionalStoreReplies {
    let version: String
    var regions: [String] = []
    init(version: String) { self.version = version }
    func execute(_ args: [String]) throws -> Data {
        args == ["list"] ? Data(#"{"adamID":1605585211,"bundleID":"com.soda.music","path":"/synthetic/Soda.app","version":"2.9.1"}"#.utf8) : Data()
    }
    func lookup(_ ids: [UInt64], region: String) throws -> [StoreProduct] {
        XCTAssertEqual(ids, [1605585211]); regions.append(region)
        guard region == "CN" else { return [] }
        return try AppStoreCatalog.decodeLookup(Data("{\"resultCount\":1,\"results\":[{\"trackId\":1605585211,\"bundleId\":\"com.soda.music\",\"version\":\"\(version)\",\"minimumOsVersion\":\"10.13\",\"kind\":\"software\",\"supportedDevices\":[\"MacDesktop-MacDesktop\"]}]}".utf8))
    }
}

extension AppStoreUpdateTests {
    func testVerifiedStoreUpdateDoesNotProbeAndCancelTheDownloadQueue() throws {
        let product = try JSONDecoder().decode(StoreProduct.self, from: Data(#"{"adamID":12345,"bundleID":"app.synthetic.store","version":"2","minimumOSVersion":"14","kind":"mac-software"}"#.utf8))
        let plan = AppStoreUpdatePlan(application: app, storeID: 12345, version: "2", userID: 501)
        XCTAssertEqual(try plan.updateArguments(for: product), ["update", "--force", "12345"])
        XCTAssertThrowsError(try AppStoreUpdatePlan(application: app, storeID: 99999, version: "2", userID: 501).updateArguments(for: product))
        XCTAssertThrowsError(try AppStoreUpdatePlan(application: app, storeID: 12345, version: "3", userID: 501).updateArguments(for: product))
        let current = try JSONDecoder().decode(StoreProduct.self, from: Data(#"{"adamID":12345,"bundleID":"app.synthetic.store","version":"1","minimumOSVersion":"14","kind":"mac-software"}"#.utf8))
        XCTAssertNil(try AppStoreUpdatePlan(application: app, storeID: 12345, version: "1", userID: 501).updateArguments(for: current))
    }

    func testStoreFailureReceiptCarriesItsCauseWithoutAccountIdentifiers() throws {
        let error = NSError(domain: "SyntheticStoreDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "Download cancelled"])
        var receipt = AppStoreUpdateReceipt(plan: .init(application: app, storeID: 12345, version: "2", userID: 501), state: "failedOrUnconfirmed")
        receipt.failure = .init(stage: "store", error: error, detail: "Error: Download cancelled for fixture@account.invalid")
        let decoded = try JSONDecoder().decode(AppStoreUpdateReceipt.self, from: JSONEncoder().encode(receipt))
        XCTAssertEqual(decoded.failure?.domain, "SyntheticStoreDomain")
        XCTAssertEqual(decoded.failure?.code, 42)
        XCTAssertEqual(decoded.failure?.stage, "store")
        let message = StoreInstallationError(try XCTUnwrap(decoded.failure)).localizedDescription
        XCTAssertTrue(message.contains("Download cancelled"))
        XCTAssertFalse(message.contains("fixture@account.invalid"))
    }
}

extension AppStoreUpdateTests {
    func testStoreFailureSkipsProgressLinesAndIdentifiesPermissionDenial() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [NSLocalizedDescriptionKey: "Write denied"])
        let failure = StoreInstallationFailure(stage: "store", error: error,
            detail: "==> Downloading Xcode (27.2)\n==> Updating Xcode (27.2)\nError: Failed to copy receipt: Operation not permitted")
        XCTAssertTrue(failure.message.hasPrefix("Error: Failed to copy receipt"))
        XCTAssertFalse(failure.message.contains("Downloading"))
        XCTAssertTrue(failure.requiresAppManagement)
        let progressOnly = StoreInstallationFailure(stage: "store", error: error, detail: "==> Downloading Xcode (27.2)")
        XCTAssertEqual(progressOnly.message, "Write denied")
        let diskFull = StoreInstallationFailure(stage: "appManagement", error: NSError(domain: NSCocoaErrorDomain, code: 640))
        XCTAssertFalse(diskFull.requiresAppManagement)
    }

    func testReceiptRecoveryIsBoundToTheRecordedDestinationAndNeverDownloadsAgain() throws {
        let detail = "Error: Failed to copy receipt for Running Application (2) from '/var/folders/fixture/receipt' to '\(app.path)/Contents/_MASReceipt/receipt': Operation not permitted"
        let failure = StoreInstallationFailure(stage: "store", error: PeerError.invalid("Failed"), detail: detail)
        XCTAssertEqual(failure.recoverableReceiptPath(application: app), "/var/folders/fixture/receipt")
        let unrelated = InstalledApp(name: "Other", bundleID: app.bundleID, version: "1", path: "/Applications/Other.app")
        XCTAssertNil(failure.recoverableReceiptPath(application: unrelated))
        let recovery = StoreReceiptRecovery(transactionID: UUID(), path: "/private/var/folders/fixture/receipt", sha256: String(repeating: "a", count: 64))
        let plan = AppStoreUpdatePlan(application: app, storeID: 12345, version: "2", userID: 501, receiptRecovery: recovery)
        XCTAssertNoThrow(try plan.validate())
        let product = try JSONDecoder().decode(StoreProduct.self, from: Data(#"{"adamID":12345,"bundleID":"app.synthetic.store","version":"2","minimumOSVersion":"14","kind":"mac-software"}"#.utf8))
        XCTAssertThrowsError(try plan.updateArguments(for: product))
        for path in ["/tmp/receipt", "/etc/passwd", "/private/var/folders/../receipt"] {
            XCTAssertThrowsError(try StoreReceiptRecovery(transactionID: UUID(), path: path, sha256: recovery.sha256).validate())
        }
    }

    func testReceiptRecoveryPreservesPhysicalTemporaryDirectoryPath() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "Upovi-receipt-path-\(UUID().uuidString)")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let canonical = try CanonicalFilePath.resolve(file)
        guard canonical.hasPrefix("/private/var/folders/") else { throw XCTSkip("Host temporary directory does not use the macOS /var alias") }
        let recovery = StoreReceiptRecovery(transactionID: UUID(), path: canonical, sha256: String(repeating: "a", count: 64))
        XCTAssertNoThrow(try recovery.validate())
        let alias = URL(fileURLWithPath: canonical.replacingOccurrences(of: "/private/var/", with: "/var/"))
        XCTAssertEqual(try CanonicalFilePath.resolve(alias), recovery.path)
    }

    func testUnsignedMalformedAndMismatchedReceiptPayloadsAreRejected() throws {
        func tlv(_ tag: UInt8, _ value: Data) -> Data { Data([tag, UInt8(value.count)]) + value }
        func attribute(_ type: UInt8, _ value: String) -> Data {
            tlv(0x30, tlv(0x02, Data([type])) + tlv(0x02, Data([1])) + tlv(0x04, tlv(0x0C, Data(value.utf8))))
        }
        let valid = tlv(0x31, attribute(2, app.bundleID) + attribute(3, app.version))
        XCTAssertNoThrow(try StoreReceiptVerifier.validatePayload(valid, application: app))
        XCTAssertThrowsError(try StoreReceiptVerifier.validate(valid, application: app))
        for data in [Data(), Data([0x31,0x80]), Data([0x31,0x84,0xFF,0xFF,0xFF,0xFF]),
                     tlv(0x31, attribute(2, "app.other") + attribute(3, app.version)),
                     tlv(0x31, attribute(2, app.bundleID) + attribute(3, "999")),
                     tlv(0x31, attribute(2, app.bundleID) + attribute(2, app.bundleID) + attribute(3, app.version))] {
            XCTAssertThrowsError(try StoreReceiptVerifier.validatePayload(data, application: app))
        }
    }
}
