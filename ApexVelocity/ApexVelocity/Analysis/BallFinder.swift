import AVFoundation
import Vision
import CoreImage
import CoreGraphics

/// Golf ball detection with strict area constraint + post-impact tracking.
///
/// Before impact: ball in constrained area (X: 20-80%, Y: 65-97%)
/// After impact: expanding search from last known position, then prediction
struct BallFinder {

    struct Result {
        let position: CGPoint  // normalized 0-1, origin top-left
        let confidence: Float
        let method: String
        var debugInfo: DebugInfo = DebugInfo()
    }

    struct DebugInfo {
        var imageSize: String = ""
        var wristPos: String = ""
        var clubHeadPos: String = ""
        var shaftAngle: String = ""
    }

    // MARK: - Expected Ball Area (before impact)

    // Search entire frame, bottom to top
    private static let ballAreaMinX: CGFloat = 0.0
    private static let ballAreaMaxX: CGFloat = 1.0
    private static let ballAreaMinY: CGFloat = 0.0
    private static let ballAreaMaxY: CGFloat = 1.0

    /// Find the golf ball within the expected area (initial detection).
    /// Returns nil if ball is not found (analysis NG).
    static func find(in asset: AVAsset, impactTime: Double? = nil, beforeTime: Double? = nil) async -> Result? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        generator.maximumSize = CGSize(width: 1080, height: 1920)

        let duration = (try? await asset.load(.duration)) ?? CMTime(seconds: 30, preferredTimescale: 600)
        let totalSeconds = CMTimeGetSeconds(duration)
        let maxSample = beforeTime ?? min(totalSeconds, 6.0)

        // Use compareAllMethods (BEST = Pixel + body exclusion + position weighting)
        // across multiple frames, pick most consistent result
        let sampleTimes: [Double] = stride(from: 0.3, to: maxSample, by: 0.8).map { $0 }
        var bestResults: [(pos: CGPoint, confidence: Float, frame: Int)] = []

        for (frameIdx, time) in sampleTimes.enumerated() {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            var actualTime = CMTime.zero
            guard let image = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) else { continue }

            let methods = compareAllMethods(image: image)
            if let best = methods.first(where: { $0.method == "BEST" }), let pos = best.position {
                bestResults.append((pos: pos, confidence: best.confidence, frame: frameIdx))
            }
        }

        guard !bestResults.isEmpty else {
            print("[BallFinder] ❌ No ball found")
            return nil
        }

        // Cluster results across frames (same position = higher confidence)
        let threshold: CGFloat = 0.05
        var clusters: [[(pos: CGPoint, confidence: Float, frame: Int)]] = []
        for r in bestResults {
            var added = false
            for i in 0..<clusters.count {
                if hypot(r.pos.x - clusters[i][0].pos.x, r.pos.y - clusters[i][0].pos.y) < threshold {
                    clusters[i].append(r)
                    added = true
                    break
                }
            }
            if !added { clusters.append([r]) }
        }

        let bestCluster = clusters.max(by: { $0.count < $1.count }) ?? [bestResults[0]]
        let avgX = bestCluster.map(\.pos.x).reduce(0, +) / CGFloat(bestCluster.count)
        let avgY = bestCluster.map(\.pos.y).reduce(0, +) / CGFloat(bestCluster.count)
        let confidence = min(1.0, Float(bestCluster.count) / 3.0 * 0.8)

        print("[BallFinder] ✅ BEST ball: (\(String(format: "%.3f", avgX)),\(String(format: "%.3f", avgY))) frames=\(bestCluster.count)/\(bestResults.count)")

        return Result(
            position: CGPoint(x: avgX, y: avgY),
            confidence: confidence,
            method: "best(\(bestCluster.count)f)"
        )
    }

    // MARK: - Constrained Area Search (before impact)

    private struct Candidate {
        let pos: CGPoint   // normalized 0-1
        let score: Double
    }

    /// Search for golf ball in the constrained area only.
    /// Looks for: bright spot on green grass with circular contrast.
    private static func searchBallInConstrainedArea(image: CGImage) -> [Candidate] {
        return searchBallInRegion(
            image: image,
            regionMinX: ballAreaMinX, regionMaxX: ballAreaMaxX,
            regionMinY: ballAreaMinY, regionMaxY: ballAreaMaxY
        )
    }

    /// Search for golf ball in a specific region of the image.
    /// Core detection: bright center + darker grass ring + small size.
    private static func searchBallInRegion(
        image: CGImage,
        regionMinX: CGFloat, regionMaxX: CGFloat,
        regionMinY: CGFloat, regionMaxY: CGFloat
    ) -> [Candidate] {
        let w = image.width
        let h = image.height
        guard let pixelData = renderToPixelData(image: image, width: w, height: h) else { return [] }
        let bytesPerRow = w * 4

        let sx1 = Int(regionMinX * CGFloat(w))
        let sx2 = Int(regionMaxX * CGFloat(w))
        let sy1 = Int(regionMinY * CGFloat(h))
        let sy2 = Int(regionMaxY * CGFloat(h))

        var candidates: [Candidate] = []

        // Search bottom-to-top: ball is most likely near the ground
        for y in stride(from: min(sy2 - 7, h - 7), through: max(sy1 + 6, 6), by: -2) {
            for x in stride(from: max(sx1 + 6, 6), to: min(sx2 - 6, w - 6), by: 2) {

                // Center brightness (3x3)
                var centerSum: Double = 0
                var centerCount = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let px = x + dx, py = y + dy
                        if px >= 0, px < w, py >= 0, py < h {
                            centerSum += pixelBrightness(pixelData, px, py, bytesPerRow)
                            centerCount += 1
                        }
                    }
                }
                let centerB = centerCount > 0 ? centerSum / Double(centerCount) : 0
                guard centerB > 50 else { continue }

                // Ring at radius 7-9px (should be darker than center)
                var ringSum: Double = 0
                var ringCount = 0
                var greenDominantCount = 0

                for angle in stride(from: 0, to: 360, by: 30) {
                    let rad = Double(angle) * .pi / 180.0
                    for r in [7, 8, 9] {
                        let rx = x + Int(Double(r) * cos(rad))
                        let ry = y + Int(Double(r) * sin(rad))
                        if rx >= 0, rx < w, ry >= 0, ry < h {
                            let b = pixelBrightness(pixelData, rx, ry, bytesPerRow)
                            ringSum += b
                            ringCount += 1

                            let offset = ry * bytesPerRow + rx * 4
                            if offset + 2 < pixelData.count {
                                let red = Double(pixelData[offset])
                                let grn = Double(pixelData[offset + 1])
                                let blu = Double(pixelData[offset + 2])
                                if grn > red && grn > blu {
                                    greenDominantCount += 1
                                }
                            }
                        }
                    }
                }

                guard ringCount > 0 else { continue }
                let ringB = ringSum / Double(ringCount)
                let contrast = centerB - ringB
                guard contrast > 5 else { continue }

                let grassRatio = Double(greenDominantCount) / Double(ringCount)
                guard grassRatio > 0.35 else { continue }

                // Outer ring (15-20px) should NOT be bright (rejects large bright areas like clothes)
                var outerBrightCount = 0
                var outerTotal = 0
                for angle in stride(from: 0, to: 360, by: 45) {
                    let rad = Double(angle) * .pi / 180.0
                    for r in [15, 18, 20] {
                        let rx = x + Int(Double(r) * cos(rad))
                        let ry = y + Int(Double(r) * sin(rad))
                        if rx >= 0, rx < w, ry >= 0, ry < h {
                            if pixelBrightness(pixelData, rx, ry, bytesPerRow) > centerB - 10 {
                                outerBrightCount += 1
                            }
                            outerTotal += 1
                        }
                    }
                }
                if outerTotal > 0 && Double(outerBrightCount) / Double(outerTotal) > 0.5 {
                    continue
                }

                let score = contrast * 3 + grassRatio * 20 + centerB * 0.1

                let normX = CGFloat(x) / CGFloat(w)
                let normY = CGFloat(y) / CGFloat(h)
                candidates.append(Candidate(pos: CGPoint(x: normX, y: normY), score: score))
            }
        }

        return Array(candidates.sorted { $0.score > $1.score }.prefix(10))
    }

    // MARK: - Zoom Verification

    /// Zoom into a candidate position and verify it looks like a ball.
    /// Returns refined position or nil if not a ball.
    private static func zoomVerify(
        image: CGImage, candidate: CGPoint, pixelData: [UInt8], width: Int, height: Int, bytesPerRow: Int
    ) -> CGPoint? {
        let cx = Int(candidate.x * CGFloat(width))
        let cy = Int(candidate.y * CGFloat(height))

        // Zoom: 30px radius around candidate
        let zoomR = 30
        let zx1 = max(0, cx - zoomR)
        let zx2 = min(width - 1, cx + zoomR)
        let zy1 = max(0, cy - zoomR)
        let zy2 = min(height - 1, cy + zoomR)

        // In the zoomed region, find the brightest small cluster
        var bestX = cx, bestY = cy
        var bestScore: Double = 0

        for y in stride(from: zy1 + 3, to: zy2 - 3, by: 1) {
            for x in stride(from: zx1 + 3, to: zx2 - 3, by: 1) {
                // 5x5 center brightness
                var sum: Double = 0
                var count = 0
                for dy in -2...2 {
                    for dx in -2...2 {
                        let px = x + dx, py = y + dy
                        if px >= 0, px < width, py >= 0, py < height {
                            sum += pixelBrightness(pixelData, px, py, bytesPerRow)
                            count += 1
                        }
                    }
                }
                let avg = count > 0 ? sum / Double(count) : 0
                guard avg > 60 else { continue }

                // Surrounding ring at radius 8
                var ringSum: Double = 0
                var ringCount = 0
                for angle in stride(from: 0, to: 360, by: 45) {
                    let rad = Double(angle) * .pi / 180.0
                    let rx = x + Int(8 * cos(rad))
                    let ry = y + Int(8 * sin(rad))
                    if rx >= 0, rx < width, ry >= 0, ry < height {
                        ringSum += pixelBrightness(pixelData, rx, ry, bytesPerRow)
                        ringCount += 1
                    }
                }
                let ringAvg = ringCount > 0 ? ringSum / Double(ringCount) : avg
                let contrast = avg - ringAvg

                if contrast > bestScore {
                    bestScore = contrast
                    bestX = x
                    bestY = y
                }
            }
        }

        // Must have meaningful contrast
        guard bestScore > 3 else { return nil }

        return CGPoint(
            x: CGFloat(bestX) / CGFloat(width),
            y: CGFloat(bestY) / CGFloat(height)
        )
    }

    // MARK: - Best Candidate Selection

    private static func selectBestCandidate(_ candidates: [(pos: CGPoint, score: Double, frame: Int)]) -> Result {
        let threshold: CGFloat = 0.04
        var clusters: [[(pos: CGPoint, score: Double, frame: Int)]] = []

        for c in candidates {
            var added = false
            for i in 0..<clusters.count {
                let center = clusters[i][0].pos
                if hypot(c.pos.x - center.x, c.pos.y - center.y) < threshold {
                    clusters[i].append(c)
                    added = true
                    break
                }
            }
            if !added {
                clusters.append([c])
            }
        }

        let best = clusters.max(by: { a, b in
            let framesA = Set(a.map(\.frame)).count
            let framesB = Set(b.map(\.frame)).count
            let scoreA = a.map(\.score).reduce(0, +)
            let scoreB = b.map(\.score).reduce(0, +)
            return (framesA * 1000 + Int(scoreA)) < (framesB * 1000 + Int(scoreB))
        })

        guard let bestCluster = best, !bestCluster.isEmpty else {
            let top = candidates.max(by: { $0.score < $1.score })!
            return Result(position: top.pos, confidence: 0.5, method: "area_search")
        }

        let avgX = bestCluster.map(\.pos.x).reduce(0, +) / CGFloat(bestCluster.count)
        let avgY = bestCluster.map(\.pos.y).reduce(0, +) / CGFloat(bestCluster.count)
        let frames = Set(bestCluster.map(\.frame)).count
        let confidence = min(1.0, Float(frames) / 3.0 * 0.8)

        print("[BallFinder] ✅ Ball: (\(String(format: "%.3f", avgX)),\(String(format: "%.3f", avgY))) frames=\(frames) pts=\(bestCluster.count)")

        return Result(
            position: CGPoint(x: avgX, y: avgY),
            confidence: confidence,
            method: "area(\(frames)f)",
            debugInfo: DebugInfo(
                imageSize: "",
                wristPos: "\(bestCluster.count)pts",
                clubHeadPos: "\(frames)frames",
                shaftAngle: "score=\(String(format: "%.0f", bestCluster.map(\.score).reduce(0,+) / Double(bestCluster.count)))"
            )
        )
    }

    // MARK: - Validation

    private static func isInExpectedArea(_ pos: CGPoint) -> Bool {
        return pos.x >= ballAreaMinX && pos.x <= ballAreaMaxX &&
               pos.y >= ballAreaMinY && pos.y <= ballAreaMaxY
    }

    // MARK: - Frame-by-Frame Ball Tracking

    struct FrameBallPosition {
        let time: Double
        let position: CGPoint   // normalized 0-1
        let confidence: Float
    }

    /// Track the ball across all frames.
    ///
    /// **Before impact:** Search in constrained area → zoom verify → confirm
    /// **After impact:**
    ///   1. Search UP + LEFT/RIGHT from last position (expanding area)
    ///   2. Found → zoom verify → confirm
    ///   3. Not found → expand search further
    ///   4. Still not found → predict from previous 2 positions' delta
    static func trackBallAcrossFrames(
        in asset: AVAsset,
        initialBallPosition: CGPoint,
        impactTime: Double?,
        frameInterval: Double = 0.2
    ) async -> [FrameBallPosition] {

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        generator.maximumSize = CGSize(width: 720, height: 1280)

        let duration = (try? await asset.load(.duration)) ?? CMTime(seconds: 30, preferredTimescale: 600)
        let totalSeconds = CMTimeGetSeconds(duration)
        let impact = impactTime ?? totalSeconds

        var positions: [FrameBallPosition] = []
        var lastDetectedPos = initialBallPosition
        var secondLastPos: CGPoint? = nil
        var consecutiveMisses = 0
        let maxMisses = 5  // Stop tracking after 5 consecutive misses

        // ============================================
        // Phase 1: Before impact — constrained area
        // ============================================
        var time: Double = 0.0
        while time < min(impact, totalSeconds) {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            var actualTime = CMTime.zero

            if let image = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) {
                let w = image.width, h = image.height
                let pixelData = renderToPixelData(image: image, width: w, height: h)

                // Step 1: Search in constrained area
                let candidates = searchBallInConstrainedArea(image: image)

                if let best = candidates.first {
                    // Step 2: Zoom verify
                    let verified: CGPoint
                    if let pd = pixelData {
                        verified = zoomVerify(image: image, candidate: best.pos, pixelData: pd, width: w, height: h, bytesPerRow: w * 4) ?? best.pos
                    } else {
                        verified = best.pos
                    }

                    // Step 3: Validate distance from last known
                    let dist = hypot(verified.x - lastDetectedPos.x, verified.y - lastDetectedPos.y)
                    if dist < 0.12 {
                        // Confirmed
                        secondLastPos = lastDetectedPos
                        lastDetectedPos = verified
                        positions.append(FrameBallPosition(time: time, position: verified, confidence: 0.9))
                    } else {
                        // Too far — keep last position
                        positions.append(FrameBallPosition(time: time, position: lastDetectedPos, confidence: 0.7))
                    }
                } else {
                    // No detection — keep last
                    positions.append(FrameBallPosition(time: time, position: lastDetectedPos, confidence: 0.6))
                }
            } else {
                positions.append(FrameBallPosition(time: time, position: lastDetectedPos, confidence: 0.5))
            }

            time += frameInterval
        }

        // ============================================
        // Phase 2: After impact — expanding search
        // ============================================
        // Use smaller interval for post-impact (ball moves fast)
        let postInterval = 0.033  // ~30fps
        time = impact
        consecutiveMisses = 0
        let postImpactDuration = 0.8  // Track up to 0.8s after impact

        while time < min(impact + postImpactDuration, totalSeconds) && consecutiveMisses < maxMisses {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            var actualTime = CMTime.zero

            guard let image = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) else {
                time += postInterval
                consecutiveMisses += 1
                continue
            }

            let w = image.width, h = image.height
            let pixelData = renderToPixelData(image: image, width: w, height: h)

            var found = false

            // --- Step 1: Search area = last position + UP + LEFT/RIGHT ---
            let searchMargin1: CGFloat = 0.08
            let region1MinX = max(0, lastDetectedPos.x - searchMargin1)
            let region1MaxX = min(1, lastDetectedPos.x + searchMargin1)
            let region1MinY = max(0, lastDetectedPos.y - searchMargin1 * 2)  // more upward
            let region1MaxY = min(1, lastDetectedPos.y + searchMargin1 * 0.5)  // less downward

            let candidates1 = searchBallInRegion(
                image: image,
                regionMinX: region1MinX, regionMaxX: region1MaxX,
                regionMinY: region1MinY, regionMaxY: region1MaxY
            )

            if let best = candidates1.first {
                if let pd = pixelData,
                   let verified = zoomVerify(image: image, candidate: best.pos, pixelData: pd, width: w, height: h, bytesPerRow: w * 4) {
                    secondLastPos = lastDetectedPos
                    lastDetectedPos = verified
                    positions.append(FrameBallPosition(time: time, position: verified, confidence: 0.8))
                    found = true
                    consecutiveMisses = 0
                } else {
                    // Zoom failed but candidate exists
                    secondLastPos = lastDetectedPos
                    lastDetectedPos = best.pos
                    positions.append(FrameBallPosition(time: time, position: best.pos, confidence: 0.6))
                    found = true
                    consecutiveMisses = 0
                }
            }

            // --- Step 2: Not found → expand search area ---
            if !found {
                let searchMargin2: CGFloat = 0.15
                let region2MinX = max(0, lastDetectedPos.x - searchMargin2)
                let region2MaxX = min(1, lastDetectedPos.x + searchMargin2)
                let region2MinY = max(0, lastDetectedPos.y - searchMargin2 * 3)  // much more upward
                let region2MaxY = min(1, lastDetectedPos.y + searchMargin2 * 0.3)

                let candidates2 = searchBallInRegion(
                    image: image,
                    regionMinX: region2MinX, regionMaxX: region2MaxX,
                    regionMinY: region2MinY, regionMaxY: region2MaxY
                )

                if let best = candidates2.first {
                    if let pd = pixelData,
                       let verified = zoomVerify(image: image, candidate: best.pos, pixelData: pd, width: w, height: h, bytesPerRow: w * 4) {
                        secondLastPos = lastDetectedPos
                        lastDetectedPos = verified
                        positions.append(FrameBallPosition(time: time, position: verified, confidence: 0.65))
                        found = true
                        consecutiveMisses = 0
                    }
                }
            }

            // --- Step 3: Still not found → predict from previous 2 positions ---
            if !found {
                if let prev = secondLastPos {
                    // Velocity vector from secondLast → last
                    let dx = lastDetectedPos.x - prev.x
                    let dy = lastDetectedPos.y - prev.y

                    // Only predict if there's meaningful movement
                    if abs(dx) > 0.001 || abs(dy) > 0.001 {
                        let predictedX = max(0, min(1, lastDetectedPos.x + dx))
                        let predictedY = max(0, min(1, lastDetectedPos.y + dy))
                        let predicted = CGPoint(x: predictedX, y: predictedY)

                        secondLastPos = lastDetectedPos
                        lastDetectedPos = predicted
                        positions.append(FrameBallPosition(time: time, position: predicted, confidence: 0.4))
                        consecutiveMisses += 1
                    } else {
                        // No movement detected → give up
                        consecutiveMisses += 1
                    }
                } else {
                    consecutiveMisses += 1
                }
            }

            time += postInterval
        }

        let highConf = positions.filter { $0.confidence >= 0.6 }.count
        let postImpactCount = positions.filter { $0.time >= impact }.count
        print("[BallFinder] Tracked \(positions.count) frames (\(highConf) high-conf, \(postImpactCount) post-impact)")
        return positions
    }

    // MARK: - Key Frame Detection for Each Frame

    /// Detect ball in a single frame image.
    /// Before impact: constrained area. After impact: near lastPosition.
    static func detectBallInFrame(
        image: CGImage,
        lastPosition: CGPoint?,
        isPostImpact: Bool
    ) -> (position: CGPoint, confidence: Float)? {
        let w = image.width, h = image.height

        if isPostImpact, let last = lastPosition {
            // Post-impact: search near last position, biased upward
            let margin: CGFloat = 0.12
            let candidates = searchBallInRegion(
                image: image,
                regionMinX: max(0, last.x - margin),
                regionMaxX: min(1, last.x + margin),
                regionMinY: max(0, last.y - margin * 2),
                regionMaxY: min(1, last.y + margin * 0.5)
            )
            if let best = candidates.first {
                let pixelData = renderToPixelData(image: image, width: w, height: h)
                if let pd = pixelData,
                   let verified = zoomVerify(image: image, candidate: best.pos, pixelData: pd, width: w, height: h, bytesPerRow: w * 4) {
                    return (verified, 0.7)
                }
                return (best.pos, 0.5)
            }
            return nil
        } else {
            // Pre-impact: constrained area
            let candidates = searchBallInConstrainedArea(image: image)
            if let best = candidates.first {
                let pixelData = renderToPixelData(image: image, width: w, height: h)
                if let pd = pixelData,
                   let verified = zoomVerify(image: image, candidate: best.pos, pixelData: pd, width: w, height: h, bytesPerRow: w * 4) {
                    return (verified, 0.9)
                }
                return (best.pos, 0.7)
            }
            return nil
        }
    }

    // MARK: - Helpers

    private static func renderToPixelData(image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixelData,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelData
    }

    private static func pixelBrightness(_ data: [UInt8], _ x: Int, _ y: Int, _ bytesPerRow: Int) -> Double {
        let offset = y * bytesPerRow + x * 4
        guard offset + 2 < data.count else { return 0 }
        return (Double(data[offset]) + Double(data[offset + 1]) + Double(data[offset + 2])) / 3.0
    }

    // MARK: - Multi-Method Comparison

    struct MethodResult {
        let method: String
        let position: CGPoint?  // normalized 0-1
        let confidence: Float
        let color: (r: CGFloat, g: CGFloat, b: CGFloat)  // marker color
        let details: String
    }

    /// Pixel scanning + body exclusion + position weighting.
    static func compareAllMethods(image: CGImage) -> [MethodResult] {
        var results: [MethodResult] = []

        // Pixel Scanning — bottom 40% + body exclusion + position weighting
        let pixelCandidates = searchBallInRegion(
            image: image,
            regionMinX: 0, regionMaxX: 1, regionMinY: 0.6, regionMaxY: 1.0
        )
        let bodyRegions = detectBodyRegions(image: image)
        let filtered = pixelCandidates.filter { c in
            for region in bodyRegions {
                if region.contains(c.pos) { return false }
            }
            return true
        }

        // Position weighting
        let scored = filtered.map { c -> (Candidate, Double) in
            var weight = c.score
            if c.pos.y >= 0.7 { weight *= 1.5 }
            else if c.pos.y >= 0.5 { weight *= 1.2 }
            else if c.pos.y >= 0.3 { weight *= 0.5 }
            else { weight *= 0.1 }
            if c.pos.x >= 0.2 && c.pos.x <= 0.8 { weight *= 1.2 }
            else { weight *= 0.4 }
            return (c, weight)
        }.sorted { $0.1 > $1.1 }

        if let best = scored.first {
            results.append(MethodResult(
                method: "BEST",
                position: best.0.pos,
                confidence: Float(min(0.9, best.1 / 50.0)),
                color: (1, 0, 1),  // MAGENTA
                details: "w=\(String(format: "%.0f", best.1))"
            ))
        }

        // Log all results
        for r in results {
            if let pos = r.position {
                print("[Compare] \(r.method): (\(String(format: "%.3f", pos.x)),\(String(format: "%.3f", pos.y))) conf=\(String(format: "%.2f", r.confidence)) \(r.details)")
            } else {
                print("[Compare] \(r.method): NOT FOUND \(r.details)")
            }
        }

        return results
    }

    // MARK: - Body Region Detection (with ankle-below full mask)

    /// Debug flag: draws exclusion masks on Key Frame images when true
    static let isDebugMaskEnabled = true

    private static func detectBodyRegions(image: CGImage) -> [CGRect] {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        guard let body = request.results?.first else { return [] }

        var regions: [CGRect] = []

        // --- Step 1: Joint exclusion circles ---
        let jointNames: [VNHumanBodyPoseObservation.JointName] = [
            .rightWrist, .leftWrist, .rightElbow, .leftElbow,
            .rightShoulder, .leftShoulder, .neck,
            .nose, .rightEar, .leftEar,
            .rightAnkle, .leftAnkle,
            .rightKnee, .leftKnee,
            .rightHip, .leftHip
        ]

        for joint in jointNames {
            guard let pt = try? body.recognizedPoint(joint), pt.confidence > 0.3 else { continue }
            let x = pt.location.x
            let y = 1.0 - pt.location.y  // Vision bottom-left → top-left
            let margin: CGFloat = 0.08
            regions.append(CGRect(x: x - margin, y: y - margin, width: margin * 2, height: margin * 2))
        }

        // --- Step 2: Body trunk rectangle ---
        let rShoulder = try? body.recognizedPoint(.rightShoulder)
        let lShoulder = try? body.recognizedPoint(.leftShoulder)
        let rHip = try? body.recognizedPoint(.rightHip)
        let lHip = try? body.recognizedPoint(.leftHip)

        if let rs = rShoulder, let ls = lShoulder, let rh = rHip, let lh = lHip,
           rs.confidence > 0.3, ls.confidence > 0.3, rh.confidence > 0.3, lh.confidence > 0.3 {
            let minX = min(rs.location.x, ls.location.x, rh.location.x, lh.location.x) - 0.06
            let maxX = max(rs.location.x, ls.location.x, rh.location.x, lh.location.x) + 0.06
            let minY = 1.0 - max(rs.location.y, ls.location.y)
            let maxY = 1.0 - min(rh.location.y, lh.location.y)
            regions.append(CGRect(x: minX, y: minY - 0.05, width: maxX - minX, height: maxY - minY + 0.1))
        }

        // --- Step 3: ANKLE-BELOW FULL MASK ---
        // Mask everything below ankle Y under the golfer's horizontal span.
        // This prevents shoe tips, laces, and ground-level bright spots.
        let rAnkle = try? body.recognizedPoint(.rightAnkle)
        let lAnkle = try? body.recognizedPoint(.leftAnkle)

        var ankleYValues: [CGFloat] = []  // top-left Y coordinates
        if let ra = rAnkle, ra.confidence > 0.3 { ankleYValues.append(1.0 - ra.location.y) }
        if let la = lAnkle, la.confidence > 0.3 { ankleYValues.append(1.0 - la.location.y) }

        if !ankleYValues.isEmpty {
            // Use the higher ankle on screen (lower Y value in top-left coords)
            let highestAnkleY = ankleYValues.min()!
            let maskStartY = highestAnkleY + 0.02  // tiny buffer above ankle

            // Horizontal span: use hip range or ankle range + margin
            let golferMinX: CGFloat
            let golferMaxX: CGFloat
            if let rh = rHip, let lh = lHip, rh.confidence > 0.3, lh.confidence > 0.3 {
                golferMinX = min(rh.location.x, lh.location.x) - 0.15
                golferMaxX = max(rh.location.x, lh.location.x) + 0.15
            } else {
                golferMinX = (rAnkle?.location.x ?? 0.2) - 0.15
                golferMaxX = (lAnkle?.location.x ?? 0.4) + 0.15
            }

            let ankleRect = CGRect(
                x: max(0, golferMinX),
                y: maskStartY,
                width: min(1.0, golferMaxX) - max(0, golferMinX),
                height: 1.0 - maskStartY
            )
            regions.append(ankleRect)
            print("[BallFinder] Ankle mask: y>=\(String(format: "%.3f", maskStartY)) x=\(String(format: "%.2f", golferMinX))-\(String(format: "%.2f", golferMaxX))")
        }

        return regions
    }

    /// Draw debug exclusion masks on a CGImage for Key Frame visualization.
    static func drawDebugMasks(on image: CGImage, regions: [CGRect]? = nil) -> CGImage? {
        guard isDebugMaskEnabled else { return image }

        let w = image.width, h = image.height
        guard let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        // Draw original (CGContext origin = bottom-left)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let exclusionRegions = regions ?? detectBodyRegions(image: image)

        // Red semi-transparent fill + border
        context.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.25)
        context.setStrokeColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.6)
        context.setLineWidth(2)

        for region in exclusionRegions {
            // Normalized top-left → pixel bottom-left (CGContext)
            let px = region.origin.x * CGFloat(w)
            let py = (1.0 - region.origin.y - region.height) * CGFloat(h)
            let pw = region.width * CGFloat(w)
            let ph = region.height * CGFloat(h)
            let pixelRect = CGRect(x: px, y: py, width: pw, height: ph)
            context.fill(pixelRect)
            context.stroke(pixelRect)
        }

        return context.makeImage()
    }

}

// MARK: - Unused methods removed (Contours, Saliency, Circularity, YOLO)
// Only Pixel scanning + body exclusion + position weighting is used.

