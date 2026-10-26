import UpoviCore

enum SourceFilter: String, CaseIterable, Identifiable {
    case all = "所有来源", unsupported = "未适配", incomplete = "检测异常", appStore = "App Store"
    var id: String { rawValue }
    func includes(_ status: SourceStatus?, isAppStore: Bool = false) -> Bool {
        switch self {
        case .all: true
        case .unsupported: status == .unsupported
        case .incomplete: status == .failed || status == .partial
        case .appStore: isAppStore || status == .appStore
        }
    }
}
