import Foundation

enum AppManagementGuide: String, Identifiable {
    case firstLaunch, permissionRequired, settings
    var id: String { rawValue }
}

struct AppManagementAccessCheck: Identifiable {
    let id: String
    let name: String
    let verified: Bool
    let failure: String?
}
