import XCTest
@testable import UpoviCore

final class MachOTests: XCTestCase {
    private func binary(cpu: UInt32, minimum: UInt32) -> Data {
        let values: [UInt32] = [0xfeedfacf, cpu, 0, 2, 1, 24, 0, 0, 0x32, 24, 1, minimum, minimum, 0]
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
}
