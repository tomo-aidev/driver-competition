import SwiftUI

/// Test screen for trajectory animation with adjustable parameters.
/// 10 animation styles to compare. Amateur golfer data-based sliders.
struct TrajectoryTestView: View {

    // Sliders — ranges based on amateur golfer data
    @State private var headSpeedMs: Double = 40    // 30-55 m/s
    @State private var launchAngleDeg: Double = 13  // 8-25°
    @State private var directionDeg: Double = 0     // -20 to +20°
    @State private var animStyleIndex: Int = 0

    // Animation state
    @State private var isAnimating = false
    @State private var animationProgress: Double = 0
    @State private var trajectoryPoints: [TrajectoryDetector.TrajectoryPoint] = []
    @State private var animationTimer: Timer?

    // Ball position
    private var ballPosition: CGPoint {
        isAnimating ? CGPoint(x: 0.5, y: 0.92) : CGPoint(x: 0.5, y: 0.85)
    }

    // Computed values
    private var ballSpeedMs: Double { headSpeedMs * 1.45 }  // ミート率1.45
    private var ballSpeedMph: Double { ballSpeedMs * 2.237 }
    private var estimatedYards: Int {
        // 飛距離 ≈ ヘッドスピード × 5.5
        Int(headSpeedMs * 5.5)
    }

    static let styleNames = [
        "Fire Comet",       // 0: 炎の彗星
        "Neon Laser",       // 1: ネオンレーザー
        "Thunder Bolt",     // 2: 雷光
        "Sakura Trail",     // 3: 桜吹雪
        "Gold Ribbon",      // 4: ゴールドリボン
        "Ice Crystal",      // 5: 氷結晶
        "Rainbow Arc",      // 6: 虹のアーク
        "Phantom Smoke",    // 7: ファントムスモーク
        "Star Dust",        // 8: スターダスト
        "Plasma Beam",      // 9: プラズマビーム
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.18, blue: 0.08),
                        Color(red: 0.04, green: 0.12, blue: 0.04),
                        Color(red: 0.06, green: 0.20, blue: 0.10)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                gridOverlay(in: geo.size)
                ballMarkerFixed(in: geo.size)

                // Trajectory with selected style
                if !trajectoryPoints.isEmpty {
                    TrajectoryStyleView(
                        points: trajectoryPoints,
                        progress: animationProgress,
                        style: animStyleIndex,
                        viewSize: geo.size
                    )
                }

                // Controls
                VStack(spacing: 0) {
                    titleBar
                    Spacer()
                    if isAnimating {
                        compactBar
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        controlPanel(in: geo.size)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: isAnimating)
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { stopAnimation() }
    }

    // MARK: - Title

    private var titleBar: some View {
        HStack {
            Text("Trajectory Lab")
                .font(.custom("SpaceGrotesk-Bold", size: 18, relativeTo: .title3))
                .foregroundStyle(.white)
            Spacer()
            if isAnimating {
                Text(Self.styleNames[animStyleIndex])
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.primaryFixed)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
    }

    // MARK: - Compact Bar

    private var compactBar: some View {
        HStack(spacing: 16) {
            Text("\(estimatedYards)y")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(AppTheme.primaryFixed)
            Text("\(Int(launchAngleDeg))°")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.gray)
            Text(String(format: "%+.0f°", directionDeg))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.gray)

            Spacer()

            Button(action: { stopAnimation() }) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill").font(.system(size: 12))
                    Text("STOP").font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.8))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 100)
    }

    // MARK: - Grid

    private func gridOverlay(in size: CGSize) -> some View {
        Canvas { context, s in
            for i in 1...9 {
                let y = s.height * CGFloat(i) / 10
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: s.width, y: y))
                context.stroke(path, with: .color(Color.white.opacity(0.06)), lineWidth: 0.5)
            }
            var center = Path()
            center.move(to: CGPoint(x: s.width / 2, y: 0))
            center.addLine(to: CGPoint(x: s.width / 2, y: s.height))
            context.stroke(center, with: .color(Color.white.opacity(0.08)), lineWidth: 0.5)
        }
    }

    // MARK: - Ball Marker

    private func ballMarkerFixed(in size: CGSize) -> some View {
        let x = ballPosition.x * size.width
        let y = ballPosition.y * size.height
        return ZStack {
            Circle().stroke(AppTheme.primaryFixed, lineWidth: 2).frame(width: 30, height: 30)
            Circle().fill(AppTheme.primaryFixed).frame(width: 4, height: 4)
            Text("BALL").font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(AppTheme.primaryFixed).offset(y: 22)
        }
        .position(x: x, y: y)
    }

    // MARK: - Control Panel

    private func controlPanel(in size: CGSize) -> some View {
        VStack(spacing: 10) {
            // Head Speed
            sliderRow(label: "Head Speed", value: $headSpeedMs, range: 30...55,
                      display: String(format: "%.0f m/s", headSpeedMs),
                      leftIcon: "tortoise", rightIcon: "hare")

            // Launch Angle
            sliderRow(label: "Launch Angle", value: $launchAngleDeg, range: 8...25,
                      display: String(format: "%.0f°", launchAngleDeg),
                      leftIcon: "arrow.down.right", rightIcon: "arrow.up.right")

            // Direction
            sliderRow(label: "Direction", value: $directionDeg, range: -20...20,
                      display: String(format: "%+.0f°", directionDeg),
                      leftIcon: "arrow.left", rightIcon: "arrow.right")

            // Style selector
            VStack(spacing: 4) {
                HStack {
                    Text("Style").font(.system(size: 12, weight: .medium)).foregroundStyle(.gray)
                    Spacer()
                    Text(Self.styleNames[animStyleIndex])
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.primaryFixed)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(0..<10, id: \.self) { i in
                            Button(action: { animStyleIndex = i }) {
                                Text("\(i+1)")
                                    .font(.system(size: 12, weight: .bold))
                                    .frame(width: 32, height: 32)
                                    .foregroundStyle(i == animStyleIndex ? .black : .white)
                                    .background(i == animStyleIndex ? AppTheme.primaryFixed : Color.white.opacity(0.12))
                                    .clipShape(Circle())
                            }
                        }
                    }
                }
            }

            // Info chips
            HStack(spacing: 12) {
                infoChip("\(Int(headSpeedMs))m/s", label: "HS")
                infoChip("\(Int(ballSpeedMs))m/s", label: "Ball")
                infoChip("\(Int(launchAngleDeg))°", label: "Angle")
                infoChip("~\(estimatedYards)y", label: "Carry")
            }
            .padding(.top, 2)

            // Start button
            Button(action: { startAnimation() }) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").font(.system(size: 16))
                    Text("START").font(.custom("SpaceGrotesk-Bold", size: 16, relativeTo: .body))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.primaryFixed)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.88)))
        .padding(.horizontal, 16)
        .padding(.bottom, 100)
    }

    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>,
                           display: String, leftIcon: String, rightIcon: String) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.gray)
                Spacer()
                Text(display).font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.primaryFixed)
            }
            HStack(spacing: 6) {
                Image(systemName: leftIcon).font(.system(size: 10)).foregroundStyle(.gray)
                Slider(value: value, in: range).tint(AppTheme.primaryFixed)
                Image(systemName: rightIcon).font(.system(size: 10)).foregroundStyle(.gray)
            }
        }
    }

    private func infoChip(_ value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.white)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Animation

    private var totalDuration: Double { trajectoryPoints.last?.time ?? 3.0 }

    private func startAnimation() {
        stopAnimation()
        trajectoryPoints = generateTrajectory()
        animationProgress = 0
        isAnimating = true
        let start = Date()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            animationProgress = Date().timeIntervalSince(start)
            if animationProgress >= totalDuration + 1.5 { stopAnimation() }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        isAnimating = false
        animationProgress = 0
        trajectoryPoints = []
    }

    private func generateTrajectory() -> [TrajectoryDetector.TrajectoryPoint] {
        var points: [TrajectoryDetector.TrajectoryPoint] = []

        let dirRad = directionDeg * .pi / 180.0
        let angleRad = launchAngleDeg * .pi / 180.0

        // 中級者230y初期設定で画面の60%（6メモリ）の高さに到達
        let speedNorm = headSpeedMs / 40.0
        let targetApexHeight = 0.60 * sin(angleRad) / sin(13 * .pi / 180) * speedNorm
        // 真空滞空時間2.8s × 補正: 上昇1.3倍、下降1.5倍
        let vacuumHalfTime = 1.4 * speedNorm
        let ascentTime = vacuumHalfTime * 1.3   // 上昇: 1.82s
        let descentTime = vacuumHalfTime * 1.5  // 下降: 2.10s
        let flightDuration = ascentTime + descentTime  // 合計: 3.92s

        let halfTime = ascentTime
        let gravity = 2.0 * targetApexHeight / (halfTime * halfTime)
        let vy0 = -gravity * halfTime
        let vx = 0.12 * sin(dirRad) * speedNorm

        // Step 1: Generate positions at equal spatial intervals
        let positionDt = 0.005  // fine sampling for position
        var rawPositions: [(x: Double, y: Double)] = []
        var t = 0.0
        var hasReachedApex = false

        while t < flightDuration + 0.5 {
            let x = Double(ballPosition.x) + vx * t
            let y = Double(ballPosition.y) + vy0 * t + 0.5 * gravity * t * t

            if !hasReachedApex && (vy0 + gravity * t) > 0 { hasReachedApex = true }

            if hasReachedApex && y >= Double(ballPosition.y) - 0.005 && t > 0.5 {
                rawPositions.append((x: clamp01(x), y: Double(ballPosition.y)))
                break
            }
            if x < -0.15 || x > 1.15 { break }

            rawPositions.append((x: clamp01(x), y: clamp01(y)))
            t += positionDt
        }

        guard rawPositions.count > 10 else { return points }

        // Step 2: Resample with velocity-based timing
        // Ball speed: fast at launch, slowest at apex, slightly faster on descent
        // v(t) = sqrt(vx² + (vy0 + g*t)²)
        // Use this to assign "real time" to each position

        let totalPositions = rawPositions.count
        var cumulativeTime = 0.0

        for i in 0..<totalPositions {
            let physicsT = Double(i) * positionDt

            // Current velocity (normalized)
            let vyNow = vy0 + gravity * physicsT
            let speed = sqrt(vx * vx + vyNow * vyNow)

            // Initial speed for reference
            let initialSpeed = sqrt(vx * vx + vy0 * vy0)

            // Air resistance: speed decays over time (exponential drag)
            let dragFactor = 0.7 + 0.3 * exp(-physicsT * 0.8)
            let adjustedSpeed = max(0.15, speed * dragFactor)

            // Time increment: fast launch, slow apex, medium descent
            let animDt: Double
            if i == 0 {
                animDt = 0
            } else {
                let speedRatio = min(3.0, initialSpeed / adjustedSpeed)  // cap stretch
                let baseDt = flightDuration / Double(totalPositions)
                animDt = baseDt * speedRatio
            }

            cumulativeTime += animDt

            points.append(TrajectoryDetector.TrajectoryPoint(
                time: cumulativeTime,
                position: CGPoint(x: rawPositions[i].x, y: rawPositions[i].y),
                isDetected: cumulativeTime < 0.2,
                confidence: Float(max(0.2, 1.0 - cumulativeTime / (flightDuration + 0.5)))
            ))
        }

        // Normalize total animation time to match physical flight duration
        if let lastTime = points.last?.time, lastTime > 0 {
            let scale = flightDuration / lastTime
            points = points.map {
                var p = $0
                p = TrajectoryDetector.TrajectoryPoint(
                    time: $0.time * scale,
                    position: $0.position,
                    isDetected: $0.isDetected,
                    confidence: $0.confidence
                )
                return p
            }
        }

        return points
    }

    private func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }
}

// MARK: - 10 Animation Styles

struct TrajectoryStyleView: View {
    let points: [TrajectoryDetector.TrajectoryPoint]
    let progress: Double
    let style: Int
    let viewSize: CGSize

    private var visibleCount: Int {
        guard let first = points.first, let last = points.last, last.time > first.time else { return 0 }
        let p = min(1.0, max(0, (progress - first.time) / (last.time - first.time)))
        return Int(p * Double(points.count))
    }

    private var normalizedProgress: Double {
        guard let first = points.first, let last = points.last, last.time > first.time else { return 0 }
        return min(1.0, max(0, (progress - first.time) / (last.time - first.time)))
    }

    var body: some View {
        ZStack {
            // Impact burst (all styles)
            if let first = points.first, progress >= first.time && progress < first.time + 0.8 {
                impactBurst(at: pt(first.position), elapsed: progress - first.time)
            }

            // Trail + ball based on style
            Canvas { context, size in
                guard visibleCount >= 2 else { return }
                let visible = Array(points.prefix(visibleCount))

                switch style {
                case 0: drawFireComet(context: context, points: visible, size: size)
                case 1: drawNeonLaser(context: context, points: visible, size: size)
                case 2: drawThunderBolt(context: context, points: visible, size: size)
                case 3: drawSakuraTrail(context: context, points: visible, size: size)
                case 4: drawGoldRibbon(context: context, points: visible, size: size)
                case 5: drawIceCrystal(context: context, points: visible, size: size)
                case 6: drawRainbowArc(context: context, points: visible, size: size)
                case 7: drawPhantomSmoke(context: context, points: visible, size: size)
                case 8: drawStarDust(context: context, points: visible, size: size)
                case 9: drawPlasmaBeam(context: context, points: visible, size: size)
                default: drawFireComet(context: context, points: visible, size: size)
                }
            }

            // Landing
            if normalizedProgress >= 0.95, let last = points.last {
                landingRipple(at: pt(last.position), progress: (normalizedProgress - 0.95) / 0.05)
            }
        }
    }

    // MARK: - Impact Burst
    private func impactBurst(at pos: CGPoint, elapsed: Double) -> some View {
        let p = min(1.0, elapsed / 0.6)
        return ZStack {
            Circle().stroke(Color.white.opacity(max(0, 1 - p * 1.3)), lineWidth: max(0.5, 5 - p * 5))
                .frame(width: 20 + p * 180, height: 20 + p * 180)
            Circle().fill(RadialGradient(colors: [
                Color.white.opacity(max(0, 1 - p * 0.8)),
                Color.yellow.opacity(max(0, 0.8 - p)),
                Color.clear
            ], center: .center, startRadius: 0, endRadius: 40 + p * 50))
            .frame(width: 120 + p * 80, height: 120 + p * 80)
            ForEach(0..<16, id: \.self) { i in
                let a = Double(i) * .pi / 8.0 + p * 1.5
                let d = p * (50.0 + Double(i % 3) * 25.0)
                let sparkColors: [Color] = [.white, .yellow, .orange, .red]
                let sparkOpacity = max(0.0, 1.0 - p * 1.4)
                let sparkSize = max(1.0, 6.0 - p * 6.0)
                Circle().fill(sparkColors[i % 4].opacity(sparkOpacity))
                    .frame(width: sparkSize, height: sparkSize)
                    .offset(x: CGFloat(Foundation.cos(a) * d), y: CGFloat(Foundation.sin(a) * d))
            }
        }
        .position(pos)
    }

    // MARK: - Landing Ripple
    private func landingRipple(at pos: CGPoint, progress p: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let delay = Double(i) * 0.15
                let rp = max(0, min(1, (p - delay) / 0.4))
                Circle().stroke(Color.green.opacity(max(0, 0.5 - rp * 0.5)), lineWidth: max(0.5, 2.5 - rp * 2.5))
                    .frame(width: rp * 50 + 5, height: rp * 50 + 5)
            }
        }.position(pos)
    }

    // MARK: - Style 0: Fire Comet
    private func drawFireComet(context: GraphicsContext, points: [TrajectoryDetector.TrajectoryPoint], size: CGSize) {
        let total = Double(points.count)
        // Glow
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            context.stroke(p, with: .color(Color.orange.opacity(max(0.03, 0.25 - s * 0.2))), lineWidth: 22 - s * 14)
        }
        // Core
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            let c: Color = s < 0.2 ? .red : s < 0.5 ? .orange : s < 0.8 ? .yellow : .white
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            context.stroke(p, with: .color(c.opacity(max(0.4, 1 - s * 0.5))),
                          style: StrokeStyle(lineWidth: 7 - s * 4, lineCap: .round))
        }
        drawBallHead(context: context, points: points, size: size, color: .orange)
    }

    // MARK: - Style 1: Neon Laser
    private func drawNeonLaser(context: GraphicsContext, points: [TrajectoryDetector.TrajectoryPoint], size: CGSize) {
        let total = Double(points.count)
        let neonGreen = Color(red: 0, green: 1, blue: 0.4)
        // Outer glow
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            context.stroke(p, with: .color(neonGreen.opacity(0.15 - s * 0.1)), lineWidth: 18)
        }
        // Sharp core
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            context.stroke(p, with: .color(neonGreen.opacity(max(0.5, 1 - s * 0.4))),
                          style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        // White center
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            context.stroke(p, with: .color(Color.white.opacity(max(0.3, 0.8 - s * 0.5))), lineWidth: 1)
        }
        drawBallHead(context: context, points: points, size: size, color: neonGreen)
    }

    // MARK: - Style 2: Thunder Bolt
    private func drawThunderBolt(context: GraphicsContext, points: [TrajectoryDetector.TrajectoryPoint], size: CGSize) {
        let total = Double(points.count)
        // Electric glow
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            context.stroke(p, with: .color(Color.cyan.opacity(0.2 - s * 0.15)), lineWidth: 20)
        }
        // Jagged bolt core
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            let jx = CGFloat(Foundation.sin(Double(i) * 3.7)) * 3
            let jy = CGFloat(Foundation.cos(Double(i) * 2.3)) * 3
            var p = Path(); p.move(to: CGPoint(x: prev.x + jx, y: prev.y + jy))
            p.addLine(to: CGPoint(x: curr.x - jx, y: curr.y - jy))
            let c: Color = i % 3 == 0 ? .white : .cyan
            context.stroke(p, with: .color(c.opacity(max(0.5, 1 - s * 0.4))),
                          style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        drawBallHead(context: context, points: points, size: size, color: .cyan)
    }

    // MARK: - Style 3: Sakura Trail
    private func drawSakuraTrail(context: GraphicsContext, points: [TrajectoryDetector.TrajectoryPoint], size: CGSize) {
        let total = Double(points.count)
        let sakura = Color(red: 1, green: 0.7, blue: 0.8)
        // Soft glow
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            context.stroke(p, with: .color(sakura.opacity(0.2 - s * 0.15)), lineWidth: 16)
        }
        // Core
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            context.stroke(p, with: .color(sakura.opacity(max(0.3, 0.9 - s * 0.5))),
                          style: StrokeStyle(lineWidth: 5 - s * 3, lineCap: .round))
        }
        // Petal dots
        for i in stride(from: 0, to: points.count, by: 4) {
            let pos = pt(points[i].position, size)
            let s = Double(i) / total
            let offset = CGFloat(Foundation.sin(Double(i) * 1.3)) * 8
            context.fill(Path(ellipseIn: CGRect(x: pos.x + offset - 3, y: pos.y - 3, width: 6, height: 6)),
                        with: .color(Color.white.opacity(max(0.1, 0.6 - s * 0.5))))
        }
        drawBallHead(context: context, points: points, size: size, color: sakura)
    }

    // MARK: - Style 4: Gold Ribbon
    private func drawGoldRibbon(context: GraphicsContext, points: [TrajectoryDetector.TrajectoryPoint], size: CGSize) {
        let total = Double(points.count)
        let gold = Color(red: 1, green: 0.84, blue: 0)
        // Wide ribbon
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            let wave = CGFloat(Foundation.sin(Double(i) * 0.3)) * 4
            var p = Path()
            p.move(to: CGPoint(x: prev.x, y: prev.y + wave))
            p.addLine(to: CGPoint(x: curr.x, y: curr.y - wave))
            context.stroke(p, with: .color(gold.opacity(max(0.3, 0.9 - s * 0.5))),
                          style: StrokeStyle(lineWidth: 8 - s * 5, lineCap: .round))
        }
        // Shimmer
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            context.stroke(p, with: .color(Color.white.opacity(max(0.1, 0.5 - s * 0.4))), lineWidth: 1.5)
        }
        drawBallHead(context: context, points: points, size: size, color: gold)
    }

    // MARK: - Style 5: Ice Crystal
    private func drawIceCrystal(context: GraphicsContext, points: [TrajectoryDetector.TrajectoryPoint], size: CGSize) {
        let total = Double(points.count)
        let ice = Color(red: 0.7, green: 0.9, blue: 1)
        // Frost glow
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            context.stroke(p, with: .color(ice.opacity(0.15 - s * 0.1)), lineWidth: 20)
        }
        // Crystalline segments
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            let c: Color = i % 2 == 0 ? ice : .white
            context.stroke(p, with: .color(c.opacity(max(0.4, 1 - s * 0.5))),
                          style: StrokeStyle(lineWidth: 4 - s * 2, lineCap: .round))
        }
        // Crystal dots
        for i in stride(from: 0, to: points.count, by: 6) {
            let pos = pt(points[i].position, size)
            context.fill(Path(ellipseIn: CGRect(x: pos.x - 2, y: pos.y - 2, width: 4, height: 4)),
                        with: .color(Color.white.opacity(0.7)))
        }
        drawBallHead(context: context, points: points, size: size, color: ice)
    }

    // MARK: - Style 6: Rainbow Arc
    private func drawRainbowArc(context: GraphicsContext, points: [TrajectoryDetector.TrajectoryPoint], size: CGSize) {
        let total = Double(points.count)
        let rainbowColors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple]
        // Wide rainbow
        for i in 1..<points.count {
            let s = Double(i) / total
            let colorIdx = Int(s * Double(rainbowColors.count - 1))
            let color = rainbowColors[min(colorIdx, rainbowColors.count - 1)]
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            // Glow
            var pg = Path(); pg.move(to: prev); pg.addLine(to: curr)
            context.stroke(pg, with: .color(color.opacity(0.15)), lineWidth: 16)
            // Core
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            context.stroke(p, with: .color(color.opacity(max(0.5, 1 - s * 0.3))),
                          style: StrokeStyle(lineWidth: 5 - s * 2.5, lineCap: .round))
        }
        drawBallHead(context: context, points: points, size: size, color: .white)
    }

    // MARK: - Style 7: Phantom Smoke
    private func drawPhantomSmoke(context: GraphicsContext, points: [TrajectoryDetector.TrajectoryPoint], size: CGSize) {
        let total = Double(points.count)
        // Multiple offset layers for smoke effect
        for layer in 0..<3 {
            let layerOff = CGFloat(layer - 1) * 3
            for i in 1..<points.count {
                let s = Double(i) / total
                let prev = pt(points[i-1].position, size)
                let curr = pt(points[i].position, size)
                let smokeOff = CGFloat(Foundation.sin(Double(i) * 0.8 + Double(layer))) * (4 + layerOff)
                var p = Path()
                p.move(to: CGPoint(x: prev.x + smokeOff, y: prev.y))
                p.addLine(to: CGPoint(x: curr.x - smokeOff, y: curr.y))
                let opacity = max(0.05, (0.4 - Double(layer) * 0.1) - s * 0.3)
                context.stroke(p, with: .color(Color.white.opacity(opacity)),
                              style: StrokeStyle(lineWidth: CGFloat(10 - layer * 3) - s * 4, lineCap: .round))
            }
        }
        drawBallHead(context: context, points: points, size: size, color: .gray)
    }

    // MARK: - Style 8: Star Dust
    private func drawStarDust(context: GraphicsContext, points: [TrajectoryDetector.TrajectoryPoint], size: CGSize) {
        let total = Double(points.count)
        let starYellow = Color(red: 1, green: 0.95, blue: 0.6)
        // Soft trail
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            context.stroke(p, with: .color(starYellow.opacity(max(0.2, 0.7 - s * 0.4))),
                          style: StrokeStyle(lineWidth: 3 - s * 1.5, lineCap: .round))
        }
        // Scattered stars
        for i in stride(from: 0, to: points.count, by: 2) {
            let pos = pt(points[i].position, size)
            let s = Double(i) / total
            let ox = CGFloat(Foundation.sin(Double(i) * 2.1)) * 12
            let oy = CGFloat(Foundation.cos(Double(i) * 1.7)) * 12
            let starSize = max(1.0, 5.0 - s * 4.0)
            context.fill(Path(ellipseIn: CGRect(x: pos.x + ox - starSize/2, y: pos.y + oy - starSize/2,
                                                width: starSize, height: starSize)),
                        with: .color(starYellow.opacity(max(0.1, 0.8 - s * 0.6))))
        }
        drawBallHead(context: context, points: points, size: size, color: starYellow)
    }

    // MARK: - Style 9: Plasma Beam
    private func drawPlasmaBeam(context: GraphicsContext, points: [TrajectoryDetector.TrajectoryPoint], size: CGSize) {
        let total = Double(points.count)
        let plasma = Color(red: 0.8, green: 0.2, blue: 1)
        // Wide plasma glow
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            context.stroke(p, with: .color(plasma.opacity(0.2 - s * 0.15)), lineWidth: 24)
        }
        // Beam core
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            let c: Color = s < 0.3 ? .white : s < 0.6 ? Color(red: 0.9, green: 0.5, blue: 1) : plasma
            context.stroke(p, with: .color(c.opacity(max(0.5, 1 - s * 0.4))),
                          style: StrokeStyle(lineWidth: 6 - s * 3.5, lineCap: .round))
        }
        // Inner white hot
        for i in 1..<points.count {
            let s = Double(i) / total
            let prev = pt(points[i-1].position, size); let curr = pt(points[i].position, size)
            var p = Path(); p.move(to: prev); p.addLine(to: curr)
            context.stroke(p, with: .color(Color.white.opacity(max(0.1, 0.6 - s * 0.5))), lineWidth: 1.5)
        }
        drawBallHead(context: context, points: points, size: size, color: plasma)
    }

    // MARK: - Ball Head (shared)
    private func drawBallHead(context: GraphicsContext, points: [TrajectoryDetector.TrajectoryPoint],
                              size: CGSize, color: Color) {
        guard let last = points.last else { return }
        let pos = pt(last.position, size)
        // Glow
        context.fill(Path(ellipseIn: CGRect(x: pos.x - 18, y: pos.y - 18, width: 36, height: 36)),
                    with: .color(color.opacity(0.3)))
        // Ball
        context.fill(Path(ellipseIn: CGRect(x: pos.x - 6, y: pos.y - 6, width: 12, height: 12)),
                    with: .color(.white))
    }

    // MARK: - Helper
    private func pt(_ p: CGPoint, _ s: CGSize? = nil) -> CGPoint {
        let size = s ?? viewSize
        return CGPoint(x: p.x * size.width, y: p.y * size.height)
    }
}
