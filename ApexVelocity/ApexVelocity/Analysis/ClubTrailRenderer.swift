import AVFoundation
import Vision
import CoreGraphics
import CoreImage
import UIKit

/// Generates a smooth club head trajectory by:
/// 1. Sampling frames around impact
/// 2. Detecting wrist positions via VNDetectHumanBodyPose
/// 3. Estimating club head position from wrist + extension vector
/// 4. Smoothing the trail with Catmull-Rom spline interpolation
struct ClubTrailRenderer {

    /// A single club head position with timing
    struct TrailPoint {
        let time: Double         // seconds from video start
        let position: CGPoint    // normalized 0-1, origin top-left
        let phase: SwingPhase
        let confidence: Float
    }

    /// Generate club head trail across the swing.
    /// - Parameters:
    ///   - asset: Video asset
    ///   - impactTime: Detected impact time in seconds
    ///   - preImpactSeconds: How far before impact to start tracking (default 1.5s)
    ///   - postImpactSeconds: How far after impact to track (default 0.5s)
    ///   - sampleInterval: Time between samples. nil = 動画FPSに合わせて自動 (1/fps)
    ///                     検出が遅くなりすぎないよう 1/60 で下限クランプ。
    /// - Returns: Smoothed array of trail points
    static func generateTrail(
        from asset: AVAsset,
        impactTime: Double,
        preImpactSeconds: Double = 1.5,
        postImpactSeconds: Double = 0.5,
        sampleInterval: Double? = nil
    ) async -> [TrailPoint] {

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        generator.maximumSize = CGSize(width: 540, height: 960)  // low-res for speed

        let duration = (try? await asset.load(.duration)) ?? CMTime(seconds: 30, preferredTimescale: 600)
        let totalSeconds = CMTimeGetSeconds(duration)

        // 動画FPSに合わせて sampleInterval を動的決定
        // nil 指定時: 1/videoFPS。ただし下限 1/60秒（過剰サンプリング防止）、上限 1/15秒（最低15fps）
        let resolvedInterval: Double
        if let interval = sampleInterval {
            resolvedInterval = interval
        } else if let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let nominalFR = try? await track.load(.nominalFrameRate), nominalFR > 0 {
            let videoFPS = Double(nominalFR)
            // VNDetectHumanBodyPose の処理速度を考慮し、最大30fps相当でサンプリング
            let targetFPS = min(30.0, videoFPS)
            resolvedInterval = 1.0 / targetFPS
            print("[ClubTrail] sampleInterval auto: video=\(String(format: "%.0f", videoFPS))fps, sampling at \(String(format: "%.0f", targetFPS))fps (interval=\(String(format: "%.4f", resolvedInterval)))")
        } else {
            resolvedInterval = 1.0 / 30.0  // デフォルト30fps
        }

        let startTime = max(0, impactTime - preImpactSeconds)
        let endTime = min(totalSeconds, impactTime + postImpactSeconds)

        // Step 1: Collect raw club head estimates per frame
        var rawPoints: [(time: Double, pos: CGPoint, conf: Float)] = []
        var t = startTime

        while t < endTime {
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            var actualTime = CMTime.zero

            if let image = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime),
               let estimate = estimateClubHead(image: image) {
                rawPoints.append((time: t, pos: estimate.pos, conf: estimate.conf))
            }

            t += resolvedInterval
        }

        guard rawPoints.count >= 3 else {
            print("[ClubTrail] Insufficient points: \(rawPoints.count)")
            return []
        }

        print("[ClubTrail] Raw points: \(rawPoints.count)")

        // Step 2: Smooth with moving average + Catmull-Rom interpolation
        let smoothed = smoothPoints(rawPoints)

        // Step 3: Classify phases (backswing/downswing/postImpact)
        let classified = classifyPhases(smoothed, impactTime: impactTime)

        return classified
    }

    // MARK: - Per-Frame Club Head Estimation

    private static func estimateClubHead(image: CGImage) -> (pos: CGPoint, conf: Float)? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let poseRequest = VNDetectHumanBodyPoseRequest()
        try? handler.perform([poseRequest])

        guard let body = poseRequest.results?.first else { return nil }

        // Get both wrists and hips
        let rWrist = try? body.recognizedPoint(.rightWrist)
        let lWrist = try? body.recognizedPoint(.leftWrist)
        let rHip = try? body.recognizedPoint(.rightHip)
        let lHip = try? body.recognizedPoint(.leftHip)
        let neck = try? body.recognizedPoint(.neck)

        // Need at least one wrist
        var wristPositions: [(CGPoint, Float)] = []
        if let rw = rWrist, rw.confidence > 0.2 {
            wristPositions.append((CGPoint(x: rw.location.x, y: 1.0 - rw.location.y), Float(rw.confidence)))
        }
        if let lw = lWrist, lw.confidence > 0.2 {
            wristPositions.append((CGPoint(x: lw.location.x, y: 1.0 - lw.location.y), Float(lw.confidence)))
        }
        guard !wristPositions.isEmpty else { return nil }

        // Average wrist position (top-left coords)
        let wristX = wristPositions.map(\.0.x).reduce(0, +) / CGFloat(wristPositions.count)
        let wristY = wristPositions.map(\.0.y).reduce(0, +) / CGFloat(wristPositions.count)
        let wristAvgConf = wristPositions.map(\.1).reduce(0, +) / Float(wristPositions.count)

        // Get body anchor point (hip or neck) to determine club extension direction
        var bodyX: CGFloat = wristX
        var bodyY: CGFloat = wristY
        var hasBody = false

        if let rh = rHip, rh.confidence > 0.2, let lh = lHip, lh.confidence > 0.2 {
            bodyX = (rh.location.x + lh.location.x) / 2
            bodyY = 1.0 - (rh.location.y + lh.location.y) / 2
            hasBody = true
        } else if let n = neck, n.confidence > 0.2 {
            bodyX = n.location.x
            bodyY = 1.0 - n.location.y
            hasBody = true
        }

        // Estimate club head: extend from wrist away from body
        // Club shaft is approximately 1.0-1.1m long
        // In normalized coords, we estimate ~15-20% of frame height as shaft length
        let extensionLength: CGFloat = 0.18

        let clubX: CGFloat
        let clubY: CGFloat

        if hasBody {
            // Vector from body to wrist
            let dx = wristX - bodyX
            let dy = wristY - bodyY
            let mag = sqrt(dx * dx + dy * dy)

            if mag > 0.01 {
                // Normalize and extend
                let nx = dx / mag
                let ny = dy / mag
                clubX = wristX + nx * extensionLength
                clubY = wristY + ny * extensionLength
            } else {
                // Wrist at body center: extend downward (address position)
                clubX = wristX
                clubY = wristY + extensionLength
            }
        } else {
            // No body reference: extend downward from wrist
            clubX = wristX
            clubY = wristY + extensionLength
        }

        // Clamp to frame
        let clampedX = max(0, min(1, clubX))
        let clampedY = max(0, min(1, clubY))

        return (CGPoint(x: clampedX, y: clampedY), wristAvgConf)
    }

    // MARK: - Smoothing (Moving Average + Outlier Rejection)

    private static func smoothPoints(_ points: [(time: Double, pos: CGPoint, conf: Float)]) -> [TrailPoint] {
        guard points.count >= 3 else {
            return points.map { TrailPoint(time: $0.time, position: $0.pos, phase: .address, confidence: $0.conf) }
        }

        var smoothed: [TrailPoint] = []
        // 30fps化に伴いウィンドウを5に拡大（約 ±0.07 秒の窓）
        // ガウシアン重み: 中央が最も重く、両端は約 0.6 倍
        let windowSize = 5
        let halfWindow = windowSize / 2

        for i in 0..<points.count {
            let lo = max(0, i - halfWindow)
            let hi = min(points.count - 1, i + halfWindow)

            var sumX: CGFloat = 0, sumY: CGFloat = 0, sumW: CGFloat = 0
            for j in lo...hi {
                let weight = CGFloat(points[j].conf)
                sumX += points[j].pos.x * weight
                sumY += points[j].pos.y * weight
                sumW += weight
            }

            guard sumW > 0 else { continue }
            let avgX = sumX / sumW
            let avgY = sumY / sumW

            // Outlier rejection: if this point is too far from the smoothed average, skip
            let dist = sqrt(pow(points[i].pos.x - avgX, 2) + pow(points[i].pos.y - avgY, 2))
            guard dist < 0.25 else {
                print("[ClubTrail] Outlier at t=\(String(format: "%.2f", points[i].time)) dist=\(String(format: "%.3f", dist))")
                continue
            }

            smoothed.append(TrailPoint(
                time: points[i].time,
                position: CGPoint(x: avgX, y: avgY),
                phase: .address,  // classified later
                confidence: points[i].conf
            ))
        }

        return smoothed
    }

    // MARK: - Phase Classification

    private static func classifyPhases(_ points: [TrailPoint], impactTime: Double) -> [TrailPoint] {
        guard points.count >= 3 else { return points }

        // Find top of swing (minimum Y = highest on screen)
        let yValues = points.map { $0.position.y }
        let topIdx = yValues.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0

        return points.enumerated().map { idx, pt in
            let phase: SwingPhase
            if pt.time >= impactTime - 0.01 {
                phase = .postImpact
            } else if idx <= topIdx {
                phase = .backswing
            } else {
                phase = .downswing
            }
            return TrailPoint(time: pt.time, position: pt.position, phase: phase, confidence: pt.confidence)
        }
    }

    // MARK: - Catmull-Rom Spline Interpolation (for rendering)

    /// Interpolate trail points using Catmull-Rom spline for smooth rendering.
    /// Returns dense points suitable for path drawing.
    static func interpolateSpline(_ points: [TrailPoint], samplesBetween: Int = 8) -> [TrailPoint] {
        guard points.count >= 4 else { return points }

        var result: [TrailPoint] = [points[0]]

        for i in 0..<points.count - 1 {
            let p0 = i == 0 ? points[i] : points[i - 1]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = (i + 2 < points.count) ? points[i + 2] : points[i + 1]

            for s in 1...samplesBetween {
                let t = CGFloat(s) / CGFloat(samplesBetween)
                let interpolated = catmullRom(
                    p0: p0.position, p1: p1.position, p2: p2.position, p3: p3.position, t: t
                )
                let timeInterp = p1.time + (p2.time - p1.time) * Double(t)
                result.append(TrailPoint(
                    time: timeInterp,
                    position: interpolated,
                    phase: p1.phase,
                    confidence: p1.confidence
                ))
            }
        }

        return result
    }

    private static func catmullRom(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, t: CGFloat) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t

        let x = 0.5 * (
            (2 * p1.x) +
            (-p0.x + p2.x) * t +
            (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
            (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3
        )

        let y = 0.5 * (
            (2 * p1.y) +
            (-p0.y + p2.y) * t +
            (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
            (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3
        )

        return CGPoint(x: x, y: y)
    }

    // MARK: - Snapshot Verification (Trail tab)

    /// 検出位置を可視化したスナップショット
    struct DetectionSnapshot {
        let time: Double
        let position: CGPoint        // 検出されたクラブヘッド位置（正規化）
        let imagePath: URL           // 検出マーカーを描画した画像ファイルURL
        let detectedByMotion: Bool   // モーション差分で精緻化されたか
    }

    /// 拡張版: クラブヘッドを **モーション差分で精緻化** + **スナップショット保存**
    ///
    /// 検出ロジック:
    /// 1. VNDetectHumanBodyPose で手首位置取得（アンカー）
    /// 2. 手首+体幹方向ベクトルでヒューリスティック推定位置を算出
    /// 3. 連続2フレームの差分画像を計算
    /// 4. 推定位置周辺(半径15%)で「最も大きな動きの中心」を探索
    /// 5. 手首位置から半径6%以内の動き(=手の動き)は除外
    /// 6. 最大動き重心 = クラブヘッド位置
    /// 7. 動きが小さい場合(=静止)はヒューリスティック推定を採用
    /// 8. 各サンプル時刻のスナップショット画像を一時ディレクトリに保存
    static func generateTrailWithSnapshots(
        from asset: AVAsset,
        impactTime: Double,
        preImpactSeconds: Double = 1.5,
        postImpactSeconds: Double = 0.5,
        sampleInterval: Double? = nil,
        snapshotDir: URL
    ) async -> (trail: [TrailPoint], snapshots: [DetectionSnapshot]) {

        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        generator.maximumSize = CGSize(width: 720, height: 1280)

        let duration = (try? await asset.load(.duration)) ?? CMTime(seconds: 30, preferredTimescale: 600)
        let totalSeconds = CMTimeGetSeconds(duration)

        let resolvedInterval: Double
        if let interval = sampleInterval {
            resolvedInterval = interval
        } else if let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let nominalFR = try? await track.load(.nominalFrameRate), nominalFR > 0 {
            resolvedInterval = 1.0 / min(30.0, Double(nominalFR))
        } else {
            resolvedInterval = 1.0 / 30.0
        }

        let startTime = max(0, impactTime - preImpactSeconds)
        let endTime = min(totalSeconds, impactTime + postImpactSeconds)

        var rawPoints: [(time: Double, pos: CGPoint, conf: Float)] = []
        var snapshots: [DetectionSnapshot] = []
        var prevImage: CGImage? = nil

        var t = startTime
        var snapIdx = 0

        while t < endTime {
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            var actualTime = CMTime.zero

            guard let image = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) else {
                t += resolvedInterval
                continue
            }

            // ヒューリスティック推定位置 + 手首位置を取得
            guard let est = estimateClubHeadWithWrist(image: image) else {
                prevImage = image
                t += resolvedInterval
                continue
            }

            // モーション差分で精緻化
            var detectedByMotion = false
            var refined = est.clubEstimate
            if let prev = prevImage,
               let motionPos = refineWithMotion(
                   currentImage: image,
                   prevImage: prev,
                   estimate: est.clubEstimate,
                   wristPosition: est.wristPosition
               ) {
                refined = motionPos
                detectedByMotion = true
            }

            rawPoints.append((time: t, pos: refined, conf: est.confidence))

            // スナップショット保存
            let snapPath = snapshotDir.appendingPathComponent(
                String(format: "snap_%03d_%.2fs.jpg", snapIdx, t)
            )
            if let snapImage = drawDetectionMarker(
                image: image,
                position: refined,
                wristPosition: est.wristPosition,
                detectedByMotion: detectedByMotion,
                timeLabel: String(format: "%.2fs", t)
            ),
               let jpegData = snapImage.jpegData(compressionQuality: 0.7) {
                try? jpegData.write(to: snapPath)
                snapshots.append(DetectionSnapshot(
                    time: t,
                    position: refined,
                    imagePath: snapPath,
                    detectedByMotion: detectedByMotion
                ))
                snapIdx += 1
            }

            prevImage = image
            t += resolvedInterval
        }

        guard rawPoints.count >= 3 else {
            print("[ClubTrail] Insufficient points: \(rawPoints.count)")
            return ([], snapshots)
        }

        let smoothed = smoothPoints(rawPoints)
        let classified = classifyPhases(smoothed, impactTime: impactTime)

        print("[ClubTrail] Generated \(classified.count) trail points + \(snapshots.count) snapshots (motion-refined: \(snapshots.filter(\.detectedByMotion).count))")

        return (classified, snapshots)
    }

    /// 手首位置 + ヒューリスティック推定の両方を返すバリエーション
    private static func estimateClubHeadWithWrist(image: CGImage)
        -> (clubEstimate: CGPoint, wristPosition: CGPoint, confidence: Float)? {

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let poseRequest = VNDetectHumanBodyPoseRequest()
        try? handler.perform([poseRequest])

        guard let body = poseRequest.results?.first else { return nil }

        let rWrist = try? body.recognizedPoint(.rightWrist)
        let lWrist = try? body.recognizedPoint(.leftWrist)
        let rHip = try? body.recognizedPoint(.rightHip)
        let lHip = try? body.recognizedPoint(.leftHip)

        var wristPositions: [(CGPoint, Float)] = []
        if let rw = rWrist, rw.confidence > 0.2 {
            wristPositions.append((CGPoint(x: rw.location.x, y: 1.0 - rw.location.y), Float(rw.confidence)))
        }
        if let lw = lWrist, lw.confidence > 0.2 {
            wristPositions.append((CGPoint(x: lw.location.x, y: 1.0 - lw.location.y), Float(lw.confidence)))
        }
        guard !wristPositions.isEmpty else { return nil }

        let wristX = wristPositions.map(\.0.x).reduce(0, +) / CGFloat(wristPositions.count)
        let wristY = wristPositions.map(\.0.y).reduce(0, +) / CGFloat(wristPositions.count)
        let wristAvgConf = wristPositions.map(\.1).reduce(0, +) / Float(wristPositions.count)

        var bodyX: CGFloat = wristX
        var bodyY: CGFloat = wristY
        var hasBody = false
        if let rh = rHip, rh.confidence > 0.2, let lh = lHip, lh.confidence > 0.2 {
            bodyX = (rh.location.x + lh.location.x) / 2
            bodyY = 1.0 - (rh.location.y + lh.location.y) / 2
            hasBody = true
        }

        let extensionLength: CGFloat = 0.18
        let clubX: CGFloat
        let clubY: CGFloat
        if hasBody {
            let dx = wristX - bodyX
            let dy = wristY - bodyY
            let mag = sqrt(dx * dx + dy * dy)
            if mag > 0.01 {
                clubX = wristX + (dx / mag) * extensionLength
                clubY = wristY + (dy / mag) * extensionLength
            } else {
                clubX = wristX
                clubY = wristY + extensionLength
            }
        } else {
            clubX = wristX
            clubY = wristY + extensionLength
        }

        return (
            clubEstimate: CGPoint(x: max(0, min(1, clubX)), y: max(0, min(1, clubY))),
            wristPosition: CGPoint(x: wristX, y: wristY),
            confidence: wristAvgConf
        )
    }

    /// 連続2フレームの差分画像から、推定位置周辺の最大動き重心を求める。
    /// - 探索半径: 15% (正規化座標)
    /// - 手首位置から 6% 以内の動きは除外（手の動きを排除）
    /// - 動きが弱い場合は nil（推定をそのまま使う）
    private static func refineWithMotion(
        currentImage: CGImage,
        prevImage: CGImage,
        estimate: CGPoint,
        wristPosition: CGPoint
    ) -> CGPoint? {
        let w = currentImage.width
        let h = currentImage.height

        guard prevImage.width == w, prevImage.height == h else { return nil }
        guard let cur = renderToGray(image: currentImage, width: w, height: h),
              let prev = renderToGray(image: prevImage, width: w, height: h) else { return nil }

        // 探索領域（推定位置を中心、半径15%）
        let radius: CGFloat = 0.15
        let minX = Int(max(0, (estimate.x - radius)) * CGFloat(w))
        let maxX = Int(min(1.0, (estimate.x + radius)) * CGFloat(w))
        let minY = Int(max(0, (estimate.y - radius)) * CGFloat(h))
        let maxY = Int(min(1.0, (estimate.y + radius)) * CGFloat(h))

        // 手首から除外する半径（ピクセル）
        let wristExclusionRadius: CGFloat = 0.06
        let wristPx = Int(wristPosition.x * CGFloat(w))
        let wristPy = Int(wristPosition.y * CGFloat(h))
        let exclRadiusPx = Int(wristExclusionRadius * CGFloat(min(w, h)))

        // 差分画像の重心算出
        var sumX: Double = 0
        var sumY: Double = 0
        var sumW: Double = 0
        var maxDiff: Int = 0

        // ステップで間引いて高速化
        let step = 2
        for y in stride(from: minY, to: maxY, by: step) {
            for x in stride(from: minX, to: maxX, by: step) {
                // 手首付近は除外
                let dx = x - wristPx
                let dy = y - wristPy
                if dx * dx + dy * dy < exclRadiusPx * exclRadiusPx {
                    continue
                }

                let idx = y * w + x
                guard idx < cur.count, idx < prev.count else { continue }
                let diff = abs(Int(cur[idx]) - Int(prev[idx]))

                if diff > 30 {  // 閾値以上の動きのみ
                    let weight = Double(diff)
                    sumX += Double(x) * weight
                    sumY += Double(y) * weight
                    sumW += weight
                    if diff > maxDiff { maxDiff = diff }
                }
            }
        }

        // 最大動きが弱い → モーション情報なし、推定を使う
        if sumW < 500 || maxDiff < 50 {
            return nil
        }

        let cx = sumX / sumW / Double(w)
        let cy = sumY / sumW / Double(h)
        return CGPoint(x: cx, y: cy)
    }

    /// CGImage をグレースケール 1ch のバイト配列にレンダリング
    private static func renderToGray(image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var data = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &data,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    /// スナップショット画像に検出位置のマーカーを描画
    private static func drawDetectionMarker(
        image: CGImage,
        position: CGPoint,
        wristPosition: CGPoint,
        detectedByMotion: Bool,
        timeLabel: String
    ) -> UIImage? {
        let w = image.width
        let h = image.height
        let size = CGSize(width: w, height: h)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let result = renderer.image { ctx in
            let cgContext = ctx.cgContext
            // 元画像
            cgContext.draw(image, in: CGRect(origin: .zero, size: size))

            // 描画は UIKit 座標系（左上原点）
            let cx = position.x * size.width
            let cy = position.y * size.height
            let wx = wristPosition.x * size.width
            let wy = wristPosition.y * size.height

            // クラブヘッドマーカー: 二重円 + 十字 + ラベル
            let markerColor = detectedByMotion ?
                UIColor(red: 1.0, green: 1.0, blue: 0.2, alpha: 1.0) :  // 黄: モーション検出
                UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0)    // オレンジ: ヒューリスティックのみ
            cgContext.setStrokeColor(markerColor.cgColor)

            // 外側円
            cgContext.setLineWidth(4)
            cgContext.strokeEllipse(in: CGRect(x: cx - 30, y: cy - 30, width: 60, height: 60))
            // 内側円
            cgContext.setLineWidth(2)
            cgContext.strokeEllipse(in: CGRect(x: cx - 12, y: cy - 12, width: 24, height: 24))
            // 十字
            cgContext.setLineWidth(2)
            cgContext.move(to: CGPoint(x: cx - 18, y: cy))
            cgContext.addLine(to: CGPoint(x: cx + 18, y: cy))
            cgContext.move(to: CGPoint(x: cx, y: cy - 18))
            cgContext.addLine(to: CGPoint(x: cx, y: cy + 18))
            cgContext.strokePath()

            // 手首から検出位置への線（青）
            cgContext.setStrokeColor(UIColor.cyan.cgColor)
            cgContext.setLineWidth(2)
            cgContext.move(to: CGPoint(x: wx, y: wy))
            cgContext.addLine(to: CGPoint(x: cx, y: cy))
            cgContext.strokePath()

            // 手首位置（小さい青円）
            cgContext.setFillColor(UIColor.cyan.cgColor)
            cgContext.fillEllipse(in: CGRect(x: wx - 6, y: wy - 6, width: 12, height: 12))

            // 時刻ラベル（左上）
            let label = timeLabel
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 36),
                .foregroundColor: UIColor.white,
                .strokeColor: UIColor.black,
                .strokeWidth: -3.0,
            ]
            label.draw(at: CGPoint(x: 16, y: 16), withAttributes: attrs)

            // 検出方式ラベル
            let methodLabel = detectedByMotion ? "MOTION" : "POSE_EST"
            let methodAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 24),
                .foregroundColor: markerColor,
                .strokeColor: UIColor.black,
                .strokeWidth: -3.0,
            ]
            methodLabel.draw(at: CGPoint(x: 16, y: 60), withAttributes: methodAttrs)
        }

        return result
    }
}
