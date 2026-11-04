import SwiftUI
import UpoviCore

struct IgnoredAppsView: View {
    @Bindable var store: AppStore

    var body: some View {
        let apps = store.visibleApps
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: String(localized: "已忽略"), subtitle: String(localized: "集中管理已忽略的应用和已跳过的版本。恢复提醒不会开始安装。")) {
                    Text(store.ignoredApps.count.formatted()).font(Theme.display(26, weight: .semibold)).monospacedDigit().foregroundStyle(.tertiary)
                }
                if apps.isEmpty {
                    if !store.search.isEmpty { ContentUnavailableView.search(text: store.search) }
                    else {
                        ContentUnavailableView("没有已忽略的应用", systemImage: "eye.slash",
                            description: Text("忽略应用更新或跳过某个版本后，可在这里查看和恢复提醒。"))
                    }
                } else {
                    ForEach(apps) { app in
                        row(app).transition(.listRow)
                    }
                }
            }
            .listAnimation(apps.map(\.id))
            .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 48)
            .frame(maxWidth: 980).frame(maxWidth: .infinity)
        }
        .navigationTitle("已忽略")
        .accessibilityIdentifier("ignored-applications")
        .inspector(isPresented: $store.libraryInspectorPresented) {
            AppDetailView(store: store).inspectorColumnWidth(min: 300, ideal: 340, max: 420)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.libraryInspectorPresented.toggle() } label: {
                    Label(store.libraryInspectorPresented ? "隐藏详情" : "显示详情", systemImage: "sidebar.trailing")
                }
                .accessibilityIdentifier("toggle-ignored-inspector")
            }
        }
    }

    private func row(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { store.show(app) } label: {
                HStack(spacing: 12) {
                    AppIcon(path: app.path, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.headline)
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "sidebar.trailing").foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("显示应用详情")
            if store.ignored.contains(app.bundleID) {
                rule(title: String(localized: "已忽略所有更新"), symbol: "eye.slash",
                     detail: String(localized: "此应用不会出现在可用更新、全部更新和通知中。")) {
                    Button("恢复更新提醒") { store.toggleIgnored(app) }
                        .accessibilityIdentifier("restore-ignored-" + app.bundleID)
                }
            }
            if store.updatePolicy.hasSkippedVersions(for: app) {
                rule(title: String(localized: "已跳过版本"), symbol: "forward.end",
                     detail: String(localized: "只跳过选定版本，后续新版本仍会提醒。")) {
                    Button("恢复版本提醒") { store.restoreSkippedVersions(for: app) }
                        .accessibilityIdentifier("restore-skipped-" + app.bundleID)
                }
            }
        }
        .card(padding: 16)
        .accessibilityIdentifier("ignored-app-" + app.bundleID)
    }

    private func rule<Action: View>(title: String, symbol: String, detail: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            action().buttonStyle(.bordered).disabled(store.operationBusy)
        }
    }
}
