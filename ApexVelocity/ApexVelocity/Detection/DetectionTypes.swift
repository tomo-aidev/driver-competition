import Foundation
import CoreGraphics

/// Represents a single ball detection from CoreML inference
struct BallDetection: Sendable {
    /// Center position in normalized coordinates (0-1 range, Vision framework output)
    let normalizedCenter: CGPoint
    /// Detection confidence (0-1)
    let confidence: Float
    /// Bounding box in normalized coordinates
    let boundingBox: CGRect
    /// Timestamp of the frame
    let timestamp: CFAbsoluteTime
}

/// A point in the ball's trajectory, converted to screen coordinates
struct TrajectoryPoint: Sendable {
    /// Position in screen/view coordinates
    let position: CGPoint
    /// Timestamp of detection
    let timestamp: CFAbsoluteTime
    /// Opacity for fade effect (1.0 = newest, decreasing for older points)
    var opacity: CGFloat = 1.0
}

/// Configuration constants for detection and trajectory
enum DetectionConfig {
    /// Maximum number of trajectory points to keep
    static let maxTrajectoryPoints = 120
    /// Time after which trajectory points fade out (seconds)
    static let trajectoryFadeTime: TimeInterval = 2.0
    /// Minimum confidence threshold for valid detection
    static let minConfidence: Float = 0.5
    /// Input image size for YOLOv8 inference
    static let inferenceInputSize = CGSize(width: 640, height: 640)
    /// Maximum distance (normalized) between consecutive detections
    /// before treating as a new trajectory
    static let maxPositionJump: CGFloat = 0.3
    /// Trajectory line width in points
    static let trajectoryLineWidth: CGFloat = 8.0
}
