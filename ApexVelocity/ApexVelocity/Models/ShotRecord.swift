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

    // Thumbnail
    var thumbnailFileName: String?

    init(videoFileName: String) {
        self.id = UUID()
        self.createdAt = Date()
        self.videoFileName = videoFileName
        self.analysisStatus = .pending
        self.analysisProgress = 0
        self.ballTrajectory = []
        self.swingTrajectory = []
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

struct ShotMetrics: Codable {
    var estimatedLaunchAngle: Double?   // degrees
    var estimatedLaunchDirection: Double? // degrees (0=straight, +right, -left)
    var estimatedBallSpeed: Double?      // m/s
    var estimatedCarryDistance: Double?   // meters
    var detectedFrameCount: Int          // how many frames ball was detected
    var predictedFrameCount: Int         // how many frames were physics-predicted
    var analysisConfidence: Double       // 0-1 overall confidence
}
