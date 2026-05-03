import Foundation
import CoreGraphics

/// Persistent record of a golf shot with analysis results.
/// Stored as JSON in the app's Documents directory.
struct ShotRecord: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let videoFileName: String           // relative to shots directory

    // Analysis state
    var analysisStatus: AnalysisStatus
    var analysisProgress: Double        // 0.0 - 1.0

    // Impact
    var impactTimeSeconds: Double?

    // Ball trajectory (normalized 0-1 coordinates)
    var ballTrajectory: [TrajectoryPointRecord]

    // Swing trajectory (normalized 0-1 coordinates)
    var swingTrajectory: [SwingPointRecord]

    // Shot metrics
    var metrics: ShotMetrics?

    // Body pose swing metrics (from VNDetectHumanBodyPose3D)
    var swingMetrics: SwingMetrics?

    // Known ball position from recording target frame (normalized 0-1)
    // Set when user aligns ball in the target frame before recording
    var knownBallPositionX: Double?
    var knownBallPositionY: Double?

    // Thumbnail
    var thumbnailFileName: String?

    // Key frames for analysis review
    var keyFrames: [KeyFrameRecord]

    init(videoFileName: String) {
        self.id = UUID()
        self.createdAt = Date()
        self.videoFileName = videoFileName
        self.analysisStatus = .pending
        self.analysisProgress = 0
        self.ballTrajectory = []
        self.swingTrajectory = []
        self.keyFrames = []
    }
}

enum AnalysisStatus: String, Codable {
    case pending
    case analyzing
    case completed
    case failed
}

struct TrajectoryPointRecord: Codable {
    let x: Double   // normalized 0-1
    let y: Double   // normalized 0-1
    let time: Double // seconds from impact
    let isDetected: Bool // true = actual detection, false = physics prediction
}

struct SwingPointRecord: Codable {
    let x: Double
    let y: Double
    let time: Double
    let phase: String  // "backswing", "downswing", "postImpact"
}

/// A key frame captured during analysis with ball marker overlay
struct KeyFrameRecord: Codable {
    let imageFileName: String   // relative to shots directory
    let time: Double            // seconds from video start
    let label: String           // e.g. "Ball Detected", "Top of Backswing", "Impact", "Impact +0.1s"
    let ballX: Double?          // normalized ball marker X (nil = no marker)
    let ballY: Double?          // normalized ball marker Y
}

struct ShotMetrics: Codable {
    var estimatedLaunchAngle: Double?       // degrees
    var estimatedLaunchDirection: Double?   // degrees (0=straight, +right, -left)
    var estimatedBallSpeed: Double?         // m/s
    var estimatedHeadSpeed: Double?         // m/s (club head speed)
    var estimatedCarryDistance: Double?     // yards
    var estimatedCarryDistanceMeters: Double? // meters
    var detectedFrameCount: Int            // how many frames ball was detected
    var predictedFrameCount: Int           // how many frames were physics-predicted
    var analysisConfidence: Double          // 0-1 overall confidence
}
