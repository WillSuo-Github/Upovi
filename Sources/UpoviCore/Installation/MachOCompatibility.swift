import Foundation

public enum MachOCompatibility {
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
                guard length >= 24, try uint(cursor + 8) == 1 else { throw PeerError.invalid("Unsupported executable platform") }
                minimum = try uint(cursor + 12)
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
