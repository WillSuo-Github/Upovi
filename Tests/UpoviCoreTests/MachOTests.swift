import XCTest
@testable import UpoviCore

final class MachOTests: XCTestCase {
    private func binary(cpu: UInt32, minimum: UInt32, platform: UInt32 = 1) -> Data {
        let values: [UInt32] = [0xfeedfacf, cpu, 0, 2, 1, 24, 0, 0, 0x32, 24, platform, minimum, minimum, 0]
        return values.reduce(into: Data()) { data, number in
            data.append(contentsOf: (0..<4).map { UInt8((number >> ($0 * 8)) & 255) })
        }
    }
    func testRejectsWrongArchitectureAndNewerOS() {
        let data = binary(cpu: 0x0100000c, minimum: 14 << 16)
        let os = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        XCTAssertNoThrow(try MachOCompatibility.inspect(data, cpu: 0x0100000c, os: os))
        XCTAssertThrowsError(try MachOCompatibility.inspect(data, cpu: 0x01000007, os: os))
        XCTAssertThrowsError(try MachOCompatibility.inspect(binary(cpu: 0x0100000c, minimum: 15 << 16), cpu: 0x0100000c, os: os))
        XCTAssertThrowsError(try MachOCompatibility.inspect(Data(data.prefix(40)), cpu: 0x0100000c, os: os))
    }
    func testMacCatalystUsesReviewedDeploymentMappingRatherThanMacOSVersionComparison() {
        // Catalyst 18.5 runs on macOS 15.5, not macOS 18.5. Patch-level mappings also matter.
        for (target, minimum) in [(UInt32(18 << 16 | 5 << 8), OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 0)),
                                  (UInt32(13 << 16 | 3 << 8 | 1), OperatingSystemVersion(majorVersion: 10, minorVersion: 15, patchVersion: 3)),
                                  (UInt32(27 << 16 | 1 << 8), OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0))] {
            let data = binary(cpu: 0x0100000c, minimum: target, platform: 6)
            XCTAssertNoThrow(try MachOCompatibility.inspect(data, cpu: 0x0100000c, os: minimum))
            let older = minimum.patchVersion > 0
                ? OperatingSystemVersion(majorVersion: minimum.majorVersion, minorVersion: minimum.minorVersion, patchVersion: minimum.patchVersion - 1)
                : OperatingSystemVersion(majorVersion: minimum.majorVersion, minorVersion: minimum.minorVersion - 1, patchVersion: 0)
            XCTAssertThrowsError(try MachOCompatibility.inspect(data, cpu: 0x0100000c, os: older))
        }
    }
    func testUnknownCatalystIOSSimulatorAndDriverKitTargetsRemainRejected() {
        let os = OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)
        for (platform, minimum) in [(UInt32(6), UInt32(28 << 16)), (6, 17 << 16 | 9 << 8), (2, 13 << 16), (7, 13 << 16), (10, 13 << 16)] {
            XCTAssertThrowsError(try MachOCompatibility.inspect(binary(cpu: 0x0100000c, minimum: minimum, platform: platform), cpu: 0x0100000c, os: os))
        }
    }
}
