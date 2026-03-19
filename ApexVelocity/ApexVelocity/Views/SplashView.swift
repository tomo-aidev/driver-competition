import SwiftUI

struct SplashView: View {
    @State private var progress: CGFloat = 0
    @State private var showContent = false

    var body: some View {
        ZStack {
            // Background
            AppTheme.surface
                .ignoresSafeArea()

            // Subtle radial gradients (mesh background)
            RadialGradient(
                colors: [AppTheme.primary.opacity(0.03), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 400
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [AppTheme.primaryFixed.opacity(0.05), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 400
            )
            .ignoresSafeArea()

            // Decorative crossing lines
            GeometryReader { geo in
                Path { path in
                    let cx = geo.size.width / 2
                    let cy = geo.size.height / 2
                    path.move(to: CGPoint(x: 0, y: cy - 50))
                    path.addLine(to: CGPoint(x: geo.size.width, y: cy + 50))
                }
                .stroke(AppTheme.outlineVariant.opacity(0.1), lineWidth: 1)

                Path { path in
                    let cx = geo.size.width / 2
                    let cy = geo.size.height / 2
                    path.move(to: CGPoint(x: 0, y: cy + 50))
                    path.addLine(to: CGPoint(x: geo.size.width, y: cy - 50))
                }
                .stroke(AppTheme.outlineVariant.opacity(0.1), lineWidth: 1)
            }
            .ignoresSafeArea()

            VStack {
                Spacer()

                // Logo & Branding
                VStack(spacing: 48) {
                    // Logo mark with corner markers
                    ZStack {
                        // Glow
                        RoundedRectangle(cornerRadius: 12)
                            .fill(AppTheme.primary.opacity(0.2))
                            .frame(width: 110, height: 110)
                            .blur(radius: 30)

                        // Main icon
                        RoundedRectangle(cornerRadius: 12)
                            .fill(AppTheme.primary)
                            .frame(width: 96, height: 96)
                            .shadow(color: AppTheme.primary.opacity(0.15), radius: 40)
                            .overlay {
                                Image(systemName: "gauge.open.with.lines.needle.33percent.and.arrowtriangle")
                                    .font(.system(size: 48, weight: .medium))
                                    .foregroundStyle(AppTheme.onPrimary)
                            }

                        // Corner precision markers
                        CornerMarkers()
                    }

                    // Brand text
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Text("APEX")
                                .font(.custom("SpaceGrotesk-Bold", size: 48, relativeTo: .largeTitle))
                                .foregroundStyle(AppTheme.onSurface)
                            Text("VELOCITY")
                                .font(.custom("SpaceGrotesk-Bold", size: 48, relativeTo: .largeTitle))
                                .foregroundStyle(AppTheme.primaryFixed)
                        }
                        .tracking(-2)

                        Text("アペックス・ベロシティ")
                            .font(.custom("Inter-Regular", size: 13, relativeTo: .caption))
                            .tracking(6)
                            .foregroundStyle(AppTheme.onSurfaceVariant)
                    }
                }
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)

                Spacer()

                // Bottom section
                VStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Rectangle()
                            .fill(AppTheme.primary)
                            .frame(width: 48, height: 2)

                        Text("Precision Lab Analytics")
                            .font(.custom("SpaceGrotesk-Medium", size: 22, relativeTo: .title3))
                            .foregroundStyle(AppTheme.onSurface)

                        Text("Next-Gen Swing Analysis Engine v1.0")
                            .font(.custom("Inter-Regular", size: 13, relativeTo: .caption))
                            .foregroundStyle(AppTheme.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Loading bar
                    VStack(alignment: .trailing, spacing: 16) {
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(AppTheme.surfaceContainerHighest)
                                .frame(height: 3)
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(AppTheme.primary)
                                        .frame(width: geo.size.width * progress, height: 3)
                                }
                        }
                        .frame(height: 3)

                        HStack(spacing: 8) {
                            Circle()
                                .fill(AppTheme.primary)
                                .frame(width: 6, height: 6)
                                .opacity(pulseOpacity)

                            Text(String(localized: "splash_calibrating", defaultValue: "SYSTEM CALIBRATING"))
                                .font(.custom("Inter-Regular", size: 10, relativeTo: .caption2))
                                .tracking(3)
                                .foregroundStyle(AppTheme.onSurfaceVariant)
                                .textCase(.uppercase)
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
                .opacity(showContent ? 1 : 0)
            }

            // Corner decals
            VStack {
                HStack {
                    Text("001 // PRO EDITION")
                        .font(.custom("Inter-Regular", size: 9, relativeTo: .caption2))
                        .tracking(0.5)
                        .foregroundStyle(AppTheme.outline.opacity(0.5))

                    Spacer()

                    VStack(alignment: .trailing) {
                        Text("Kinetic")
                        Text("Precision")
                    }
                    .font(.custom("Inter-Regular", size: 9, relativeTo: .caption2))
                    .tracking(3)
                    .foregroundStyle(AppTheme.outline.opacity(0.5))
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                Spacer()
            }
            .opacity(showContent ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                showContent = true
            }
            withAnimation(.easeInOut(duration: 2.0)) {
                progress = 0.85
            }
        }
    }

    private var pulseOpacity: Double {
        // Simple pulse via animation
        1.0
    }
}

private struct CornerMarkers: View {
    var body: some View {
        ZStack {
            // Top-left
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Rectangle().fill(AppTheme.primary).frame(width: 16, height: 2)
                    Spacer()
                }
                Rectangle().fill(AppTheme.primary).frame(width: 2, height: 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }

            // Bottom-right
            VStack(spacing: 0) {
                Spacer()
                Rectangle().fill(AppTheme.primary).frame(width: 2, height: 14)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                HStack(spacing: 0) {
                    Spacer()
                    Rectangle().fill(AppTheme.primary).frame(width: 16, height: 2)
                }
            }
        }
        .frame(width: 112, height: 112)
    }
}

#Preview {
    SplashView()
}
