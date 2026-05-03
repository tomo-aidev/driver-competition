import SwiftUI

/// Animated golf ball trajectory overlay — "Everybody's Golf" style.
///
/// Animations:
/// 1. Impact: massive burst + shockwave + sparks
/// 2. Launch: comet tail with fire trail, speed lines
/// 3. Flight: glowing ball with fading ribbon trail
/// 4. Descent: trail thins and cools (red→orange→yellow→white)
/// 5. Landing: ripple rings on ground
struct TrajectoryAnimationView: View {
    let trajectoryPoints: [TrajectoryDetector.TrajectoryPoint]
    let impactTime: Double
    let currentTime: Double
    let viewSize: CGSize

    private var progress: Double {
        guard let first = trajectoryPoints.first,
              let last = trajectoryPoints.last,
              last.time > first.time else { return 0 }
        return min(1.0, max(0, (currentTime - first.time) / (last.time - first.time)))
    }

    private var isActive: Bool {
        guard let first = trajectoryPoints.first,
              let last = trajectoryPoints.last else { return false }
        return currentTime >= first.time - 0.1 && currentTime <= last.time + 1.5
    }

    private var visibleCount: Int {
        Int(progress * Double(trajectoryPoints.count))
    }

    var body: some View {
        if isActive && !trajectoryPoints.isEmpty {
            ZStack {
                // Layer 1: Wide glow trail (background)
                wideGlowTrail

                // Layer 2: Core trail (foreground)
                coreTrail

                // Layer 3: Impact burst
                if currentTime >= impactTime && currentTime < impactTime + 1.0 {
                    impactBurst
                }

                // Layer 4: Speed lines (first 30%)
                if progress > 0.01 && progress < 0.35 {
                    speedLines
                }

                // Layer 5: Ball head with comet tail
                if progress > 0.01 && progress < 0.98 {
                    cometBall
                }

                // Layer 6: Landing effect
                if progress >= 0.95 {
                    landingEffect
                }
            }
        }
    }

    // MARK: - Wide Glow Trail

    private var wideGlowTrail: some View {
        Canvas { context, size in
            guard visibleCount >= 2 else { return }
            let points = Array(trajectoryPoints.prefix(visibleCount))

            for i in 1..<points.count {
                let prev = pt(points[i-1].position, size)
                let curr = pt(points[i].position, size)
                let seg = Double(i) / Double(points.count)

                // Wide, soft glow
                let glowWidth = 24.0 - seg * 16.0
                let glowOpacity = max(0.03, 0.2 - seg * 0.15)

                // Color shifts from warm to cool
                let color: Color = seg < 0.4 ?
                    Color.orange : seg < 0.7 ?
                    Color.yellow : Color.white

                var path = Path()
                path.move(to: prev)
                path.addLine(to: curr)
                context.stroke(path, with: .color(color.opacity(glowOpacity)), lineWidth: glowWidth)
            }
        }
    }

    // MARK: - Core Trail

    private var coreTrail: some View {
        Canvas { context, size in
            guard visibleCount >= 2 else { return }
            let points = Array(trajectoryPoints.prefix(visibleCount))

            // Draw segments with varying width and color
            for i in 1..<points.count {
                let prev = pt(points[i-1].position, size)
                let curr = pt(points[i].position, size)
                let seg = Double(i) / Double(points.count)

                // Width: thick at start, thins out
                let width = 6.0 - seg * 3.5

                // Opacity: bright → fades
                let opacity = max(0.4, 1.0 - seg * 0.5)

                // Hot gradient: red → orange → yellow → white
                let color: Color
                if seg < 0.15 {
                    color = Color(red: 1, green: 0.2, blue: 0.1) // hot red
                } else if seg < 0.35 {
                    color = Color(red: 1, green: 0.5, blue: 0.1) // orange
                } else if seg < 0.6 {
                    color = Color(red: 1, green: 0.8, blue: 0.2) // yellow-orange
                } else if seg < 0.8 {
                    color = Color(red: 1, green: 0.95, blue: 0.5) // warm yellow
                } else {
                    color = Color(red: 0.9, green: 0.95, blue: 1.0) // cool white
                }

                var path = Path()
                path.move(to: prev)
                path.addLine(to: curr)
                context.stroke(
                    path,
                    with: .color(color.opacity(opacity)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round)
                )
            }
        }
    }

    // MARK: - Impact Burst (Hot Shots Golf style)

    private var impactBurst: some View {
        let impactPos = pt(
            trajectoryPoints.first?.position ?? CGPoint(x: 0.5, y: 0.8),
            viewSize
        )
        let elapsed = currentTime - impactTime
        let p = min(1.0, elapsed / 0.8)

        return ZStack {
            // Shockwave ring 1
            Circle()
                .stroke(
                    Color.white.opacity(max(0, 1.0 - p * 1.2)),
                    lineWidth: max(0.5, 5 - p * 5)
                )
                .frame(width: 20 + p * 200, height: 20 + p * 200)

            // Shockwave ring 2 (delayed)
            Circle()
                .stroke(
                    Color.orange.opacity(max(0, 0.8 - p * 1.0)),
                    lineWidth: max(0.5, 4 - p * 4)
                )
                .frame(width: 10 + p * 140, height: 10 + p * 140)

            // Central flash
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(max(0, 1.0 - p * 0.7)),
                            Color.yellow.opacity(max(0, 0.9 - p * 0.8)),
                            Color.orange.opacity(max(0, 0.6 - p * 0.6)),
                            Color.red.opacity(max(0, 0.3 - p * 0.3)),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 40 + p * 60
                    )
                )
                .frame(width: 140 + p * 100, height: 140 + p * 100)

            // Fire sparks (20 particles)
            ForEach(0..<20, id: \.self) { i in
                let sparkAngle = Double(i) * Double.pi * 2.0 / 20.0 + p * 1.2
                let dist = p * (60 + Double(i % 3) * 30)
                let size = max(1.0, (6.0 - p * 6.0) * (i % 2 == 0 ? 1.0 : 0.6))
                let sparkColor: Color = [Color.white, .yellow, .orange, .red][i % 4]

                Circle()
                    .fill(sparkColor.opacity(max(0, 1.0 - p * 1.3)))
                    .frame(width: size, height: size)
                    .offset(
                        x: CGFloat(Foundation.cos(sparkAngle) * dist),
                        y: CGFloat(Foundation.sin(sparkAngle) * dist)
                    )
            }

            // Star burst lines
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) * Double.pi / 4.0
                let lineLen = max(0, 30 * (1.0 - p * 1.5))

                Path { path in
                    let inner = 15 + p * 40
                    let sx = CGFloat(Foundation.cos(angle) * inner)
                    let sy = CGFloat(Foundation.sin(angle) * inner)
                    let ex = CGFloat(Foundation.cos(angle) * (inner + lineLen))
                    let ey = CGFloat(Foundation.sin(angle) * (inner + lineLen))
                    path.move(to: CGPoint(x: sx, y: sy))
                    path.addLine(to: CGPoint(x: ex, y: ey))
                }
                .stroke(Color.white.opacity(max(0, 0.8 - p * 1.2)), lineWidth: 2)
            }
        }
        .position(impactPos)
    }

    // MARK: - Speed Lines

    private var speedLines: some View {
        let currentIdx = max(0, min(trajectoryPoints.count - 1, Int(progress * Double(trajectoryPoints.count))))
        guard currentIdx > 0 else { return AnyView(EmptyView()) }

        let currPos = pt(trajectoryPoints[currentIdx].position, viewSize)
        let prevIdx = max(0, currentIdx - 2)
        let prevPos = pt(trajectoryPoints[prevIdx].position, viewSize)

        let dx = Double(currPos.x - prevPos.x)
        let dy = Double(currPos.y - prevPos.y)
        let angle = atan2(dy, dx)
        let opacity = max(0.0, 0.7 - progress * 2.5)

        return AnyView(
            ZStack {
                // Parallel speed lines behind the ball
                ForEach(0..<7, id: \.self) { i in
                    let off = Double(i - 3) * 6.0
                    let px = CGFloat(Foundation.cos(angle + .pi / 2) * off)
                    let py = CGFloat(Foundation.sin(angle + .pi / 2) * off)
                    let lineLen = CGFloat(max(15.0, 50.0 - Double(abs(i - 3)) * 12.0))

                    Path { path in
                        let startX = currPos.x + px - CGFloat(Foundation.cos(angle)) * lineLen
                        let startY = currPos.y + py - CGFloat(Foundation.sin(angle)) * lineLen
                        path.move(to: CGPoint(x: startX, y: startY))
                        path.addLine(to: CGPoint(x: currPos.x + px, y: currPos.y + py))
                    }
                    .stroke(
                        Color.white.opacity(opacity * (1.0 - Double(abs(i - 3)) * 0.25)),
                        lineWidth: i == 3 ? 2.0 : 1.0
                    )
                }
            }
        )
    }

    // MARK: - Comet Ball (current position)

    private var cometBall: some View {
        let currentIdx = max(0, min(trajectoryPoints.count - 1, Int(progress * Double(trajectoryPoints.count))))
        let pos = pt(trajectoryPoints[currentIdx].position, viewSize)
        let fadeOut = max(0.0, progress - 0.85) / 0.15  // fade in last 15%

        // Comet tail direction
        let prevIdx = max(0, currentIdx - 3)
        let prevPos = pt(trajectoryPoints[prevIdx].position, viewSize)

        return ZStack {
            // Comet tail (trailing glow)
            if currentIdx > 3 {
                Canvas { context, size in
                    let tailLen = min(8, currentIdx)
                    for i in 0..<tailLen {
                        let idx = currentIdx - i
                        guard idx >= 0 else { break }
                        let p = pt(trajectoryPoints[idx].position, size)
                        let tailFade = Double(i) / Double(tailLen)
                        let radius = max(1, 10.0 - tailFade * 8.0)

                        context.fill(
                            Path(ellipseIn: CGRect(
                                x: p.x - CGFloat(radius),
                                y: p.y - CGFloat(radius),
                                width: CGFloat(radius * 2),
                                height: CGFloat(radius * 2)
                            )),
                            with: .color(Color.orange.opacity(max(0, (0.5 - tailFade * 0.5) * (1.0 - fadeOut))))
                        )
                    }
                }
            }

            // Outer glow (large, soft)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(max(0, 0.9 - fadeOut)),
                            Color.yellow.opacity(max(0, 0.4 - fadeOut * 0.4)),
                            Color.orange.opacity(max(0, 0.15 - fadeOut * 0.15)),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 25
                    )
                )
                .frame(width: 50, height: 50)
                .position(pos)

            // Core ball (bright white)
            Circle()
                .fill(Color.white.opacity(max(0, 1.0 - fadeOut)))
                .frame(width: 10, height: 10)
                .shadow(color: .yellow.opacity(0.8), radius: 6)
                .shadow(color: .orange.opacity(0.5), radius: 12)
                .position(pos)
        }
    }

    // MARK: - Landing Effect

    private var landingEffect: some View {
        let landPos = pt(
            trajectoryPoints.last?.position ?? CGPoint(x: 0.5, y: 0.9),
            viewSize
        )
        let landProgress = min(1.0, (progress - 0.95) / 0.05)

        return ZStack {
            // Dust cloud / ripple rings
            ForEach(0..<4, id: \.self) { i in
                let delay = Double(i) * 0.12
                let ringP = max(0.0, min(1.0, (landProgress - delay) / 0.4))
                let ringOpacity = max(0.0, 0.6 - ringP * 0.6)
                let ringWidth = max(0.5, 3.0 - ringP * 3.0)
                let ringSize = ringP * 60.0 + 5.0

                Circle()
                    .stroke(
                        Color(red: 0.6, green: 0.8, blue: 0.3).opacity(ringOpacity),
                        lineWidth: ringWidth
                    )
                    .frame(width: ringSize, height: ringSize)
            }

            // Center impact dot
            Circle()
                .fill(Color.white.opacity(max(0, 1.0 - landProgress * 2)))
                .frame(width: 8, height: 8)

            // Bounce dots (small particles going up)
            ForEach(0..<6, id: \.self) { i in
                let angle = Double(i) * Double.pi / 3.0 + 0.5
                let dist = landProgress * 25
                let upward = -landProgress * 15 * (1.0 - landProgress)

                Circle()
                    .fill(Color.green.opacity(max(0, 0.5 - landProgress)))
                    .frame(width: 3, height: 3)
                    .offset(
                        x: CGFloat(Foundation.cos(angle) * dist),
                        y: CGFloat(Foundation.sin(angle) * dist + upward)
                    )
            }
        }
        .position(landPos)
    }

    // MARK: - Helper

    private func pt(_ normalized: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }
}
