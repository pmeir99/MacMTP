import XCTest
@testable import MacMTP

final class USBRecoveryTests: XCTestCase {
    func testOnlyKnownAndroidTransferAppsCanBeQuit() {
        XCTAssertTrue(USBRecoveryPolicy.canQuit("com.google.android.mtpviewer"))
        XCTAssertTrue(USBRecoveryPolicy.canQuit("com.google.android.mtpagent"))
        XCTAssertTrue(USBRecoveryPolicy.canQuit("io.ganeshrvel.openmtp"))
        XCTAssertFalse(USBRecoveryPolicy.canQuit("com.apple.finder"))
        XCTAssertFalse(USBRecoveryPolicy.canQuit("com.apple.Photos"))
        XCTAssertFalse(USBRecoveryPolicy.canQuit("com.meir.macmtp"))
        XCTAssertFalse(USBRecoveryPolicy.canQuit("com.google.android.studio"))
        XCTAssertFalse(USBRecoveryPolicy.canQuit("example.io.ganeshrvel.openmtp"))
        XCTAssertFalse(USBRecoveryPolicy.canQuit(nil))
    }

    func testUSBBusyAndPermissionErrorsAreDistinct() {
        guard case .interfaceBusy = DeviceError.openingUSB(-6) else {
            return XCTFail("An occupied USB interface must be reported as busy")
        }
        guard case .usbAccessDenied = DeviceError.openingUSB(-3) else {
            return XCTFail("Access denial must point to macOS permissions")
        }
        guard case .unavailable = DeviceError.openingUSB(-4) else {
            return XCTFail("An absent device must not be reported as a conflict")
        }
        guard case .transport(-1) = DeviceError.openingUSB(-1) else {
            return XCTFail("Other USB errors must be preserved")
        }
    }
}

