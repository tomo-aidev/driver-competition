import AVFoundation
import CoreImage
import CoreGraphics
import UIKit

/// 動画にクラブ軌跡・ボール弾道・骨格をオーバーレイした動画を書き出す。
///
/// AVAssetExportSession + AVMutableVideoComposition + 自作 CIFilter で実装。
/// AVAssetReader/Writer を直接扱う方式は writer のメモリ管理が不安定だったため、
/// より堅牢な VideoComposition 方式に変更。
final class VideoExporter {

    enum ExportError: Error {
        case invalidAsset
        case noVideoTrack
        case sessionInitFailed
        case exportFailed(String)
    }

    var progressHandler: ((Double) -> Void)?

    /// オーバーレイデータ
    private var clubTrail: [ClubTrailRenderer.TrailPoint] = []
    private var ballTrajectory: [TrajectoryDetector.TrajectoryPoint] = []
    private var poseFrames: [PoseFrameExtractor.PoseFrame] = []
    private var impactTime: Double = 0

    /// オーバーレイ画像のキャッシュ（同じ時刻範囲は再利用）
    private var overlayCache: [Int: CGImage] = [:]
    private let cacheQueue = DispatchQueue(label: "com.apexvelocity.export.cache")

    func exportVideo(
        sourceURL: URL,
        outputURL: URL,
        clubTrail: [ClubTrailRenderer.TrailPoint],
        ballTrajectory: [TrajectoryDetector.TrajectoryPoint] = [],
        impactTime: Double,
        poseFrames: [PoseFrameExtractor.PoseFrame] = []
    ) async throws {

        // データを保持
        self.clubTrail = clubTrail
        self.ballTrajectory = ballTrajectory
        self.poseFrames = poseFrames
        self.impactTime = impactTime
        self.overlayCache.removeAll()

        let asset = AVURLAsset(url: sourceURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)

        // 表示時のサイズ（preferredTransform 適用後）
        let displayedSize: CGSize = {
            let transformed = naturalSize.applying(preferredTransform)
            return CGSize(width: abs(transformed.width), height: abs(transformed.height))
        }()

        print("[VideoExporter] Source: natural=\(naturalSize) displayed=\(displayedSize) @ \(frameRate)fps")

        // === Composition の構築 ===
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.sessionInitFailed
        }

        // 動画トラックをそのままコピー
        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: videoTrack,
            at: .zero
        )
        compositionVideoTrack.preferredTransform = preferredTransform

        // 音声があればコピー
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: audioTrack,
                at: .zero
            )
        }

        // === VideoComposition でオーバーレイ ===
        let videoComposition = AVMutableVideoComposition(asset: composition) { [weak self] request in
            let sourceImage = request.sourceImage
            guard let self else {
                request.finish(with: sourceImage, context: nil)
                return
            }

            let timeSeconds = CMTimeGetSeconds(request.compositionTime)

            // オーバーレイ画像を生成
            let overlay = self.makeOverlayImage(
                size: sourceImage.extent.size,
                time: timeSeconds
            )

            if let overlay = overlay,
               let overlayCI = CIImage(image: overlay) {
                let composited = overlayCI.composited(over: sourceImage)
                request.finish(with: composited, context: nil)
            } else {
                request.finish(with: sourceImage, context: nil)
            }
        }

        // フレームレート設定
        videoComposition.frameDuration = CMTime(value: 1, timescale: max(30, CMTimeScale(frameRate)))
        videoComposition.renderSize = naturalSize  // natural size に揃える
        videoComposition.renderScale = 1.0

        // === ExportSession ===
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.sessionInitFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.videoComposition = videoComposition

        // 進捗監視
        let progressTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)  // 0.2s
                let progress = Double(exportSession.progress)
                await MainActor.run {
                    self?.progressHandler?(progress)
                }
                if exportSession.status == .completed || exportSession.status == .failed || exportSession.status == .cancelled {
                    break
                }
            }
        }

        // エクスポート実行
        await exportSession.export()
        progressTimer.cancel()

        if exportSession.status == .failed {
            let errorMsg = exportSession.error?.localizedDescription ?? "unknown"
            print("[VideoExporter] ❌ Failed: \(errorMsg)")
            throw ExportError.exportFailed(errorMsg)
        }

        if exportSession.status != .completed {
            throw ExportError.exportFailed("status=\(exportSession.status.rawValue)")
        }

        await MainActor.run { [weak self] in
            self?.progressHandler?(1.0)
        }

        print("[VideoExporter] ✅ Exported: \(outputURL.lastPathComponent)")
    }

    // MARK: - Overlay Image Generation

    /// 指定時刻のオーバーレイ画像を生成（透明背景、UIGraphicsImageRenderer 使用）。
    /// UIKit の座標系（左上原点）で描画 → CIImage.composited(over:) で動画フレーム上に合成。
    ///
    /// 注意: VideoComposition は CIImage の bottom-left 原点を使うため、合成後のY軸は
    /// 反転する必要がある。これは UIImage→CIImage 変換時に自動的に処理される。
    private func makeOverlayImage(size: CGSize, time: Double) -> UIImage? {
        // キャッシュキー: 0.05秒単位で量子化
        let cacheKey = Int(time * 20)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false  // 透明背景
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let image = renderer.image { rendererContext in
            let context = rendererContext.cgContext

            // 骨格（現在フレーム）
            if !self.poseFrames.isEmpty,
               let nearestPose = PoseFrameExtractor.nearestPose(in: self.poseFrames, at: time),
               abs(nearestPose.time - time) < 0.15 {
                self.drawSkeletonTopLeft(pose: nearestPose, in: context, size: size)
            }

            // クラブ軌跡（現在時刻まで）
            let visibleClub = self.clubTrail.filter { $0.time <= time }
            if visibleClub.count >= 2 {
                self.drawClubTrailTopLeft(visibleClub, in: context, size: size)
            }

            // ボール弾道（インパクト後）
            if time >= self.impactTime - 0.05 {
                let visibleBall = self.ballTrajectory.filter { $0.time <= time }
                if visibleBall.count >= 2 {
                    self.drawBallTrajectoryTopLeft(visibleBall, in: context, size: size)
                }
            }
        }

        _ = cacheKey  // for future use
        return image
    }

    // MARK: - Drawing (UIKit 座標系: 左上原点)

    /// 骨格を UIKit 座標系で描画（CGContext は UIGraphicsImageRenderer のものを想定）
    private func drawSkeletonTopLeft(pose: PoseFrameExtractor.PoseFrame, in context: CGContext, size: CGSize) {
        let confidenceThreshold: Float = 0.3

        // 線
        for (a, b) in PoseFrameExtractor.skeletonEdges {
            guard let pa = pose.joints[a], pa.confidence >= confidenceThreshold,
                  let pb = pose.joints[b], pb.confidence >= confidenceThreshold else { continue }

            // UIGraphicsImageRenderer の座標系: 左上原点（Y増加は下向き）
            // pose.position は左上原点正規化なのでそのまま使う
            let p1 = CGPoint(x: pa.position.x * size.width, y: pa.position.y * size.height)
            let p2 = CGPoint(x: pb.position.x * size.width, y: pb.position.y * size.height)

            let lineColor = SkeletonRenderer.jointColor(for: a)

            context.setLineCap(.round)
            // グロー
            context.setStrokeColor(lineColor.copy(alpha: 0.3) ?? lineColor)
            context.setLineWidth(10)
            context.move(to: p1)
            context.addLine(to: p2)
            context.strokePath()

            // コア
            context.setStrokeColor(lineColor)
            context.setLineWidth(4)
            context.move(to: p1)
            context.addLine(to: p2)
            context.strokePath()
        }

        // 点
        for joint in PoseFrameExtractor.drawableJoints {
            guard let p = pose.joints[joint], p.confidence >= confidenceThreshold else { continue }

            let cx = p.position.x * size.width
            let cy = p.position.y * size.height
            let color = SkeletonRenderer.jointColor(for: joint)

            context.setFillColor(color.copy(alpha: 0.4) ?? color)
            context.fillEllipse(in: CGRect(x: cx - 12, y: cy - 12, width: 24, height: 24))

            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: cx - 6, y: cy - 6, width: 12, height: 12))

            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
            context.fillEllipse(in: CGRect(x: cx - 2, y: cy - 2, width: 4, height: 4))
        }
    }

    private func drawClubTrailTopLeft(_ points: [ClubTrailRenderer.TrailPoint], in context: CGContext, size: CGSize) {
        guard points.count >= 2 else { return }

        // Catmull-Rom スプラインで密に補間（4点未満なら元の点を使う）
        // samplesBetween=8: 各セグメント間に8点追加 → 描画点数が約9倍に
        let dense: [ClubTrailRenderer.TrailPoint] = points.count >= 4
            ? ClubTrailRenderer.interpolateSpline(points, samplesBetween: 8)
            : points

        // フェーズごとに線分グループ化して、グロー → コアの2パスで描画
        // 各フェーズの色
        func color(for phase: SwingPhase) -> CGColor {
            switch phase {
            case .backswing:  return CGColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.9)
            case .downswing:  return CGColor(red: 0.4, green: 1.0, blue: 0.3, alpha: 0.9)
            case .postImpact: return CGColor(red: 1.0, green: 1.0, blue: 0.2, alpha: 0.9)
            case .address:    return CGColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 0.6)
            }
        }

        // フェーズが変わる位置で線を分割
        var segments: [(phase: SwingPhase, pts: [CGPoint])] = []
        var currentPhase: SwingPhase = dense[0].phase
        var currentPts: [CGPoint] = [CGPoint(x: dense[0].position.x * size.width,
                                             y: dense[0].position.y * size.height)]

        for i in 1..<dense.count {
            let pt = CGPoint(x: dense[i].position.x * size.width,
                             y: dense[i].position.y * size.height)
            if dense[i].phase != currentPhase {
                segments.append((currentPhase, currentPts))
                currentPhase = dense[i].phase
                currentPts = [currentPts.last ?? pt, pt]  // 連続性確保のため前点を引き継ぐ
            } else {
                currentPts.append(pt)
            }
        }
        segments.append((currentPhase, currentPts))

        // 各セグメントを「グロー → コア」の2パスで CGPath として一気に描画
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for seg in segments {
            guard seg.pts.count >= 2 else { continue }
            let path = CGMutablePath()
            path.move(to: seg.pts[0])
            for p in seg.pts.dropFirst() {
                path.addLine(to: p)
            }
            let c = color(for: seg.phase)

            // 1. ワイドグロー（半透明・幅16px）
            context.addPath(path)
            context.setStrokeColor(c.copy(alpha: 0.3) ?? c)
            context.setLineWidth(16)
            context.strokePath()

            // 2. コアライン（不透明・幅8px）
            context.addPath(path)
            context.setStrokeColor(c)
            context.setLineWidth(8)
            context.strokePath()
        }
    }

    private func drawBallTrajectoryTopLeft(_ points: [TrajectoryDetector.TrajectoryPoint], in context: CGContext, size: CGSize) {
        guard points.count >= 2 else { return }

        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]

            let p1 = CGPoint(x: prev.position.x * size.width, y: prev.position.y * size.height)
            let p2 = CGPoint(x: curr.position.x * size.width, y: curr.position.y * size.height)

            let red = CGColor(red: 1.0, green: 0.15, blue: 0.1, alpha: 0.95)

            context.setLineCap(.round)
            // グロー
            context.setStrokeColor(CGColor(red: 1.0, green: 0.3, blue: 0.0, alpha: 0.3))
            context.setLineWidth(20)
            context.move(to: p1)
            context.addLine(to: p2)
            context.strokePath()

            // コア
            context.setStrokeColor(red)
            context.setLineWidth(10)
            context.move(to: p1)
            context.addLine(to: p2)
            context.strokePath()
        }
    }
}
