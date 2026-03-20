import SwiftUI

/// Setup guide overlay: fixed ball position target + vertical angle indicator on the right
struct SetupGuideOverlay: View {
    var isRecording: Bool
    var pitchDegrees: Double
    var isAngleGood: Bool
    @Binding var ballPosition: CGPoint

    @State private var pingScale: CGFloat = 1.0
    @State private var pingOpacity: Double = 0.6

    var body: some View {
        ZStack {
            // Ball position target (fixed, user moves phone to align)
            ballPositionTarget
                .position(ballPosition)

            // Angle indicator (right side, near ball position)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    verticalAngleIndicator
                        .padding(.trailing, 24)
                        .padding(.bottom, 160)
                }
            }
        }
        .opacity(isRecording ? 0 : 1)
        .animation(.easeInOut(duration: 0.4), value: isRecording)
        .allowsHitTesting(false)
    }

    // MARK: - Vertical Angle Indicator

    private var verticalAngleIndicator: some View {
        VStack(spacing: 8) {
            // "Tilt up" label
            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AppTheme.onSurfaceVariant.opacity(0.4))

            // Vertical bar with current angle dot
            ZStack {
                // Track background
                RoundedRectangle(cornerRadius: 3)
                    .fill(AppTheme.surfaceContainerHighest.opacity(0.6))
                    .frame(width: 6, height: 120)

                // Good range (center zone)
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppTheme.primaryFixed.opacity(0.15))
                    .frame(width: 6, height: 30)
                    .offset(y: -5) // slightly above center for 0-15° range

                // Current angle dot
                Circle()
                    .fill(isAngleGood ? AppTheme.primaryFixed : AppTheme.secondary)
                    .frame(width: 14, height: 14)
                    .shadow(
                        color: (isAngleGood ? AppTheme.primaryFixed : AppTheme.secondary).opacity(0.6),
                        radius: 6
                    )
                    .offset(y: angleDotOffset)
            }
            .frame(width: 14, height: 120)

            // "Tilt down" label
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AppTheme.onSurfaceVariant.opacity(0.4))

            // Angle text
            Text(String(format: "%.0f°", pitchDegrees))
                .font(.custom("SpaceGrotesk-Bold", size: 13, relativeTo: .caption))
                .foregroundStyle(isAngleGood ? AppTheme.primaryFixed : AppTheme.secondary)
                .monospacedDigit()

            // Status text
            Text(angleStatusText)
                .font(.custom("Inter-Medium", size: 9, relativeTo: .caption2))
                .foregroundStyle(isAngleGood ? AppTheme.primaryFixed : AppTheme.secondary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(AppTheme.surfaceContainerLowest.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    (isAngleGood ? AppTheme.primaryFixed : AppTheme.secondary).opacity(0.2),
                    lineWidth: 1
                )
        )
    }

    /// Map pitch degrees to vertical offset on the bar.
    /// Positive pitch (up) = dot moves up, negative = dot moves down.
    private var angleDotOffset: CGFloat {
        let clampedPitch = max(-30, min(30, pitchDegrees))
        // -30° → +55 (bottom), 0° → -5 (near center), +30° → -55 (top)
        return CGFloat(-clampedPitch / 30.0) * 55.0 - 5.0
    }

    private var angleStatusText: String {
        if isAngleGood {
            return String(localized: "angle_good", defaultValue: "OK")
        } else if pitchDegrees < 80 {
            return String(localized: "angle_tilt_up", defaultValue: "Tilt up")
        } else {
            return String(localized: "angle_tilt_down", defaultValue: "Tilt down")
        }
    }

    // MARK: - Ball Position Target (Fixed)

    private var ballPositionTarget: some View {
        VStack(spacing: 8) {
            ZStack {
                // Ping animation ring
                Circle()
                    .stroke(AppTheme.primaryContainer.opacity(0.2), lineWidth: 1.5)
                    .frame(width: 60 * pingScale, height: 60 * pingScale)
                    .opacity(pingOpacity)

                // Crosshair circle
                Circle()
                    .stroke(AppTheme.primaryFixed.opacity(0.6), lineWidth: 2)
                    .frame(width: 60, height: 60)

                // Crosshair lines
                Group {
                    Rectangle().frame(width: 1, height: 20)
                    Rectangle().frame(width: 20, height: 1)
                }
                .foregroundStyle(AppTheme.primaryFixed.opacity(0.4))

                // Center dot
                Circle()
                    .fill(AppTheme.primaryFixed)
                    .frame(width: 6, height: 6)
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
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(AppTheme.surfaceContainerLowest.opacity(0.7))
                .clipShape(Capsule())
        }
    }
}
