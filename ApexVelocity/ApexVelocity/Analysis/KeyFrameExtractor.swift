import AVFoundation
import UIKit
import CoreGraphics

/// Extracts key frames from a golf video and saves them with ball marker overlay.
///
/// Each frame is analyzed independently for ball position:
/// - Before impact: constrained area search → zoom verify
/// - After impact: expanding search from last position → prediction
struct KeyFrameExtractor {

    struct KeyFrameSpec {
        let time: Double
        let label: String
        let showBallMarker: Bool
        let isPostImpact: Bool
    }

    /// Extract and save all key frames for a shot.
    /// Ball position is detected PER FRAME, not copied from initial detection.
    static func extractKeyFrames(
        from asset: AVAsset,
        impactTime: Double?,
        ballPosition: CGPoint?,   // initial detection (used as reference, not copied)
        swingDetections: [ClubHeadDetection],
        shotID: UUID,
        saveTo directory: URL
    ) async -> [KeyFrameRecord] {

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        generator.maximumSize = CGSize(width: 1080, height: 1920)

        let duration = (try? await asset.load(.duration)) ?? CMTime(seconds: 30, preferredTimescale: 600)
        let totalSeconds = CMTimeGetSeconds(duration)
        let impact = impactTime ?? totalSeconds * 0.5

        // Build list of key frame specs
        var specs: [KeyFrameSpec] = []

        // Specific timing pattern around impact
        let preOffsets: [Double]  = [-1.5, -1.0, -0.7, -0.5, -0.4, -0.3, -0.2, -0.1]
        let postOffsets: [Double] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.7, 1.0, 1.5]

        // Pre-impact frames
        for offset in preOffsets {
            let t = impact + offset
            guard t >= 0 else { continue }
            specs.append(KeyFrameSpec(
                time: t,
                label: String(format: "%.1fs", offset),
                showBallMarker: true,
                isPostImpact: false
            ))
        }

        // Impact moment
        specs.append(KeyFrameSpec(time: impact, label: "Impact", showBallMarker: true, isPostImpact: false))

        // Post-impact frames
        for offset in postOffsets {
            let t = impact + offset
            guard t <= totalSeconds else { continue }
            specs.append(KeyFrameSpec(
                time: t,
                label: String(format: "+%.1fs", offset),
                showBallMarker: true,
                isPostImpact: true
            ))
        }

        // Sort and deduplicate
        specs.sort { $0.time < $1.time }
        var deduped: [KeyFrameSpec] = []
        for spec in specs {
            if let last = deduped.last, abs(last.time - spec.time) < 0.2 {
                if spec.label.contains("Ball") || spec.label.contains("Top") || spec.label.contains("Impact") {
                    deduped.removeLast()
                    deduped.append(spec)
                }
                continue
            }
            deduped.append(spec)
        }
        specs = deduped

        // Extract frames and detect ball in each
        var records: [KeyFrameRecord] = []
        var lastBallPos: CGPoint? = ballPosition  // seed with initial detection

        for (index, spec) in specs.enumerated() {
            let cmTime = CMTime(seconds: spec.time, preferredTimescale: 600)
            var actualTime = CMTime.zero

            guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) else {
                print("[KeyFrame] Failed to extract frame at \(String(format: "%.2f", spec.time))s")
                continue
            }

            // Detect ball in THIS frame independently
            var frameBallPos: CGPoint? = nil

            if spec.showBallMarker {
                if let detection = BallFinder.detectBallInFrame(
                    image: cgImage,
                    lastPosition: lastBallPos,
                    isPostImpact: spec.isPostImpact
                ) {
                    // Only show if confidence is sufficient
                    if detection.confidence >= 0.5 {
                        frameBallPos = detection.position
                        lastBallPos = detection.position
                        print("[KeyFrame] \(spec.label): ball at (\(String(format: "%.3f", detection.position.x)), \(String(format: "%.3f", detection.position.y))) conf=\(String(format: "%.2f", detection.confidence))")
                    } else {
                        print("[KeyFrame] \(spec.label): low confidence (\(String(format: "%.2f", detection.confidence))), no marker")
                    }
                } else {
                    print("[KeyFrame] \(spec.label): ball not detected, no marker")
                }
            }

            // Run multi-method comparison on every frame for debugging
            let methodResults = BallFinder.compareAllMethods(image: cgImage)

            // Use BEST method result if no per-frame detection
            if frameBallPos == nil, let bestResult = methodResults.first(where: { $0.method == "BEST" }),
               let bestPos = bestResult.position {
                frameBallPos = bestPos
                lastBallPos = bestPos
            }

            // Draw image with all method markers for comparison
            let finalImage: UIImage
            finalImage = drawAllMethodMarkers(on: cgImage, methods: methodResults, confirmedBall: frameBallPos)

            // Save to disk
            let fileName = "\(shotID.uuidString)_keyframe_\(index).jpg"
            let fileURL = directory.appendingPathComponent(fileName)

            if let jpegData = finalImage.jpegData(compressionQuality: 0.85) {
                do {
                    try jpegData.write(to: fileURL)

                    records.append(KeyFrameRecord(
                        imageFileName: fileName,
                        time: spec.time,
                        label: spec.label,
                        ballX: frameBallPos.map { Double($0.x) },
                        ballY: frameBallPos.map { Double($0.y) }
                    ))
                } catch {
                    print("[KeyFrame] Save failed: \(error)")
                }
            }
        }

        print("[KeyFrame] Extracted \(records.count) key frames (\(records.filter { $0.ballX != nil }.count) with ball)")
        return records
    }

    // MARK: - Draw All Method Markers

    private static func drawAllMethodMarkers(
        on cgImage: CGImage,
        methods: [BallFinder.MethodResult],
        confirmedBall: CGPoint?
    ) -> UIImage {
        let width = cgImage.width
        let height = cgImage.height
        let size = CGSize(width: width, height: height)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
            let context = ctx.cgContext

            let markerR: CGFloat = CGFloat(min(width, height)) * 0.02
            let lineW: CGFloat = max(2, markerR * 0.2)
            let fontSize = max(10, CGFloat(width) * 0.012)

            // Draw each method's result with its color
            for result in methods {
                guard let pos = result.position else { continue }
                let x = pos.x * CGFloat(width)
                let y = pos.y * CGFloat(height)
                let color = UIColor(red: result.color.r, green: result.color.g, blue: result.color.b, alpha: 1)

                // Circle marker
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(lineW)
                context.strokeEllipse(in: CGRect(x: x - markerR, y: y - markerR, width: markerR * 2, height: markerR * 2))

                // Center dot
                context.setFillColor(color.cgColor)
                context.fillEllipse(in: CGRect(x: x - 2, y: y - 2, width: 4, height: 4))

                // Label
                let label = "\(result.method) \(String(format: "%.0f%%", result.confidence * 100))"
                let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color
                ]
                let textSize = (label as NSString).size(withAttributes: attrs)
                let bgRect = CGRect(x: x - textSize.width/2 - 4, y: y + markerR + 2, width: textSize.width + 8, height: textSize.height + 2)
                context.setFillColor(UIColor.black.withAlphaComponent(0.7).cgColor)
                context.fill(bgRect)
                (label as NSString).draw(at: CGPoint(x: bgRect.minX + 4, y: bgRect.minY + 1), withAttributes: attrs)
            }

            // Draw confirmed ball marker (large, prominent)
            if let ball = confirmedBall {
                let bx = ball.x * CGFloat(width)
                let by = ball.y * CGFloat(height)
                let bigR = markerR * 1.8
                let green = UIColor(red: 0.792, green: 0.992, blue: 0, alpha: 1)

                context.setStrokeColor(green.cgColor)
                context.setLineWidth(lineW * 1.5)
                context.strokeEllipse(in: CGRect(x: bx - bigR, y: by - bigR, width: bigR * 2, height: bigR * 2))

                // Crosshair
                let crossLen = bigR * 0.6
                context.setLineWidth(max(1, lineW * 0.5))
                context.move(to: CGPoint(x: bx, y: by - crossLen))
                context.addLine(to: CGPoint(x: bx, y: by + crossLen))
                context.strokePath()
                context.move(to: CGPoint(x: bx - crossLen, y: by))
                context.addLine(to: CGPoint(x: bx + crossLen, y: by))
                context.strokePath()

                let ballLabel = "BALL"
                let ballFont = UIFont.systemFont(ofSize: max(12, CGFloat(width) * 0.015), weight: .bold)
                let ballAttrs: [NSAttributedString.Key: Any] = [.font: ballFont, .foregroundColor: green]
                let ballTextSize = (ballLabel as NSString).size(withAttributes: ballAttrs)
                let ballBgRect = CGRect(x: bx - ballTextSize.width/2 - 6, y: by + bigR + 4, width: ballTextSize.width + 12, height: ballTextSize.height + 4)
                context.setFillColor(UIColor.black.withAlphaComponent(0.7).cgColor)
                context.addPath(UIBezierPath(roundedRect: ballBgRect, cornerRadius: ballBgRect.height/2).cgPath)
                context.fillPath()
                (ballLabel as NSString).draw(at: CGPoint(x: ballBgRect.minX + 6, y: ballBgRect.minY + 2), withAttributes: ballAttrs)
            }

            // Legend at top-left (BEST only)
            let legendItems: [(String, UIColor)] = [
                ("BALL", .magenta),
            ]
            let legendFont = UIFont.systemFont(ofSize: max(9, CGFloat(width) * 0.01), weight: .bold)
            var ly: CGFloat = 10
            context.setFillColor(UIColor.black.withAlphaComponent(0.7).cgColor)
            context.fill(CGRect(x: 5, y: 5, width: CGFloat(width) * 0.18, height: CGFloat(legendItems.count) * (fontSize + 4) + 10))
            for (name, color) in legendItems {
                let attrs: [NSAttributedString.Key: Any] = [.font: legendFont, .foregroundColor: color]
                ("● \(name)" as NSString).draw(at: CGPoint(x: 10, y: ly), withAttributes: attrs)
                ly += fontSize + 4
            }
        }
    }

    // MARK: - Draw Ball Marker on Image (legacy)

    private static func drawBallMarker(on cgImage: CGImage, at normalizedPos: CGPoint) -> UIImage {
        let width = cgImage.width
        let height = cgImage.height
        let size = CGSize(width: width, height: height)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))

            let context = ctx.cgContext
            let x = normalizedPos.x * CGFloat(width)
            let y = normalizedPos.y * CGFloat(height)

            let markerRadius: CGFloat = CGFloat(min(width, height)) * 0.03
            let lineWidth: CGFloat = max(2, markerRadius * 0.15)

            // Outer circle
            context.setStrokeColor(UIColor(red: 0.792, green: 0.992, blue: 0, alpha: 1.0).cgColor)
            context.setLineWidth(lineWidth)
            context.strokeEllipse(in: CGRect(
                x: x - markerRadius, y: y - markerRadius,
                width: markerRadius * 2, height: markerRadius * 2
            ))

            // Crosshair
            let crossLen = markerRadius * 0.6
            context.setStrokeColor(UIColor(red: 0.792, green: 0.992, blue: 0, alpha: 0.7).cgColor)
            context.setLineWidth(max(1, lineWidth * 0.5))
            context.move(to: CGPoint(x: x, y: y - crossLen))
            context.addLine(to: CGPoint(x: x, y: y + crossLen))
            context.strokePath()
            context.move(to: CGPoint(x: x - crossLen, y: y))
            context.addLine(to: CGPoint(x: x + crossLen, y: y))
            context.strokePath()

            // Center dot
            context.setFillColor(UIColor(red: 0.792, green: 0.992, blue: 0, alpha: 1.0).cgColor)
            let dotSize = max(3, lineWidth)
            context.fillEllipse(in: CGRect(
                x: x - dotSize / 2, y: y - dotSize / 2,
                width: dotSize, height: dotSize
            ))

            // Label
            let labelText = "BALL"
            let labelFont = UIFont.systemFont(ofSize: max(12, CGFloat(width) * 0.015), weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: UIColor(red: 0.792, green: 0.992, blue: 0, alpha: 1.0)
            ]
            let textSize = (labelText as NSString).size(withAttributes: attrs)
            let labelRect = CGRect(
                x: x - textSize.width / 2 - 6,
                y: y + markerRadius + 4,
                width: textSize.width + 12,
                height: textSize.height + 4
            )
            context.setFillColor(UIColor.black.withAlphaComponent(0.7).cgColor)
            context.addPath(UIBezierPath(roundedRect: labelRect, cornerRadius: labelRect.height / 2).cgPath)
            context.fillPath()

            (labelText as NSString).draw(
                at: CGPoint(x: labelRect.minX + 6, y: labelRect.minY + 2),
                withAttributes: attrs
            )
        }
    }
}
