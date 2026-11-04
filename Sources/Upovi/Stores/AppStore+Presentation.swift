import Foundation
import UpoviCore

extension UpdateCandidate {
    var displaySource: String { source + (isPrerelease ? " · Beta" : "") }
}

/// One user-facing status per application, derived only from source results, policy and community leads.
enum AppStatus: Equatable {
    case ignored, update(String), postponed, community(String), current, partial, failed, unsupported(manual: Bool), appStore, unchecked

    var label: String {
        switch self {
        case .ignored: String(localized: "已忽略")
        case .update(let version): String(localized: "可更新 \(version)")
        case .postponed: String(localized: "已跳过或推迟")
        case .community(let version): String(localized: "社区线索 \(version)")
        case .current: String(localized: "未发现更新")
        case .partial: String(localized: "部分检测失败")
        case .failed: String(localized: "检测失败")
        case .unsupported(let manual): manual ? String(localized: "需官方渠道") : String(localized: "未适配来源")
        case .appStore: "App Store"
        case .unchecked: String(localized: "尚未检查")
        }
    }
    /// Label without the version, for dense surfaces that show versions separately.
    var shortLabel: String {
        switch self {
        case .update: String(localized: "可更新")
        case .community: String(localized: "社区线索")
        default: label
        }
    }
    var targetVersion: String? {
        switch self {
        case .update(let version), .community(let version): version
        default: nil
        }
    }
    var symbol: String {
        switch self {
        case .ignored: "eye.slash"
        case .update: "arrow.down.circle.fill"
        case .postponed: "clock"
        case .community: "person.2.fill"
        case .current: "checkmark.circle.fill"
        case .partial, .failed: "exclamationmark.triangle.fill"
        case .unsupported: "questionmark.circle"
        case .appStore: "bag"
        case .unchecked: "circle.dashed"
        }
    }
    var tone: Tone {
        switch self {
        case .update: .accent
        case .community: .community
        case .current: .success
        case .partial, .failed: .warning
        default: .neutral
        }
    }
}

/// How a source candidate can be applied from inside Upovi.
enum UpdateAction: Equatable {
    case store, verifiedDownload, official
}

extension AppStore {
    func status(for app: InstalledApp) -> AppStatus {
        if ignored.contains(app.bundleID) { return .ignored }
        let assessment = assessment(for: app)
        if let candidate = assessment.sourceUpdates.first {
            return candidate.requiresRevalidation == true ? .partial : .update(candidate.version)
        }
        if fullAssessment(for: app).hasUpdate { return .postponed }
        if let lead = assessment.communityLeads.first { return .community(lead.report.version) }
        guard let result = sourceResults[app.id] else { return .unchecked }
        switch result.status {
        case .unsupported: return .unsupported(manual: result.manualURL != nil)
        case .partial: return .partial
        case .failed: return .failed
        case .current, .updates: return .current
        case .appStore: return .appStore
        }
    }

    func action(for candidate: UpdateCandidate, app: InstalledApp) -> UpdateAction {
        if candidate.requiresRevalidation == true || app.bundleID == "com.valvesoftware.steam" { return .official }
        if app.isAppStore, candidate.appStoreID != nil { return .store }
        if candidate.download?.canVerify(for: app) == true, ApplicationSourceCatalog.replacementTeam(for: app) != nil, app.bundleID != "app.upovi.Upovi" { return .verifiedDownload }
        return .official
    }

    /// Applies a candidate using the same flows the inspector and update list share.
    func perform(_ candidate: UpdateCandidate, app: InstalledApp) {
        switch action(for: candidate, app: app) {
        case .store: reviewStoreUpdate(app, candidate: candidate)
        case .verifiedDownload: prepareInstallation(candidate, app: app)
        case .official: open(candidate.url ?? sourceResults[app.id]?.manualURL)
        }
    }

    var operationBusy: Bool { installationBusy || refreshing || checking || scanning || toolChecking }

    /// Snoozed updates remain here; ignored applications and skipped versions have their own sidebar section.
    var postponedApps: [InstalledApp] {
        apps.filter { !hasIgnoredUpdateRules(for: $0) &&
            (updatePolicy.deferredUntil[UpdatePolicy.scope($0)] ?? .distantPast) > policyClock &&
            !assessment(for: $0).hasUpdate && fullAssessment(for: $0).hasUpdate }
    }

    var incompleteCheckApplications: [InstalledApp] {
        apps.filter { app in
            guard let result = sourceResults[app.id] else { return false }
            return result.status == .failed || result.status == .partial
        }
    }
    var incompleteCheckCount: Int { incompleteCheckApplications.count }
    func displayedInstalledVersion(for app: InstalledApp) -> String {
        sourceResults[app.id]?.installedVersion ?? app.version
    }

    func matchesSearch(_ app: InstalledApp) -> Bool {
        search.isEmpty || app.name.localizedCaseInsensitiveContains(search) || app.bundleID.localizedCaseInsensitiveContains(search)
    }

    func show(_ app: InstalledApp) {
        section = hasIgnoredUpdateRules(for: app) ? .ignored : .all; sourceFilter = .all; selection = app.id
        libraryInspectorPresented = true
    }
}
