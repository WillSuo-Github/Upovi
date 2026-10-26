import Foundation
import UpoviCore

extension AppStore {
    func recordDiagnostic(_ stage: DiagnosticEvent.Stage, appID: String? = nil, error: any Error) {
        diagnosticEvents.insert(.init(applicationID: appID, stage: stage, error: error), at: 0)
        diagnosticEvents = Array(diagnosticEvents.prefix(50))
        if let data = try? JSONEncoder().encode(diagnosticEvents) { preferences.set(data, forKey: "diagnosticEventsV1") }
    }
    func diagnosticSnapshot() -> DiagnosticSnapshot {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture: DiagnosticSnapshot.Environment.Architecture = .arm64
        #elseif arch(x86_64)
        let architecture: DiagnosticSnapshot.Environment.Architecture = .x86_64
        #else
        let architecture: DiagnosticSnapshot.Environment.Architecture = .unknown
        #endif
        let ordinary = installationReceipts.map { DiagnosticSnapshot.Transaction(applicationID: $0.application.id, kind: .application,
            state: .known($0.state.rawValue), date: $0.date) }
        let protected = administrator.attempts.map { DiagnosticSnapshot.Transaction(applicationID: $0.plan.application.id, kind: .administrator,
            state: .known($0.state), date: $0.updatedAt) }
        let batches = batchHistory.flatMap { record in record.entries.map { DiagnosticSnapshot.Transaction(applicationID: $0.item.application.id,
            kind: .batch, state: .known($0.phase.rawValue), date: record.finishedAt ?? record.startedAt) } }
        let downloads = downloadCenter.records.map { DiagnosticSnapshot.Transaction(applicationID: $0.applicationID, kind: .download, state: .known($0.state.rawValue), date: $0.updatedAt) }
        return .init(applications: apps, results: sourceResults, events: diagnosticEvents,
                     transactions: (ordinary + protected + batches + downloads).sorted { $0.date > $1.date },
                     environment: .init(version: AppMetadata.version, build: AppMetadata.build, osMajor: os.majorVersion,
                                        osMinor: os.minorVersion, architecture: architecture),
                     online: networkAvailable, busy: installationBusy || checking || scanning || refreshing)
    }
}
