import XCTest
@testable import UpoviCore

final class ApplicationRunningLocationTests: XCTestCase {
    func testNormalLocationRequiresExactInstalledPath() {
        XCTAssertTrue(ApplicationRunningLocation.matches(URL(fileURLWithPath: "/Applications/Fixture.app"), installedPath: "/Applications/Fixture.app"))
        XCTAssertFalse(ApplicationRunningLocation.matches(URL(fileURLWithPath: "/elsewhere/Fixture.app"), installedPath: "/Applications/Fixture.app"))
    }
    func testTranslocatedProcessMustMapToTheExactReadOnlyMountSource() {
        let mount = "/private/var/folders/fixture/T/AppTranslocation/UUID"
        func matches(source: String = "/Applications/Fixture.app", point: String = mount, type: String = "nullfs", readOnly: Bool = true,
                     runtime: String = mount + "/d/Fixture.app") -> Bool {
            ApplicationRunningLocation.matchesTranslocation(runtimePath: runtime, installedPath: "/Applications/Fixture.app",
                source: source, mount: point, fileSystem: type, readOnly: readOnly)
        }
        XCTAssertTrue(matches())
        XCTAssertFalse(matches(source: "/Downloads/Fixture.app"))
        XCTAssertFalse(matches(point: "/Volumes/Fixture"))
        XCTAssertFalse(matches(type: "apfs"))
        XCTAssertFalse(matches(readOnly: false))
        XCTAssertFalse(matches(runtime: mount + "/d/Other.app"))
        XCTAssertFalse(matches(runtime: mount + "/d/Fixture.app/Contents/Helpers/Other.app"))
    }
}
