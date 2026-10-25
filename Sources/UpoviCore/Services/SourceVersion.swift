import Foundation

/// Conservative normalization of known catalog packaging forms, not arbitrary version guessing.
public enum SourceVersion {
    public static func normalize(_ version: String) -> String {
        let value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: #"^[vV]?\d+(?:\.\d+)*-[0-9a-f]{7,40}$"#, options: .regularExpression) {
            return String(value[range]).components(separatedBy: "-")[0]
        }
        if value.range(of: #"^\d+(?:\.\d+)* \(\d+\)$"#, options: .regularExpression) != nil {
            return value.replacingOccurrences(of: " (", with: ".").replacingOccurrences(of: ")", with: "")
        }
        return value
    }
    public static func comparable(_ version: String, installed: String) -> Bool {
        VersionOrder.compare(normalize(version), normalize(installed)) != nil
    }
}
