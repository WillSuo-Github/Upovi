import Foundation

struct CheckHistoryEntry: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let applications: Int
    let updates: Int
    let failed: Int
}
