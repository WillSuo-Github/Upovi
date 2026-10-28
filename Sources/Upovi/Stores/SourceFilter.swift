import UpoviCore

enum SourceFilter: String, CaseIterable, Identifiable {
    case all = "全部", incomplete = "检测异常", unsupported = "未适配", appStore = "App Store", ignored = "已忽略"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: String(localized: "全部"); case .incomplete: String(localized: "检测异常"); case .unsupported: String(localized: "未适配")
        case .appStore: "App Store"; case .ignored: String(localized: "已忽略")
        }
    }
    func includes(_ status: SourceStatus?, isAppStore: Bool = false) -> Bool {
        switch self {
        case .all: true
        case .unsupported: status == .unsupported
        case .incomplete: status == .failed || status == .partial
        case .appStore: isAppStore || status == .appStore
        case .ignored: true
        }
    }
}
