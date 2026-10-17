import XCTest
@testable import ExtilumeNative

final class RecoveryTimingReportTests: XCTestCase {
    func testReportIncludesAccurateBoundsForEachAssessment() throws {
        let scenarios: [([String], [String])] = [
            (
                ["100", "1000000100", "5000000100", "10000000100"],
                [
                    "故障区间=[100, 1000000100] ns；测量不确定区间宽度=1000000000 ns",
                    "通知观测=5000000100 ns；恢复核验观测=10000000100 ns",
                    "故障至核验观测耗时=[9000000000, 10000000000] ns；故障至核验观测上界满足10秒"
                ]
            ),
            (
                ["100", "1000000100", "9000000100", "11000000101"],
                [
                    "故障区间=[100, 1000000100] ns；测量不确定区间宽度=1000000000 ns",
                    "通知观测=9000000100 ns；恢复核验观测=11000000101 ns",
                    "故障至核验观测耗时=[10000000001, 11000000001] ns；故障至核验观测下界已超过10秒"
                ]
            ),
            (
                ["100", "2000000100", "1000000100", "10000000101"],
                [
                    "故障区间=[100, 2000000100] ns；测量不确定区间宽度=2000000000 ns",
                    "通知观测=1000000100 ns；恢复核验观测=10000000101 ns",
                    "故障至核验观测耗时=[8000000001, 10000000001] ns；核验观测耗时区间跨越10秒，证据不足"
                ]
            )
        ]

        for (arguments, expectedLines) in scenarios {
            let report = try recoveryTimingReport(arguments: arguments)

            XCTAssertTrue(
                report.contains("仅检查给定时间戳；不核实故障、通知归属、实际恢复或时钟来源，不授权停用。"),
                report
            )
            for line in expectedLines {
                XCTAssertTrue(report.contains(line), "Missing \(line) in:\n\(report)")
            }
        }
    }

    func testLateVerificationDoesNotClaimActualRecoveryExceededDeadline() throws {
        // 故障1秒、实际恢复3秒都在人工确认4秒之前；16秒才核验不能证明恢复耗时12秒。
        let report = try recoveryTimingReport(arguments: ["0", "4000000000", "2000000000", "16000000000"])
        XCTAssertTrue(report.contains("故障至核验观测耗时=[12000000000, 16000000000] ns"))
        XCTAssertTrue(report.contains("故障至核验观测下界已超过10秒"))
        XCTAssertTrue(report.contains("观测超时不能证明实际恢复超时"))
    }

    func testRejectsMalformedArgumentsAndInvalidTimestampOrder() {
        let invalidArguments = [
            ["1", "2", "3"],
            ["1", "2", "3", "4", "5"],
            ["1", "x", "3", "4"],
            ["1", "-2", "3", "4"],
            ["1", "18446744073709551616", "3", "4"],
            ["2", "1", "3", "4"],
            ["2", "3", "1", "4"],
            ["1", "2", "4", "3"]
        ]

        for arguments in invalidArguments {
            XCTAssertThrowsError(
                try recoveryTimingReport(arguments: arguments),
                "Accepted invalid arguments: \(arguments)"
            )
        }
    }
}
