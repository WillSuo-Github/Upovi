import Foundation

enum AppManagementGuide: String, Identifiable {
    case accessDenied, settings
    var id: String { rawValue }
}

struct AppManagementAccessCheck: Identifiable, Codable {
    let id: String
    let name: String
    let verified: Bool
    let failure: String?
}

/// Historical evidence, never an authorization capability or permission to install.
struct AppManagementAccessEvidence: Codable {
    let checks: [AppManagementAccessCheck]
    let checkedAt: Date
}
