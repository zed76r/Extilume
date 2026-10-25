import XCTest
import Foundation
@testable import ExtilumeNative
import ExtilumeCore

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

    func testReportUsesOnlyCalculatedSleepEvidenceAndOmitsPrivateIdentifiers() throws {
        let session = UUID()
        let evidence = RecoverySuspensionEvidence(intervals: [
            RecoverySuspensionInterval(
                before: try sample(session, 2_000_000_000, 2_000_000_000, 4_000_000_000),
                after: try sample(session, 20_000_000_000, 4_000_000_000, 22_000_000_000),
                powerEvent: RecoveryPowerEventEvidence(
                    bootSession: session,
                    willSleepAtNanoseconds: 4_000_000_000,
                    didWakeAtNanoseconds: 18_000_000_000
                )
            )
        ])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
        object["deductionNs"] = 999_000_000_000
        let file = try storeEvidence(JSONSerialization.data(withJSONObject: object))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let arguments = try clockArguments(directory: file.deletingLastPathComponent(), sessions: Array(repeating: session, count: 4))
        let report = try recoveryTimingReport(arguments: arguments + ["--suspension-evidence", file.path])
        let raw = try recoveryTimingReport(arguments: [
            "0", "1000000000", "3000000000", "22000000000", "--suspension-evidence", file.path
        ])
        XCTAssertTrue(raw.contains("缺少端点时钟上下文；未从连续耗时中扣除。"), raw)
        XCTAssertFalse(raw.contains("清醒耗时上界满足10秒"), raw)

        XCTAssertTrue(report.contains("休眠时长区间=[13999999998, 18000000002] ns"), report)
        XCTAssertTrue(report.contains("清醒恢复耗时区间=[2999999998, 8000000002] ns；清醒耗时上界满足10秒"), report)
        XCTAssertFalse(report.contains(session.uuidString), report)
        XCTAssertFalse(report.contains(file.path), report)
        XCTAssertFalse(report.contains("999000000000"), report)
    }

    func testMissingOrUnlocatableSuspensionEvidenceIsIgnored() throws {
        let emptyEvidence = RecoverySuspensionEvidence(intervals: [])
        let file = try storeEvidence(JSONEncoder().encode(emptyEvidence))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let report = try recoveryTimingReport(arguments: [
            "0", "1000000000", "9000000000", "11000000001",
            "--suspension-evidence", file.path
        ])

        XCTAssertTrue(report.contains("缺少端点时钟上下文；未从连续耗时中扣除。"), report)
        XCTAssertTrue(report.contains("故障至核验观测耗时=[10000000001, 11000000001] ns；故障至核验观测下界已超过10秒"), report)
        XCTAssertFalse(report.contains(file.path), report)
    }

    func testClockSampleEndpointBootMismatchRejectsApparentlyOrderedTimes() throws {
        let file = try storeEvidence(Data())
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = UUID(), second = UUID()
        let arguments = try clockArguments(directory: file.deletingLastPathComponent(), sessions: [first, second, second, second])
        XCTAssertThrowsError(try recoveryTimingReport(arguments: arguments)) {
            XCTAssertEqual($0 as? RecoveryTimingError, .incomparableClock)
        }
    }

    func testClockSampleWriterUsesPrivateDirectoryAndFileModes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("recovery-clock.json")
        let sample = try sample(UUID(), 1, 2, 3)

        try writeRecoveryClockSample(sample, to: file.path)

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try JSONDecoder().decode(RecoveryClockSample.self, from: Data(contentsOf: file)), sample)
    }

    private func storeEvidence(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("suspension-evidence.json")
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    private func clockArguments(directory: URL, sessions: [UUID]) throws -> [String] {
        let points: [UInt64] = [0, 1_000_000_000, 3_000_000_000, 22_000_000_000]
        var paths: [String] = []
        for (index, point) in points.enumerated() {
            let file = directory.appendingPathComponent("endpoint-\(index).json")
            try writeRecoveryClockSample(sample(sessions[index], point, point, point), to: file.path)
            paths.append(file.path)
        }
        return ["--clock-samples"] + paths
    }

    private func sample(_ session: UUID, _ before: UInt64, _ awake: UInt64, _ after: UInt64) throws -> RecoveryClockSample {
        try RecoveryClockSample(
            bootSession: session,
            continuousBeforeNanoseconds: before,
            awakeNanoseconds: awake,
            continuousAfterNanoseconds: after
        )
    }
}
