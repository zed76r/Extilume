import Foundation
import XCTest
@testable import ExtilumeCore

final class PrimaryLayoutTests: XCTestCase {
    private let originalMain = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let targetDisplay = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    private let thirdDisplay = UUID(uuidString: "00000000-1111-4222-8333-444444444444")!

    func testTranslatesWholeLayoutAndPreservesRelativeCoordinates() throws {
        let original = try makeLayout(
            main: originalMain,
            origins: [
                originalMain: DisplayOrigin(x: 0, y: 0),
                targetDisplay: DisplayOrigin(x: 200, y: -50),
                thirdDisplay: DisplayOrigin(x: -300, y: 80)
            ]
        )

        let translated = try layoutByMakingMain(original, target: targetDisplay)

        XCTAssertEqual(translated.main, targetDisplay)
        XCTAssertEqual(translated.origins[targetDisplay], DisplayOrigin(x: 0, y: 0))
        XCTAssertEqual(translated.origins[originalMain], DisplayOrigin(x: -200, y: 50))
        XCTAssertEqual(translated.origins[thirdDisplay], DisplayOrigin(x: -500, y: 130))
        XCTAssertEqual(
            translated.origins[thirdDisplay]!.x - translated.origins[originalMain]!.x,
            original.origins[thirdDisplay]!.x - original.origins[originalMain]!.x
        )
        XCTAssertEqual(
            translated.origins[thirdDisplay]!.y - translated.origins[originalMain]!.y,
            original.origins[thirdDisplay]!.y - original.origins[originalMain]!.y
        )
    }

    func testAlreadyMainTargetReturnsLayoutUnchanged() throws {
        let original = try makeLayout(
            main: originalMain,
            origins: [originalMain: DisplayOrigin(x: 0, y: 0), targetDisplay: DisplayOrigin(x: 80, y: 20)]
        )

        XCTAssertEqual(try layoutByMakingMain(original, target: originalMain), original)
    }

    func testMissingTargetIsRejected() throws {
        let original = try makeLayout(main: originalMain, origins: [originalMain: DisplayOrigin(x: 0, y: 0)])

        XCTAssertThrowsError(try layoutByMakingMain(original, target: targetDisplay)) { error in
            guard let recoveryError = error as? RecoveryError,
                  case .identityConflict = recoveryError else {
                return XCTFail("Expected missing identity to be rejected")
            }
        }
    }

    func testCoordinateOverflowIsRejected() throws {
        let original = try makeLayout(
            main: originalMain,
            origins: [
                originalMain: DisplayOrigin(x: 0, y: 0),
                targetDisplay: DisplayOrigin(x: Int32.max, y: 0),
                thirdDisplay: DisplayOrigin(x: Int32.min, y: 0)
            ]
        )

        XCTAssertThrowsError(try layoutByMakingMain(original, target: targetDisplay)) { error in
            guard let recoveryError = error as? RecoveryError,
                  case .invalidRecord = recoveryError else {
                return XCTFail("Expected overflowing translation to be rejected")
            }
        }
    }

    private func makeLayout(main: UUID, origins: [UUID: DisplayOrigin]) throws -> DisplayLayout {
        try DisplayLayout(main: main, origins: origins)
    }
}
