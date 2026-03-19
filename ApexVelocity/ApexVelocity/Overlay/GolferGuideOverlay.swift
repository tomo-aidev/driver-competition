import SwiftUI

/// Overlay showing golfer silhouettes and ball position guide
/// Matches stitch _3 design: L-HANDED silhouette, ball position circle, R-HANDED silhouette
struct GolferGuideOverlay: View {
    var isRecording: Bool

    @State private var pingScale: CGFloat = 1.0
    @State private var pingOpacity: Double = 0.6

    var body: some View {
        HStack(spacing: 0) {
            // L-HANDED silhouette
            golferSilhouette(mirrored: false)
                .frame(maxWidth: .infinity)

            // Ball position guide
            ballPositionGuide
                .frame(width: 120)

            // R-HANDED silhouette
            golferSilhouette(mirrored: true)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .opacity(isRecording ? 0 : 1)
        .animation(.easeInOut(duration: 0.4), value: isRecording)
        .allowsHitTesting(false)
    }

    // MARK: - Ball Position Guide

    private var ballPositionGuide: some View {
        VStack(spacing: 12) {
            ZStack {
                // Ping animation ring
                Circle()
                    .stroke(AppTheme.primaryContainer.opacity(0.2), lineWidth: 1.5)
                    .frame(width: 80 * pingScale, height: 80 * pingScale)
                    .opacity(pingOpacity)

                // Main circle
                Circle()
                    .stroke(AppTheme.primaryContainer.opacity(0.4), lineWidth: 2)
                    .frame(width: 80, height: 80)

                // Arrow up
                Image(systemName: "arrow.up")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(AppTheme.primaryFixed)
            }
            .onAppear {
                withAnimation(
                    .easeOut(duration: 1.5)
                    .repeatForever(autoreverses: false)
                ) {
                    pingScale = 1.4
                    pingOpacity = 0
                }
            }

            // Label
            Text(String(localized: "ball_position", defaultValue: "BALL POSITION"))
                .font(.custom("Inter-Medium", size: 9, relativeTo: .caption2))
                .tracking(2)
                .foregroundStyle(AppTheme.onSurfaceVariant)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(AppTheme.surfaceContainerLowest.opacity(0.7))
                .clipShape(Capsule())
        }
    }

    // MARK: - Golfer Silhouette

    private func golferSilhouette(mirrored: Bool) -> some View {
        VStack(spacing: 6) {
            GolferShape()
                .stroke(Color.white.opacity(0.3), lineWidth: 0.8)
                .frame(width: 80, height: 180)
                .scaleEffect(x: mirrored ? -1 : 1, y: 1)

            Text(mirrored
                 ? String(localized: "r_handed", defaultValue: "R-HANDED")
                 : String(localized: "l_handed", defaultValue: "L-HANDED"))
                .font(.custom("Inter-Medium", size: 9, relativeTo: .caption2))
                .tracking(2)
                .foregroundStyle(AppTheme.onSurfaceVariant.opacity(0.5))
        }
    }
}

// MARK: - Golfer Shape (SwiftUI Path)

/// Simplified golfer silhouette drawn with Path
struct GolferShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        // Head
        let headCenter = CGPoint(x: w * 0.45, y: h * 0.08)
        let headRadius = w * 0.08
        path.addEllipse(in: CGRect(
            x: headCenter.x - headRadius,
            y: headCenter.y - headRadius,
            width: headRadius * 2,
            height: headRadius * 2
        ))

        // Neck to shoulders
        path.move(to: CGPoint(x: w * 0.45, y: h * 0.12))
        path.addLine(to: CGPoint(x: w * 0.45, y: h * 0.18))

        // Shoulders
        path.move(to: CGPoint(x: w * 0.25, y: h * 0.18))
        path.addLine(to: CGPoint(x: w * 0.65, y: h * 0.18))

        // Torso
        path.move(to: CGPoint(x: w * 0.45, y: h * 0.18))
        path.addLine(to: CGPoint(x: w * 0.45, y: h * 0.42))

        // Left arm (holding club)
        path.move(to: CGPoint(x: w * 0.25, y: h * 0.18))
        path.addQuadCurve(
            to: CGPoint(x: w * 0.35, y: h * 0.38),
            control: CGPoint(x: w * 0.18, y: h * 0.28)
        )

        // Right arm
        path.move(to: CGPoint(x: w * 0.65, y: h * 0.18))
        path.addQuadCurve(
            to: CGPoint(x: w * 0.38, y: h * 0.38),
            control: CGPoint(x: w * 0.60, y: h * 0.30)
        )

        // Hands together (grip)
        path.move(to: CGPoint(x: w * 0.35, y: h * 0.38))
        path.addLine(to: CGPoint(x: w * 0.38, y: h * 0.38))

        // Club shaft
        path.move(to: CGPoint(x: w * 0.36, y: h * 0.38))
        path.addLine(to: CGPoint(x: w * 0.50, y: h * 0.68))

        // Club head
        path.move(to: CGPoint(x: w * 0.48, y: h * 0.67))
        path.addLine(to: CGPoint(x: w * 0.55, y: h * 0.70))

        // Left leg
        path.move(to: CGPoint(x: w * 0.45, y: h * 0.42))
        path.addQuadCurve(
            to: CGPoint(x: w * 0.30, y: h * 0.72),
            control: CGPoint(x: w * 0.38, y: h * 0.56)
        )
        // Left foot
        path.addLine(to: CGPoint(x: w * 0.22, y: h * 0.74))

        // Right leg
        path.move(to: CGPoint(x: w * 0.45, y: h * 0.42))
        path.addQuadCurve(
            to: CGPoint(x: w * 0.55, y: h * 0.72),
            control: CGPoint(x: w * 0.50, y: h * 0.56)
        )
        // Right foot
        path.addLine(to: CGPoint(x: w * 0.63, y: h * 0.74))

        return path
    }
}
