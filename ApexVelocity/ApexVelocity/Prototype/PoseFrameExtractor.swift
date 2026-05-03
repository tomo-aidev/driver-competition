import AVFoundation
import Vision
import CoreGraphics

/// 動画の各フレームから人物の骨格（関節座標）を抽出するサービス。
///
/// 設計方針:
/// - VNDetectHumanBodyPoseRequest で17関節を検出
/// - 各フレームの結果を時系列配列として保持し、後段の描画・MVVM層に提供
/// - メインスレッドをブロックしないよう async/await で実行
/// - パフォーマンス: 動画FPSではなく低解像度（540x960）で間引きサンプリング
struct PoseFrameExtractor {

    /// 1フレーム分の骨格データ
    struct PoseFrame {
        /// 動画開始からの経過秒数
        let time: Double
        /// 関節名 → 正規化座標 (0-1, 左上原点) と信頼度
        let joints: [VNHumanBodyPoseObservation.JointName: JointPoint]
    }

    /// 1関節の検出結果
    struct JointPoint {
        let position: CGPoint  // 正規化座標、左上原点
        let confidence: Float
    }

    /// 描画対象とする骨格の接続定義（点と線で繋ぐ関節ペア）
    /// MediaPipe風のスケルトン構造をAppleの命名で表現
    static let skeletonEdges: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
        // 頭部
        (.nose, .leftEye), (.nose, .rightEye),
        (.leftEye, .leftEar), (.rightEye, .rightEar),
        // 上半身
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        // 体幹
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftHip, .rightHip),
        // 下半身
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle)
    ]

    /// 骨格点の描画対象関節（visibility threshold 0.3 以上を描画）
    static let drawableJoints: [VNHumanBodyPoseObservation.JointName] = [
        .nose, .leftEye, .rightEye, .leftEar, .rightEar,
        .neck,
        .leftShoulder, .rightShoulder,
        .leftElbow, .rightElbow,
        .leftWrist, .rightWrist,
        .leftHip, .rightHip,
        .leftKnee, .rightKnee,
        .leftAnkle, .rightAnkle
    ]

    /// 動画から骨格データを時系列で抽出する。
    /// - Parameters:
    ///   - asset: 解析対象の動画
    ///   - sampleInterval: サンプリング間隔（秒）。小さいほど滑らかだが処理時間増。
    /// - Returns: フレーム順に並んだ PoseFrame 配列
    static func extractPoses(
        from asset: AVAsset,
        sampleInterval: Double = 0.05  // 20fps相当
    ) async -> [PoseFrame] {

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        // 推論速度を上げるため低解像度に縮小
        generator.maximumSize = CGSize(width: 540, height: 960)

        let duration = (try? await asset.load(.duration)) ?? CMTime(seconds: 30, preferredTimescale: 600)
        let totalSeconds = CMTimeGetSeconds(duration)

        var frames: [PoseFrame] = []
        var t = 0.0

        // VNSequenceRequestHandler を使うと連続フレーム間でモデルがキャッシュされ高速
        // ただし pose estimation は state を持たないため、ここでは VNImageRequestHandler でも同等
        while t < totalSeconds {
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            var actualTime = CMTime.zero

            guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) else {
                t += sampleInterval
                continue
            }

            // Vision の骨格推定リクエストを実行
            let request = VNDetectHumanBodyPoseRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                // エラー時はそのフレームをスキップして処理継続（クラッシュしない）
                print("[PoseExtractor] Frame \(t)s: \(error.localizedDescription)")
                t += sampleInterval
                continue
            }

            guard let observation = request.results?.first else {
                // 人物未検出のフレームはスキップ
                t += sampleInterval
                continue
            }

            // 全関節の座標と信頼度を取得
            var joints: [VNHumanBodyPoseObservation.JointName: JointPoint] = [:]
            for jointName in drawableJoints {
                if let point = try? observation.recognizedPoint(jointName), point.confidence > 0.1 {
                    // Vision座標系: 左下原点・正規化 → 左上原点に変換
                    let topLeftPoint = CGPoint(x: point.location.x, y: 1.0 - point.location.y)
                    joints[jointName] = JointPoint(position: topLeftPoint, confidence: point.confidence)
                }
            }

            if !joints.isEmpty {
                frames.append(PoseFrame(time: t, joints: joints))
            }

            t += sampleInterval
        }

        print("[PoseExtractor] Extracted \(frames.count) pose frames over \(String(format: "%.1f", totalSeconds))s")
        return frames
    }

    /// 指定時刻に最も近い PoseFrame を取得（プレビュー再生時のスケルトン描画用）
    static func nearestPose(in frames: [PoseFrame], at time: Double) -> PoseFrame? {
        guard !frames.isEmpty else { return nil }

        // 二分探索で最近傍を取得
        var lo = 0, hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].time < time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        let candidate = frames[lo]
        // 前後どちらが近いか判定
        if lo > 0 && abs(frames[lo - 1].time - time) < abs(candidate.time - time) {
            return frames[lo - 1]
        }
        return candidate
    }
}
