import XCTest
@testable import MacMTP

final class TransferProgressTests: XCTestCase {
    func testCountsAccumulateAcrossFiles() {
        let transfer = TransferProgress(title: "Upload")
        transfer.begin(TransferSize(bytes: 1_000, files: 2))
        transfer.update(.file("first"))
        transfer.update(.bytes(300))
        transfer.update(.bytes(100))
        transfer.update(.finishedFile)
        transfer.update(.file("second"))
        transfer.update(.bytes(200))
        let partial = transfer.snapshot()
        XCTAssertEqual(partial.bytes, 600)
        XCTAssertEqual(partial.files, 1)
        XCTAssertEqual(partial.remaining, 400)
        XCTAssertEqual(partial.fraction, 0.6, accuracy: 0.0001)
        XCTAssertEqual(partial.filename, "second")

        transfer.update(.bytes(400))
        transfer.update(.finishedFile)
        transfer.finish()
        transfer.update(.bytes(100))
        let complete = transfer.snapshot()
        XCTAssertEqual(complete.bytes, 1_000)
        XCTAssertEqual(complete.files, 2)
        XCTAssertEqual(complete.remaining, 0)
        XCTAssertEqual(complete.fraction, 1)
    }

    func testFailureRetainsPartialCounts() {
        let transfer = TransferProgress(title: "Download")
        transfer.begin(TransferSize(bytes: 1_000, files: 1))
        transfer.update(.bytes(250))
        transfer.finish(error: CocoaError(.fileWriteOutOfSpace))
        transfer.update(.finishedFile)
        let result = transfer.snapshot()
        guard case .failed = result.phase else { return XCTFail("Expected failure") }
        XCTAssertEqual(result.bytes, 250)
        XCTAssertEqual(result.remaining, 750)
        XCTAssertEqual(result.files, 0)
        XCTAssertEqual(result.fraction, 0.25)
    }

    func testEmptyFolderCompletesWithoutDivisionByZero() {
        let transfer = TransferProgress(title: "Empty folder")
        transfer.begin(TransferSize())
        XCTAssertEqual(transfer.snapshot().fraction, 0)
        transfer.finish()
        XCTAssertEqual(transfer.snapshot().fraction, 1)
        XCTAssertEqual(transfer.snapshot().remaining, 0)
    }

    func testSuccessfulTransferDismissalDeadlineAndFailureRetention() throws {
        let transfer = TransferProgress(title: "Download")
        XCTAssertNil(transfer.snapshot().dismissalDelay(at: 0))
        transfer.begin(TransferSize(bytes: 10, files: 1))
        XCTAssertNil(transfer.snapshot().dismissalDelay(at: 0))
        transfer.finish()
        let snapshot = transfer.snapshot()
        let completed = try XCTUnwrap(snapshot.completedAt)
        XCTAssertEqual(try XCTUnwrap(snapshot.dismissalDelay(at: completed)), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.dismissalDelay(at: completed + 0.5)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.dismissalDelay(at: completed + 1), 0)
        XCTAssertEqual(snapshot.dismissalDelay(at: completed + 2), 0)
        let failed = TransferProgress(title: "Failed")
        failed.finish(error: CocoaError(.fileWriteOutOfSpace))
        XCTAssertNil(failed.snapshot().dismissalDelay(at: completed + 100))
    }

    func testThroughputUsesElapsedTime() {
        var snapshot = TransferProgress.Snapshot()
        snapshot.samples = [(10, 100), (12, 4_000_100)]
        XCTAssertEqual(snapshot.speed, 2_000_000)
    }
}
