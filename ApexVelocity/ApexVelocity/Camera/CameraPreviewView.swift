import SwiftUI
import AVFoundation

/// UIKit-backed camera preview layer with trajectory overlay, wrapped for SwiftUI
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var trajectoryPoints: [TrajectoryPoint]
    var onPreviewLayerReady: ((AVCaptureVideoPreviewLayer) -> Void)?

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        DispatchQueue.main.async {
            onPreviewLayerReady?(view.previewLayer)
        }
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        let screenPoints = trajectoryPoints.map { $0.position }
        uiView.updateTrajectory(points: screenPoints)
    }
}

final class CameraPreviewUIView: UIView {

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    private let renderer = TrajectoryRenderer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(renderer.containerLayer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        layer.addSublayer(renderer.containerLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderer.containerLayer.frame = bounds
    }

    func updateTrajectory(points: [CGPoint]) {
        renderer.updateTrajectory(points: points)
    }
}
