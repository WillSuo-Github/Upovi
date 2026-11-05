import Foundation

public enum MachOCompatibility {
    // Exact Catalyst-to-macOS deployment mappings from Apple MacOSX27.2.sdk SDKSettings.json.
    // Catalyst LC_BUILD_VERSION encodes its iOS-family target, not a macOS version.
    // Unknown targets stay unsupported until reviewed; never subtract a guessed major version.
    private static let catalystMinimumMacOS: [String: String] = [
        "13.1": "10.15",
        "13.2": "10.15.1",
        "13.3": "10.15.2",
        "13.3.1": "10.15.3",
        "13.4": "10.15.4",
        "13.5": "10.15.5",
        "14.0": "11.0",
        "14.1": "11.0",
        "14.2": "11.0",
        "14.3": "11.1",
        "14.4": "11.2",
        "14.5": "11.3",
        "14.6": "11.4",
        "14.7": "11.5",
        "15.0": "12.0",
        "15.2": "12.1",
        "15.3": "12.2",
        "15.4": "12.3",
        "15.5": "12.4",
        "15.6": "12.5",
        "16.0": "13.0",
        "16.1": "13.0",
        "16.2": "13.1",
        "16.3": "13.2",
        "16.4": "13.3",
        "16.5": "13.4",
        "16.6": "13.5",
        "17.0": "14.0",
        "17.1": "14.1",
        "17.2": "14.2",
        "17.3": "14.3",
        "17.4": "14.4",
        "17.5": "14.5",
        "17.6": "14.6",
        "18.0": "15.0",
        "18.1": "15.1",
        "18.2": "15.2",
        "18.3": "15.3",
        "18.4": "15.4",
        "18.5": "15.5",
        "18.6": "15.6",
        "26.0": "26.0",
        "26.1": "26.1",
        "26.2": "26.2",
        "26.3": "26.3",
        "26.4": "26.4",
        "26.5": "26.5",
        "26.6": "26.6",
        "26.6.1": "26.6.1",
        "27.0": "27.0",
        "27.1": "27.2",
        "27.2": "27.2",
    ]
    private static func catalystMacOSMinimum(_ version: UInt64) throws -> UInt64 {
        let major = version >> 16, minor = (version >> 8) & 255, patch = version & 255
        let key = "\(major).\(minor)" + (patch == 0 ? "" : ".\(patch)")
        guard let mapped = catalystMinimumMacOS[key] else {
            throw PeerError.invalid("Cannot determine Mac Catalyst deployment compatibility")
        }
        let parts = mapped.split(separator: ".").compactMap { UInt64($0) }
        return (parts[0] << 16) | ((parts.count > 1 ? parts[1] : 0) << 8) | (parts.count > 2 ? parts[2] : 0)
    }
    public static func validate(_ executable: URL) throws {
        let data = try Data(contentsOf: executable, options: .mappedIfSafe)
        #if arch(arm64)
        let cpu: UInt32 = 0x0100000c
        #else
        let cpu: UInt32 = 0x01000007
        #endif
        try inspect(data, cpu: cpu, os: ProcessInfo.processInfo.operatingSystemVersion)
    }

    static func inspect(_ data: Data, cpu: UInt32, os: OperatingSystemVersion) throws {
        func uint(_ offset: Int, bytes: Int = 4, big: Bool = false) throws -> UInt64 {
            guard offset >= 0, bytes <= 8, offset <= data.count - bytes else { throw PeerError.invalid("Truncated Mach-O executable") }
            var result: UInt64 = 0
            for index in 0..<bytes { result |= UInt64(data[offset + index]) << ((big ? bytes - 1 - index : index) * 8) }
            return result
        }
        var offset = 0
        let magic = try uint(0, big: true)
        if magic == 0xcafebabe || magic == 0xcafebabf {
            let count = try uint(4, big: true), wide = magic == 0xcafebabf
            guard count <= 64 else { throw PeerError.invalid("Invalid universal executable") }
            var match: Int?
            for index in 0..<Int(count) {
                let entry = 8 + index * (wide ? 32 : 20)
                if try uint(entry, big: true) == UInt64(cpu) {
                    let value = try uint(entry + 8, bytes: wide ? 8 : 4, big: true)
                    guard value <= UInt64(Int.max) else { throw PeerError.invalid("Invalid executable offset") }
                    match = Int(value); break
                }
            }
            guard let match else { throw PeerError.invalid("Update does not support this Mac's processor") }
            offset = match
        }
        guard try uint(offset) == 0xfeedfacf, try uint(offset + 4) == UInt64(cpu) else {
            throw PeerError.invalid("Update has no compatible native executable")
        }
        let commands = try uint(offset + 16), size = try uint(offset + 20)
        guard commands <= 10000, size <= 16_000_000, offset <= data.count - 32,
              size <= UInt64(data.count - offset - 32) else { throw PeerError.invalid("Invalid Mach-O load commands") }
        let end = offset + 32 + Int(size)
        var cursor = offset + 32, foundMinimum = false
        for _ in 0..<Int(commands) {
            let command = try uint(cursor), length = try uint(cursor + 4)
            guard length >= 8, length <= UInt64(end - cursor) else { throw PeerError.invalid("Invalid Mach-O command size") }
            var minimum: UInt64?
            if command == 0x32 {
                guard length >= 24 else { throw PeerError.invalid("Invalid executable platform command") }
                switch try uint(cursor + 8) {
                case 1: minimum = try uint(cursor + 12)
                case 6: minimum = try catalystMacOSMinimum(uint(cursor + 12))
                default: throw PeerError.invalid("Unsupported executable platform")
                }
            } else if command == 0x24 {
                guard length >= 16 else { throw PeerError.invalid("Invalid minimum system command") }
                minimum = try uint(cursor + 8)
            }
            if let minimum {
                let major = Int(minimum >> 16), minor = Int((minimum >> 8) & 255), patch = Int(minimum & 255)
                let compatible = (major < os.majorVersion) || (major == os.majorVersion && minor < os.minorVersion) ||
                    (major == os.majorVersion && minor == os.minorVersion && patch <= os.patchVersion)
                guard compatible else { throw PeerError.invalid("Update executable requires a newer macOS version") }
                foundMinimum = true
            }
            cursor += Int(length)
        }
        guard foundMinimum else { throw PeerError.invalid("Cannot determine update executable compatibility") }
    }
}
