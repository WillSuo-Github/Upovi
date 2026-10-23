import Foundation

public enum VersionOrder {
    private struct Parsed {
        let numbers: [Int]
        let stage: Int
        let revision: Int
    }

    private static func parse(_ value: String) -> Parsed? {
        let pattern = #"^v?(\d+(?:\.\d+)*)(?:[-. ]?(alpha|a|beta|b|preview|pre|rc)[-. ]?(\d*))?(?:\+[0-9A-Za-z.-]+)?$"#
        guard value.count <= 128, let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let numberRange = Range(match.range(at: 1), in: value) else { return nil }
        let parts = value[numberRange].split(separator: ".").compactMap { Int($0) }
        guard parts.count == value[numberRange].split(separator: ".").count else { return nil }
        let label = Range(match.range(at: 2), in: value).map { String(value[$0]).lowercased() }
        let stage: Int
        switch label {
        case "alpha", "a": stage = 0
        case "beta", "b": stage = 1
        case "preview", "pre": stage = 2
        case "rc": stage = 3
        default: stage = 4
        }
        let revision = Range(match.range(at: 3), in: value).flatMap { Int(value[$0]) } ?? 0
        return Parsed(numbers: parts, stage: stage, revision: revision)
    }

    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        if lhs == rhs { return .orderedSame }
        guard let a = parse(lhs), let b = parse(rhs) else { return nil }
        for index in 0..<max(a.numbers.count, b.numbers.count) {
            let x = index < a.numbers.count ? a.numbers[index] : 0
            let y = index < b.numbers.count ? b.numbers[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        if a.stage != b.stage { return a.stage < b.stage ? .orderedAscending : .orderedDescending }
        if a.revision != b.revision { return a.revision < b.revision ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    public static func isPrerelease(_ version: String) -> Bool { (parse(version)?.stage ?? 4) < 4 }

    public static func isNewer(version: String, build: String = "", than app: InstalledApp) -> Bool {
        if isPrerelease(version) && !isPrerelease(app.version) { return false }
        guard let order = compare(version, app.version) else { return false }
        if order == .orderedDescending { return true }
        guard order == .orderedSame, !build.isEmpty, !app.build.isEmpty else { return false }
        return compare(build, app.build) == .orderedDescending
    }
}
