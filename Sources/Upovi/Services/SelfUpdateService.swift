import Combine
import Foundation
import Sparkle

@MainActor
final class SelfUpdateService: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = SelfUpdateService()
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var sessionInProgress = false
    var installationBusy: () -> Bool = { false }
    let isConfigured: Bool
    private var controller: SPUStandardUpdaterController?

    private override init() {
        let bundle = Bundle.main
        isConfigured = bundle.bundleIdentifier == "app.upovi.Upovi"
            && (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String).flatMap { Data(base64Encoded: $0) }?.count == 32
            && (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:))?.scheme == "https"
        super.init()
        guard ProcessInfo.processInfo.environment["UPOVI_TEST_HOST"] != "1" else { return }
        guard isConfigured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
        controller.updater.publisher(for: \.sessionInProgress).assign(to: &$sessionInProgress)
    }

    func check() { controller?.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard installationBusy() else { return false }
        Task {
            while installationBusy() { try? await Task.sleep(for: .seconds(1)) }
            installHandler()
        }
        return true
    }
}
