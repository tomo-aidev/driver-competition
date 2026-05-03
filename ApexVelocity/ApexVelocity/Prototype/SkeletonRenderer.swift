import SwiftUI
import Vision
import CoreGraphics

/// 骨格を描画するレンダラー。
/// CGContext (動画書き出し用) と SwiftUI Canvas (プレビュー用) の両方に対応。
struct SkeletonRenderer {

    // 関節カテゴリごとの色分け
    static func jointColor(for joint: VNHumanBodyPoseObservation.JointName) -> CGColor {
        switch joint {
        case .nose, .leftEye, .rightEye, .leftEar, .rightEar:
            return CGColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 0.95)  // 顔: 黄
        case .leftShoulder, .rightShoulder, .neck:
            return CGColor(red: 1.0, green: 0.5, blue: 0.2, alpha: 0.95)   // 肩: オレンジ
        case .leftElbow, .rightElbow, .leftWrist, .rightWrist:
            return CGColor(red: 0.3, green: 0.9, blue: 1.0, alpha: 0.95)   // 腕: シアン
        case .leftHip, .rightHip:
            return CGColor(red: 1.0, green: 0.4, blue: 0.7, alpha: 0.95)   // 腰: ピンク
        case .leftKnee, .rightKnee, .leftAnkle, .rightAnkle:
            return CGColor(red: 0.5, green: 1.0, blue: 0.4, alpha: 0.95)   // 脚: グリーン
        default:
            return CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.9)
        }
    }

    static func swiftUIColor(for joint: VNHumanBodyPoseObservation.JointName) -> Color {
        switch joint {
        case .nose, .leftEye, .rightEye, .leftEar, .rightEar:
            return Color(red: 1.0, green: 0.85, blue: 0.2)
        case .leftShoulder, .rightShoulder, .neck:
            return Color(red: 1.0, green: 0.5, blue: 0.2)
        case .leftElbow, .rightElbow, .leftWrist, .rightWrist:
            return Color(red: 0.3, green: 0.9, blue: 1.0)
        case .leftHip, .rightHip:
            return Color(red: 1.0, green: 0.4, blue: 0.7)
        case .leftKnee, .rightKnee, .leftAnkle, .rightAnkle:
            return Color(red: 0.5, green: 1.0, blue: 0.4)
        default:
            return Color.white
        }
    }

    // MARK: - CGContext (動画書き出し用)

    /// CGContext (左下原点) に骨格を描画する。動画フレームへの焼き込みに使用。
    /// - Parameters:
    ///   - frame: 描画対象の PoseFrame
    ///   - context: 描画先 (CGContext は左下原点)
    ///   - size: 描画領域のサイズ (ピクセル単位)
    static func drawSkeleton(
        frame: PoseFrameExtractor.PoseFrame,
        in context: CGContext,
        size: CGSize
    ) {
        let confidenceThreshold: Float = 0.3

        // === 1. 骨格の線（エッジ）を描画 ===
        for (a, b) in PoseFrameExtractor.skeletonEdges {
            guard let pa = frame.joints[a], pa.confidence >= confidenceThreshold,
                  let pb = frame.joints[b], pb.confidence >= confidenceThreshold else { continue }

            // 正規化座標（左上原点）→ ピクセル座標（CGContext は左下原点なので Y 反転）
            let x1 = pa.position.x * size.width
            let y1 = (1.0 - pa.position.y) * size.height
            let x2 = pb.position.x * size.width
            let y2 = (1.0 - pb.position.y) * size.height

            // ボディ部位ごとの色（線は両端の関節色の平均ではなく a 側を使用）
            let lineColor = jointColor(for: a)

            // グロー (太くて半透明)
            context.setLineCap(.round)
            context.setStrokeColor(lineColor.copy(alpha: 0.3) ?? lineColor)
            context.setLineWidth(10)
            context.move(to: CGPoint(x: x1, y: y1))
            context.addLine(to: CGPoint(x: x2, y: y2))
            context.strokePath()

            // コア線
            context.setStrokeColor(lineColor)
            context.setLineWidth(4)
            context.move(to: CGPoint(x: x1, y: y1))
            context.addLine(to: CGPoint(x: x2, y: y2))
            context.strokePath()
        }

        // === 2. 関節点（ノード）を描画 ===
        for joint in PoseFrameExtractor.drawableJoints {
            guard let p = frame.joints[joint], p.confidence >= confidenceThreshold else { continue }

            let cx = p.position.x * size.width
            let cy = (1.0 - p.position.y) * size.height

            // 外側のグロー
            context.setFillColor(jointColor(for: joint).copy(alpha: 0.4) ?? jointColor(for: joint))
            context.fillEllipse(in: CGRect(x: cx - 12, y: cy - 12, width: 24, height: 24))

            // コアの点
            context.setFillColor(jointColor(for: joint))
            context.fillEllipse(in: CGRect(x: cx - 6, y: cy - 6, width: 12, height: 12))

            // 中心のホワイトハイライト
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
            context.fillEllipse(in: CGRect(x: cx - 2, y: cy - 2, width: 4, height: 4))
        }
    }

    // MARK: - SwiftUI Canvas (プレビュー用)

    /// SwiftUI Canvas に骨格を描画。リアルタイムプレビュー用。
    static func drawSkeleton(
        frame: PoseFrameExtractor.PoseFrame,
        in context: GraphicsContext,
        size: CGSize
    ) {
        let confidenceThreshold: Float = 0.3

        // === 1. 線 ===
        for (a, b) in PoseFrameExtractor.skeletonEdges {
            guard let pa = frame.joints[a], pa.confidence >= confidenceThreshold,
                  let pb = frame.joints[b], pb.confidence >= confidenceThreshold else { continue }

            // SwiftUI座標系: 左上原点 (frame.position は既に左上原点なので変換不要)
            let p1 = CGPoint(x: pa.position.x * size.width, y: pa.position.y * size.height)
            let p2 = CGPoint(x: pb.position.x * size.width, y: pb.position.y * size.height)

            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)

            let color = swiftUIColor(for: a)

            // グロー
            context.stroke(path, with: .color(color.opacity(0.3)),
                          style: StrokeStyle(lineWidth: 10, lineCap: .round))
            // コア線
            context.stroke(path, with: .color(color),
                          style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }

        // === 2. 点 ===
        for joint in PoseFrameExtractor.drawableJoints {
            guard let p = frame.joints[joint], p.confidence >= confidenceThreshold else { continue }

            let cx = p.position.x * size.width
            let cy = p.position.y * size.height
            let color = swiftUIColor(for: joint)

            // 外側のグロー
            let outer = Path(ellipseIn: CGRect(x: cx - 12, y: cy - 12, width: 24, height: 24))
            context.fill(outer, with: .color(color.opacity(0.4)))

            // コア
            let core = Path(ellipseIn: CGRect(x: cx - 6, y: cy - 6, width: 12, height: 12))
            context.fill(core, with: .color(color))

            // ハイライト
            let highlight = Path(ellipseIn: CGRect(x: cx - 2, y: cy - 2, width: 4, height: 4))
            context.fill(highlight, with: .color(.white.opacity(0.9)))
        }
    }
}
