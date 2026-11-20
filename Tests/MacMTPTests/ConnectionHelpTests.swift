import XCTest
import USB
import UpdateSupport
@testable import MacMTP

final class ConnectionHelpTests: XCTestCase {
    func testOpenDenialAndInterfaceDenialHaveDifferentGuidance() {
        var diagnostic = MacUSBDiagnostics()
        diagnostic.stage = Int32(MAC_USB_STAGE_OPEN)
        diagnostic.kernel_driver_active = -1
        diagnostic.vendor = 0x18d1
        diagnostic.product = 0x4ee1
        let opening = ConnectionIssue(error: USBOpenFailure(status: -3, diagnostics: diagnostic))
        XCTAssertEqual(opening.kind, .access)
        XCTAssertTrue(opening.details.contains("open device"))
        XCTAssertTrue(opening.details.contains("18d1:4ee1"))

        diagnostic.stage = Int32(MAC_USB_STAGE_CLAIM)
        let claiming = ConnectionIssue(error: USBOpenFailure(status: -3, diagnostics: diagnostic))
        XCTAssertEqual(claiming.kind, .interface)
        XCTAssertTrue(claiming.details.contains("claim interface"))
        XCTAssertFalse(claiming.message.contains("Privacy & Security"), "A claim failure must not be diagnosed as an accessory approval setting.")

        diagnostic.kernel_driver_active = 1
        let driver = ConnectionIssue(error: USBOpenFailure(status: -3, diagnostics: diagnostic))
        XCTAssertEqual(driver.kind, .busy)
        XCTAssertTrue(driver.details.contains("Kernel driver: active"))
    }

    func testWaitingAndOtherFailuresRemainDistinct() {
        XCTAssertEqual(ConnectionIssue(error: DeviceError.unavailable).kind, .waiting)
        XCTAssertEqual(ConnectionIssue(error: DeviceError.transport(-7)).kind, .other)
        XCTAssertFalse(ConnectionIssue.waiting.offersMediaRecovery)
    }

    func testFastRetriesBackOffAndResetAfterUserAction() {
        var policy = ConnectionRetryPolicy()
        for _ in 1...10 {
            policy.failed()
            XCTAssertEqual(policy.delay, .seconds(1))
        }
        for _ in 1...100 { policy.failed() }
        XCTAssertEqual(policy.delay, .seconds(3))
        XCTAssertEqual(policy.failures, 20)
        policy.reset()
        XCTAssertEqual(policy.failures, 0)
        XCTAssertEqual(policy.delay, .seconds(1))
    }

    func testMediaAppsRequireExplicitRecoveryAction() {
        for identifier in ["com.apple.Photos", "com.apple.Image_Capture"] {
            XCTAssertFalse(USBRecoveryPolicy.canQuit(identifier))
            XCTAssertTrue(USBRecoveryPolicy.canQuit(identifier, includingMediaApps: true))
        }
        XCTAssertFalse(USBRecoveryPolicy.canQuit("com.apple.finder", includingMediaApps: true))
        XCTAssertFalse(USBRecoveryPolicy.canQuit("com.google.android.studio", includingMediaApps: true))
    }

    func testNativeUSBDiscoveryReportsCorrectFailureStageAndCleansUp() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let mocks = project.appendingPathComponent("Tests/USBMocks")
        let executable = FileManager.default.temporaryDirectory.appendingPathComponent("USBDiscovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: executable) }
        try UpdateFiles.tool("/usr/bin/xcrun", ["clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
            "-I", mocks.path, "-I", project.appendingPathComponent("Sources/USB/include").path,
            mocks.appendingPathComponent("Discovery.c").path,
            project.appendingPathComponent("Sources/USB/USB.c").path, "-o", executable.path])
        try UpdateFiles.tool(executable.path, [])
    }
}

extension ConnectionHelpTests {
    func testResetTargetRequiresExactDiagnosedDriverConflict() throws {
        var diagnostic = MacUSBDiagnostics()
        diagnostic.stage = Int32(MAC_USB_STAGE_CLAIM)
        diagnostic.kernel_driver_active = 1
        diagnostic.vendor = 0x0e8d
        diagnostic.product = 0x2008
        diagnostic.interface_number = 0
        diagnostic.bus_number = 3
        diagnostic.device_address = 7
        let issue = ConnectionIssue(error: USBOpenFailure(status: -3, diagnostics: diagnostic))
        let target = try XCTUnwrap(issue.resetTarget)
        XCTAssertEqual(target.vendor, 0x0e8d)
        XCTAssertEqual(target.product, 0x2008)
        XCTAssertEqual(target.bus, 3)
        XCTAssertEqual(target.address, 7)
        let native = target.diagnostic
        XCTAssertEqual(native.vendor, diagnostic.vendor)
        XCTAssertEqual(native.device_address, diagnostic.device_address)
        XCTAssertEqual(native.bus_number, diagnostic.bus_number)
        XCTAssertEqual(native.interface_number, 0)
        XCTAssertNil(USBResetTarget(USBOpenFailure(status: -6, diagnostics: diagnostic)))
        diagnostic.stage = Int32(MAC_USB_STAGE_OPEN)
        XCTAssertNil(USBResetTarget(USBOpenFailure(status: -3, diagnostics: diagnostic)))
        diagnostic.stage = Int32(MAC_USB_STAGE_CLAIM)
        diagnostic.kernel_driver_active = 0
        XCTAssertNil(USBResetTarget(USBOpenFailure(status: -3, diagnostics: diagnostic)))
        diagnostic.kernel_driver_active = 1
        diagnostic.device_address = 0
        XCTAssertNil(USBResetTarget(USBOpenFailure(status: -3, diagnostics: diagnostic)))
    }

    func testResetReenumerationWaitsForRediscovery() {
        var diagnostic = MacUSBDiagnostics()
        diagnostic.stage = Int32(MAC_USB_STAGE_RESET)
        diagnostic.reset_attempts = 1
        diagnostic.reset_status = -5
        diagnostic.kernel_driver_active = -1
        let issue = ConnectionIssue(error: USBOpenFailure(status: -5, diagnostics: diagnostic))
        XCTAssertEqual(issue.kind, .waiting)
        XCTAssertNil(issue.resetTarget)
        XCTAssertTrue(issue.details.contains("reset phone USB"))
        XCTAssertTrue(issue.details.contains("USB resets: 1"))
    }

    func testResetDiagnosticsSurviveAnOrdinaryRetry() {
        var diagnostic = MacUSBDiagnostics()
        diagnostic.stage = Int32(MAC_USB_STAGE_RESET)
        diagnostic.reset_attempts = 1
        diagnostic.reset_status = -3
        let reset = USBOpenFailure(status: -3, diagnostics: diagnostic)
        diagnostic.stage = Int32(MAC_USB_STAGE_CLAIM)
        diagnostic.reset_attempts = 0
        diagnostic.reset_status = 0
        let retry = ConnectionIssue(error: USBOpenFailure(status: -3, diagnostics: diagnostic), previousReset: reset.details)
        XCTAssertTrue(retry.report.contains("Previous phone USB reset:"))
        XCTAssertTrue(retry.report.contains("Last reset result: -3"))
    }
}
