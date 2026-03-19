import XCTest
@testable import ApexVelocity

final class BallDetectorTests: XCTestCase {

    var detector: BallDetector!

    override func setUp() {
        super.setUp()
        detector = BallDetector()
    }

    override func tearDown() {
        detector = nil
        super.tearDown()
    }

    // MARK: - Initialization

    func testInitialState() {
        XCTAssertNil(detector.latestDetection)
        // Model is not bundled in tests, so mock mode should be active
        XCTAssertFalse(detector.isModelLoaded, "No .mlmodel in test bundle, should use mock mode")
    }

    // MARK: - Mock Detection

    func testMockDetectionProducesResults() {
        let expectation = XCTestExpectation(description: "Mock detection produces a result")

        // Create a minimal pixel buffer for the detect call
        let pixelBuffer = createTestPixelBuffer()
        guard let pixelBuffer else {
            XCTFail("Failed to create test pixel buffer")
            return
        }

        // Mock detection triggers on a 4-second cycle.
        // We need to call detect multiple times to get past the idle phase.
        // The mock starts idle and waits 4 seconds before first flight.
        // For testing, we call detect rapidly and observe the published output.

        var detectionReceived = false
        let cancellable = detector.$latestDetection
            .dropFirst() // skip initial nil
            .compactMap { $0 }
            .sink { detection in
                detectionReceived = true
                XCTAssertGreaterThan(detection.confidence, 0)
                XCTAssertGreaterThanOrEqual(detection.normalizedCenter.x, 0)
                XCTAssertLessThanOrEqual(detection.normalizedCenter.x, 1.0)
                XCTAssertGreaterThanOrEqual(detection.normalizedCenter.y, 0)
                XCTAssertLessThanOrEqual(detection.normalizedCenter.y, 1.0)
                expectation.fulfill()
            }

        // Rapidly call detect to advance mock state
        // The mock idle phase checks `now - lastMockTrigger > 4.0`
        // Since lastMockTrigger starts at 0, the first call should trigger flight immediately
        for _ in 0..<20 {
            detector.detect(pixelBuffer: pixelBuffer)
            // Small delay to allow async processing
            Thread.sleep(forTimeInterval: 0.05)
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertTrue(detectionReceived)
        _ = cancellable // keep alive
    }

    func testMockDetectionParabolicArc() {
        let expectation = XCTestExpectation(description: "Multiple mock detections form arc")

        let pixelBuffer = createTestPixelBuffer()
        guard let pixelBuffer else {
            XCTFail("Failed to create test pixel buffer")
            return
        }

        var detections: [BallDetection] = []
        let cancellable = detector.$latestDetection
            .compactMap { $0 }
            .sink { detection in
                detections.append(detection)
                if detections.count >= 5 {
                    expectation.fulfill()
                }
            }

        // Call detect rapidly
        for _ in 0..<100 {
            detector.detect(pixelBuffer: pixelBuffer)
            Thread.sleep(forTimeInterval: 0.03)
        }

        wait(for: [expectation], timeout: 10.0)

        // Verify detections form a trajectory (x should increase over time)
        if detections.count >= 3 {
            let firstX = detections[0].normalizedCenter.x
            let lastX = detections[detections.count - 1].normalizedCenter.x
            XCTAssertGreaterThan(lastX, firstX, "Ball should move left-to-right in mock mode")
        }

        _ = cancellable
    }

    // MARK: - Reset

    func testReset() {
        let expectation = XCTestExpectation(description: "Reset clears detection")

        let pixelBuffer = createTestPixelBuffer()
        guard let pixelBuffer else {
            XCTFail("Failed to create test pixel buffer")
            return
        }

        // Get a detection first
        let cancellable = detector.$latestDetection
            .dropFirst()
            .compactMap { $0 }
            .first()
            .sink { _ in
                expectation.fulfill()
            }

        for _ in 0..<20 {
            detector.detect(pixelBuffer: pixelBuffer)
            Thread.sleep(forTimeInterval: 0.05)
        }

        wait(for: [expectation], timeout: 5.0)

        // Now reset
        let resetExpectation = XCTestExpectation(description: "Detection becomes nil after reset")
        let resetCancellable = detector.$latestDetection
            .dropFirst()
            .filter { $0 == nil }
            .sink { _ in
                resetExpectation.fulfill()
            }

        detector.reset()
        wait(for: [resetExpectation], timeout: 2.0)

        _ = cancellable
        _ = resetCancellable
    }

    // MARK: - Frame Skipping

    func testFrameSkippingDoesNotCrash() {
        let pixelBuffer = createTestPixelBuffer()
        guard let pixelBuffer else {
            XCTFail("Failed to create test pixel buffer")
            return
        }

        // Rapidly submit many frames — should not crash or deadlock
        for _ in 0..<100 {
            detector.detect(pixelBuffer: pixelBuffer)
        }

        // If we get here without crash/deadlock, the test passes
        XCTAssertTrue(true)
    }

    // MARK: - Helpers

    private func createTestPixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            320, 240,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        return status == kCVReturnSuccess ? pixelBuffer : nil
    }
}
