import XCTest
@testable import ApexVelocity

final class DetectionTypesTests: XCTestCase {

    // MARK: - BallDetection

    func testBallDetectionInitialization() {
        let detection = BallDetection(
            normalizedCenter: CGPoint(x: 0.5, y: 0.3),
            confidence: 0.95,
            boundingBox: CGRect(x: 0.48, y: 0.28, width: 0.04, height: 0.04),
            timestamp: 1000.0
        )

        XCTAssertEqual(detection.normalizedCenter.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(detection.normalizedCenter.y, 0.3, accuracy: 0.001)
        XCTAssertEqual(detection.confidence, 0.95, accuracy: 0.001)
        XCTAssertEqual(detection.boundingBox.width, 0.04, accuracy: 0.001)
        XCTAssertEqual(detection.timestamp, 1000.0, accuracy: 0.001)
    }

    func testBallDetectionNormalizedRange() {
        // Verify edge cases at boundaries of normalized coordinates
        let topLeft = BallDetection(
            normalizedCenter: CGPoint(x: 0.0, y: 0.0),
            confidence: 1.0,
            boundingBox: .zero,
            timestamp: 0
        )
        XCTAssertEqual(topLeft.normalizedCenter.x, 0.0)
        XCTAssertEqual(topLeft.normalizedCenter.y, 0.0)

        let bottomRight = BallDetection(
            normalizedCenter: CGPoint(x: 1.0, y: 1.0),
            confidence: 1.0,
            boundingBox: .zero,
            timestamp: 0
        )
        XCTAssertEqual(bottomRight.normalizedCenter.x, 1.0)
        XCTAssertEqual(bottomRight.normalizedCenter.y, 1.0)
    }

    // MARK: - TrajectoryPoint

    func testTrajectoryPointDefaultOpacity() {
        let point = TrajectoryPoint(
            position: CGPoint(x: 100, y: 200),
            timestamp: 500.0
        )
        XCTAssertEqual(point.opacity, 1.0, "Default opacity should be 1.0")
    }

    func testTrajectoryPointCustomOpacity() {
        var point = TrajectoryPoint(
            position: CGPoint(x: 100, y: 200),
            timestamp: 500.0,
            opacity: 0.5
        )
        XCTAssertEqual(point.opacity, 0.5, accuracy: 0.001)

        point.opacity = 0.3
        XCTAssertEqual(point.opacity, 0.3, accuracy: 0.001)
    }

    // MARK: - DetectionConfig

    func testDetectionConfigValues() {
        XCTAssertEqual(DetectionConfig.maxTrajectoryPoints, 120)
        XCTAssertEqual(DetectionConfig.trajectoryFadeTime, 2.0, accuracy: 0.001)
        XCTAssertEqual(DetectionConfig.minConfidence, 0.5, accuracy: 0.001)
        XCTAssertEqual(DetectionConfig.inferenceInputSize.width, 640)
        XCTAssertEqual(DetectionConfig.inferenceInputSize.height, 640)
        XCTAssertEqual(DetectionConfig.maxPositionJump, 0.3, accuracy: 0.001)
        XCTAssertEqual(DetectionConfig.trajectoryLineWidth, 3.0, accuracy: 0.001)
    }
}
