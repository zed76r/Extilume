import Foundation
import XCTest
@testable import ExtilumeNative

final class ConnectionTimingMarkersTests: XCTestCase {
    func testRecordsOrderedManualMarkersWithoutRoundingTimestamps() throws {
        struct Marker: Decodable {
            let type: String
            let clock: String
            let action: String
            let continuousNs: UInt64
        }
        var markers = ConnectionTimingMarkers()
        let actions: [ConnectionTimingAction] = [.armUnplug, .confirmUnplug, .armReconnect, .confirmReconnect]
        let times: [UInt64] = [0, 1, UInt64.max - 1, UInt64.max]
        XCTAssertFalse(markers.isComplete)
        for (index, pair) in zip(actions, times).enumerated() {
            let data = Data(try markers.record(pair.0, at: pair.1).utf8)
            let marker = try JSONDecoder().decode(Marker.self, from: data)
            XCTAssertEqual(marker.type, "manual-connection-marker")
            XCTAssertEqual(marker.clock, "mach_continuous_time/ns")
            XCTAssertEqual(marker.action, actions[index].rawValue)
            XCTAssertEqual(marker.continuousNs, times[index])
            XCTAssertEqual(markers.isComplete, index == 3)
        }
        XCTAssertThrowsError(try markers.record(.armUnplug, at: UInt64.max))
        XCTAssertEqual(markers.count, 4)
    }

    func testRejectedOrderOrClockRegressionDoesNotConsumeTheNextMarker() throws {
        var markers = ConnectionTimingMarkers()
        XCTAssertThrowsError(try markers.record(.confirmUnplug, at: 10))
        XCTAssertEqual(markers.count, 0)
        _ = try markers.record(.armUnplug, at: 10)
        XCTAssertThrowsError(try markers.record(.armUnplug, at: 10))
        XCTAssertThrowsError(try markers.record(.armReconnect, at: 11))
        XCTAssertThrowsError(try markers.record(.confirmUnplug, at: 9))
        XCTAssertEqual(markers.count, 1)
        // 相同纳秒合法，不以等待时间猜测物理动作是否完成。
        _ = try markers.record(.confirmUnplug, at: 10)
        _ = try markers.record(.armReconnect, at: 10)
        _ = try markers.record(.confirmReconnect, at: 10)
        XCTAssertTrue(markers.isComplete)
    }
}
