import SwiftUI

struct HistoryView: View {
    @ObservedObject var shotStore: ShotStore
    @State private var selectedShot: ShotRecord?

    var body: some View {
        ZStack {
            AppTheme.surface
                .ignoresSafeArea()

            if shotStore.shots.isEmpty {
                emptyState
            } else {
                shotList
            }
        }
        .fullScreenCover(item: $selectedShot) { shot in
            ShotDetailView(shot: shot, shotStore: shotStore)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(AppTheme.onSurfaceVariant.opacity(0.4))

            Text(String(localized: "no_shots_title", defaultValue: "No shots yet"))
                .font(.custom("SpaceGrotesk-Bold", size: 20, relativeTo: .title3))
                .foregroundStyle(AppTheme.onSurface)

            Text(String(localized: "no_shots_description", defaultValue: "Record a shot or import a video to start analyzing"))
                .font(.custom("Inter-Regular", size: 14, relativeTo: .body))
                .foregroundStyle(AppTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Shot List

    private var shotList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(shotStore.shots) { shot in
                    ShotCard(shot: shot, shotStore: shotStore)
                        .onTapGesture {
                            selectedShot = shot
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 100)
        }
    }
}

// MARK: - Shot Card

struct ShotCard: View {
    let shot: ShotRecord
    let shotStore: ShotStore

    var body: some View {
        HStack(spacing: 14) {
            // Thumbnail
            thumbnailView
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            // Info
            VStack(alignment: .leading, spacing: 6) {
                Text(formattedDate)
                    .font(.custom("SpaceGrotesk-Bold", size: 16, relativeTo: .body))
                    .foregroundStyle(AppTheme.onSurface)

                // Status
                HStack(spacing: 6) {
                    statusIcon
                    Text(statusText)
                        .font(.custom("Inter-Medium", size: 12, relativeTo: .caption))
                        .foregroundStyle(statusColor)
                }

                // Metrics preview
                if let metrics = shot.metrics {
                    HStack(spacing: 16) {
                        if let angle = metrics.estimatedLaunchAngle {
                            metricLabel(value: String(format: "%.0f°", angle), label: "ANGLE")
                        }
                        metricLabel(value: "\(metrics.detectedFrameCount)", label: "DETECT")
                        metricLabel(
                            value: String(format: "%.0f%%", metrics.analysisConfidence * 100),
                            label: "CONF"
                        )
                    }
                }
            }

            Spacer()

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.onSurfaceVariant.opacity(0.4))
        }
        .padding(12)
        .background(AppTheme.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppTheme.outlineVariant.opacity(0.1), lineWidth: 1)
        )
    }

    private var thumbnailView: some View {
        Group {
            if let thumbURL = shotStore.thumbnailURL(for: shot),
               let data = try? Data(contentsOf: thumbURL),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(AppTheme.surfaceContainerHighest)
                    .overlay {
                        Image(systemName: "film")
                            .foregroundStyle(AppTheme.onSurfaceVariant.opacity(0.4))
                    }
            }
        }
    }

    private var statusIcon: some View {
        Group {
            switch shot.analysisStatus {
            case .pending:
                Image(systemName: "clock")
                    .foregroundStyle(AppTheme.onSurfaceVariant)
            case .analyzing:
                ProgressView()
                    .scaleEffect(0.6)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.primaryFixed)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppTheme.error)
            }
        }
        .font(.system(size: 12))
    }

    private var statusText: String {
        switch shot.analysisStatus {
        case .pending:
            return String(localized: "status_pending", defaultValue: "Pending")
        case .analyzing:
            return String(localized: "status_analyzing", defaultValue: "Analyzing...")
        case .completed:
            return String(localized: "status_completed", defaultValue: "Analyzed")
        case .failed:
            return String(localized: "status_failed", defaultValue: "Failed")
        }
    }

    private var statusColor: Color {
        switch shot.analysisStatus {
        case .pending: return AppTheme.onSurfaceVariant
        case .analyzing: return AppTheme.secondary
        case .completed: return AppTheme.primaryFixed
        case .failed: return AppTheme.error
        }
    }

    private func metricLabel(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.custom("SpaceGrotesk-Bold", size: 13, relativeTo: .caption))
                .foregroundStyle(AppTheme.primaryFixed)
                .monospacedDigit()
            Text(label)
                .font(.custom("Inter-Medium", size: 7, relativeTo: .caption2))
                .tracking(1)
                .foregroundStyle(AppTheme.onSurfaceVariant)
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: shot.createdAt)
    }
}
