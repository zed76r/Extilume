import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

private final class SettingsInputControllerStub: ExternalDisplayInputControlling {
    var availabilityResult: ExternalDisplayInputAvailability = .available
    var readCount = 0
    var writeCount = 0

    func availability(for target: ExternalDisplayIdentity) -> ExternalDisplayInputAvailability {
        availabilityResult
    }

    func readCapabilities(for target: ExternalDisplayIdentity,
                          deadlineNanoseconds: UInt64) throws -> ExternalDisplayInputCapabilities {
        readCount += 1
        return ExternalDisplayInputCapabilities(target: target, inputValues: [0x0F, 0x11, 0x12])
    }

    func sendOnce(_ configuration: ExternalDisplayInputConfiguration,
                  capabilities: ExternalDisplayInputCapabilities,
                  deadlineNanoseconds: UInt64) throws {
        writeCount += 1
    }
}

@MainActor
final class ExternalDisplayInputSettingsTests: XCTestCase {

    func testDefaultsAreOffAndUnacceptedConnectionHasNoOptions() throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = SettingsInputControllerStub()
        let settings = ExternalDisplayInputSettings(defaults: defaults, inputController: controller)

        XCTAssertEqual(settings.inputOptions, [])
        XCTAssertNil(settings.selectedPCInput)
        XCTAssertFalse(settings.automaticInputEnabled)
        XCTAssertEqual(settings.inputUnavailableReason, "当前连接尚未验收自动输入源切换")
        XCTAssertNil(settings.automaticSession)
        XCTAssertEqual(controller.readCount, 0)
        XCTAssertEqual(controller.writeCount, 0)
    }

    func testAcceptedCapabilitiesRequireExplicitSupportedInputBeforeEnabling() throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let target = makeTarget()
        let capabilities = ExternalDisplayInputCapabilities(target: target, inputValues: [0x12, 0x0F, 0x11])
        let controller = SettingsInputControllerStub()
        let settings = ExternalDisplayInputSettings(
            defaults: defaults, capabilities: capabilities, inputController: controller
        )
        var changes = 0
        settings.inputSettingsDidChange = { changes += 1 }

        XCTAssertEqual(settings.inputOptions, [0x0F, 0x11, 0x12])
        XCTAssertNil(settings.inputUnavailableReason)
        XCTAssertNil(settings.selectedPCInput)
        XCTAssertFalse(settings.automaticInputEnabled)
        XCTAssertNil(settings.automaticSession)

        settings.selectPCInput(0x10)
        settings.setAutomaticInput(true)
        XCTAssertNil(settings.selectedPCInput)
        XCTAssertFalse(settings.automaticInputEnabled)
        XCTAssertEqual(changes, 0)

        settings.selectPCInput(0x11)
        XCTAssertEqual(settings.selectedPCInput, 0x11)
        XCTAssertFalse(settings.automaticInputEnabled)
        settings.setAutomaticInput(true)
        XCTAssertTrue(settings.automaticInputEnabled)
        let session = try XCTUnwrap(settings.automaticSession)
        XCTAssertEqual(session.configuration.target, target)
        XCTAssertEqual(session.configuration.pcInput, 0x11)
        XCTAssertTrue(session.configuration.automaticEnabled)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(controller.readCount, 0)
        XCTAssertEqual(controller.writeCount, 0)
    }

    func testPreferencesFollowUUIDEDIDAndRegistryPathButNotBootOrNumericID() throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let uuid = UUID()
        let original = makeTarget(uuid: uuid, edidUUID: "edid-a", registryPath: "IOService:/display/a")
        let controller = SettingsInputControllerStub()
        let settings = ExternalDisplayInputSettings(
            defaults: defaults,
            capabilities: ExternalDisplayInputCapabilities(target: original, inputValues: [0x11]),
            inputController: controller
        )
        settings.selectPCInput(0x11)
        settings.setAutomaticInput(true)

        let samePhysicalTargetAfterBoot = makeTarget(
            uuid: uuid, edidUUID: "edid-a", registryPath: "IOService:/display/a"
        )
        let rebooted = ExternalDisplayInputSettings(
            defaults: defaults,
            capabilities: ExternalDisplayInputCapabilities(target: samePhysicalTargetAfterBoot, inputValues: [0x11]),
            inputController: controller
        )
        XCTAssertEqual(rebooted.selectedPCInput, 0x11)
        XCTAssertTrue(rebooted.automaticInputEnabled)

        for other in [
            makeTarget(uuid: uuid, edidUUID: "edid-b", registryPath: "IOService:/display/a"),
            makeTarget(uuid: uuid, edidUUID: "edid-a", registryPath: "IOService:/display/b"),
            makeTarget(edidUUID: "edid-a", registryPath: "IOService:/display/a")
        ] {
            let isolated = ExternalDisplayInputSettings(
                defaults: defaults,
                capabilities: ExternalDisplayInputCapabilities(target: other, inputValues: [0x11]),
                inputController: controller
            )
            XCTAssertNil(isolated.selectedPCInput)
            XCTAssertFalse(isolated.automaticInputEnabled)
            XCTAssertNil(isolated.automaticSession)
        }
    }

    func testControllerAvailabilityAndCapabilityValidationBothGateSettings() throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let target = makeTarget()
        let controller = SettingsInputControllerStub()
        controller.availabilityResult = .unavailable(.hardwareAcceptanceRequired)
        let unavailable = ExternalDisplayInputSettings(
            defaults: defaults,
            capabilities: ExternalDisplayInputCapabilities(target: target, inputValues: [0x11]),
            inputController: controller
        )

        XCTAssertEqual(unavailable.inputOptions, [])
        XCTAssertEqual(unavailable.inputUnavailableReason, "当前连接尚未验收自动输入源切换")
        unavailable.selectPCInput(0x11)
        unavailable.setAutomaticInput(true)
        XCTAssertNil(unavailable.selectedPCInput)
        XCTAssertFalse(unavailable.automaticInputEnabled)
        XCTAssertNil(unavailable.automaticSession)

        controller.availabilityResult = .available
        let invalidCapabilities = ExternalDisplayInputSettings(
            defaults: defaults,
            capabilities: ExternalDisplayInputCapabilities(target: target, inputValues: [0x100]),
            inputController: controller
        )
        XCTAssertEqual(invalidCapabilities.inputOptions, [])
        XCTAssertTrue(try XCTUnwrap(invalidCapabilities.inputUnavailableReason).contains("能力"))
        invalidCapabilities.selectPCInput(0x11)
        XCTAssertFalse(invalidCapabilities.automaticInputEnabled)
        XCTAssertNil(invalidCapabilities.automaticSession)
        XCTAssertEqual(controller.readCount, 0)
        XCTAssertEqual(controller.writeCount, 0)
    }

    func testPersistenceFailureClosesSettingsAndAutomaticSession() throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let target = makeTarget()
        let controller = SettingsInputControllerStub()
        let capabilities = ExternalDisplayInputCapabilities(target: target, inputValues: [0x11, 0x12])
        let accepted = ExternalDisplayInputSettings(
            defaults: defaults, capabilities: capabilities, inputController: controller
        )
        accepted.selectPCInput(0x11)
        accepted.setAutomaticInput(true)
        XCTAssertTrue(accepted.automaticInputEnabled)
        let settings = ExternalDisplayInputSettings(
            defaults: defaults,
            capabilities: capabilities,
            inputController: controller,
            synchronize: { false }
        )
        var changes = 0
        settings.inputSettingsDidChange = { changes += 1 }

        settings.selectPCInput(0x12)
        XCTAssertEqual(settings.inputOptions, [])
        XCTAssertNil(settings.selectedPCInput)
        XCTAssertFalse(settings.automaticInputEnabled)
        XCTAssertNil(settings.automaticSession)
        XCTAssertTrue(try XCTUnwrap(settings.inputUnavailableReason).contains("无法保存"))
        settings.setAutomaticInput(true)
        XCTAssertFalse(settings.automaticInputEnabled)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(controller.writeCount, 0)

        let recreated = ExternalDisplayInputSettings(
            defaults: defaults, capabilities: capabilities, inputController: controller
        )
        XCTAssertFalse(recreated.automaticInputEnabled)
        XCTAssertNil(recreated.automaticSession)
    }

    func testResultTextSeparatesInputCodeReadbackFromPCPicture() throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ExternalDisplayInputSettings(defaults: defaults)
        var changes = 0
        settings.inputSettingsDidChange = { changes += 1 }

        settings.recordResult(.confirmed)
        XCTAssertTrue(try XCTUnwrap(settings.inputResultText).contains("读回"))
        XCTAssertTrue(try XCTUnwrap(settings.inputResultText).contains("PC 画面尚未确认"))
        settings.recordResult(.unconfirmed)
        XCTAssertTrue(try XCTUnwrap(settings.inputResultText).contains("输入码读回未确认"))
        XCTAssertTrue(try XCTUnwrap(settings.inputResultText).contains("PC 画面未确认"))
        settings.recordResult(.unavailable)
        XCTAssertTrue(try XCTUnwrap(settings.inputResultText).contains("自动输入源切换不可用"))
        XCTAssertTrue(try XCTUnwrap(settings.inputResultText).contains("PC 画面未确认"))
        XCTAssertEqual(changes, 3)
    }

    private func preferences() throws -> (String, UserDefaults) {
        let name = "ExtilumeInputSettings.\(UUID().uuidString)"
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)))
    }

    private func makeTarget(uuid: UUID = UUID(), edidUUID: String = "test-edid",
                            registryPath: String = "IOService:/display/1") -> ExternalDisplayIdentity {
        ExternalDisplayIdentity(
            uuid: uuid, registryPath: registryPath, edidUUID: edidUUID,
            bootSession: UUID(), registryEntryID: UInt64.random(in: 1...UInt64.max)
        )
    }
}
