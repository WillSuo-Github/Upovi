import Foundation

enum AppManagementGuide: String, Identifiable {
    case firstLaunch, permissionRequired, settings
    var id: String { rawValue }
}
