import Foundation
import Observation
import UpoviCore

@MainActor @Observable
final class DownloadCenterService {
    private(set) var records: [DownloadRecord] = []
    private(set) var historySaveFailed = false
    @ObservationIgnored let coordinator: DownloadCoordinator
    @ObservationIgnored private var observation: Task<Void, Never>?
    init(coordinator: DownloadCoordinator) { self.coordinator = coordinator }
    func start() {
        guard observation == nil else { return }
        let coordinator = coordinator
        observation = Task { [weak self] in
            for await values in await coordinator.snapshots() {
                guard !Task.isCancelled, let self else { return }
                records = values; historySaveFailed = await coordinator.historySaveFailed
            }
        }
    }
    func pause(_ id: UUID) { Task { await coordinator.pause(id) } }
    func resume(_ id: UUID) { Task { await coordinator.resume(id) } }
    func cancel(_ id: UUID) { Task { await coordinator.cancel(id) } }
    func networkChanged(_ online: Bool) { Task { await coordinator.setOnline(online) } }
}
