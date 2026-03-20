import SwiftUI
import AVFoundation

/// Video player with trajectory overlay for analyzed golf shots
struct VideoPlayerView: UIViewRepresentable {
    let videoURL: URL
    let trajectoryPoints: [TrajectoryPoint]

    func makeUIView(context: Context) -> VideoPlayerUIView {
        let view = VideoPlayerUIView(url: videoURL)
        return view
    }

    func updateUIView(_ uiView: VideoPlayerUIView, context: Context) {
        let screenPoints = trajectoryPoints.map { $0.position }
        uiView.updateTrajectory(points: screenPoints)
    }
}

final class VideoPlayerUIView: UIView {

    private let playerLayer = AVPlayerLayer()
    private let renderer = TrajectoryRenderer()
    private var player: AVPlayer?

    init(url: URL) {
        super.init(frame: .zero)

        player = AVPlayer(url: url)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
        layer.addSublayer(renderer.containerLayer)

        // Loop playback
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.player?.seek(to: .zero)
            self?.player?.play()
        }

        player?.play()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
        renderer.containerLayer.frame = bounds
    }

    func updateTrajectory(points: [CGPoint]) {
        renderer.updateTrajectory(points: points)
    }

    deinit {
        player?.pause()
        NotificationCenter.default.removeObserver(self)
    }
}
