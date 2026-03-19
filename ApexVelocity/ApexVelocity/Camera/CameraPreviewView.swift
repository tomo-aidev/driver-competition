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
        // Notify caller when preview layer is available for coordinate conversion
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

    // MARK: - Layers

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    private let trajectoryLayer = CAShapeLayer()
    private let tipLayer = CALayer()

    private let trajectoryColor = UIColor(
        red: 255/255, green: 115/255, blue: 81/255, alpha: 1.0 // #FF7351
    )

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupTrajectoryLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTrajectoryLayer()
    }

    private func setupTrajectoryLayer() {
        // Main trajectory line
        trajectoryLayer.strokeColor = trajectoryColor.cgColor
        trajectoryLayer.fillColor = nil
        trajectoryLayer.lineWidth = DetectionConfig.trajectoryLineWidth
        trajectoryLayer.lineCap = .round
        trajectoryLayer.lineJoin = .round
        trajectoryLayer.shadowColor = trajectoryColor.cgColor
        trajectoryLayer.shadowRadius = 8
        trajectoryLayer.shadowOpacity = 0.9
        trajectoryLayer.shadowOffset = .zero
        layer.addSublayer(trajectoryLayer)

        // Tip glow ball (leading edge emphasis)
        let tipSize: CGFloat = 16
        tipLayer.bounds = CGRect(x: 0, y: 0, width: tipSize, height: tipSize)
        tipLayer.cornerRadius = tipSize / 2
        tipLayer.backgroundColor = UIColor.white.cgColor
        tipLayer.shadowColor = trajectoryColor.cgColor
        tipLayer.shadowRadius = 12
        tipLayer.shadowOpacity = 1.0
        tipLayer.shadowOffset = .zero
        tipLayer.isHidden = true
        layer.addSublayer(tipLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        trajectoryLayer.frame = bounds
    }

    // MARK: - Trajectory Rendering

    func updateTrajectory(points: [CGPoint]) {
        guard points.count >= 2 else {
            trajectoryLayer.path = nil
            tipLayer.isHidden = true
            return
        }

        let path = UIBezierPath()
        path.move(to: points[0])

        if points.count == 2 {
            path.addLine(to: points[1])
        } else {
            // Catmull-Rom spline interpolation for smooth curves
            for i in 1..<points.count {
                let p0 = points[max(i - 2, 0)]
                let p1 = points[i - 1]
                let p2 = points[i]
                let p3 = points[min(i + 1, points.count - 1)]

                let cp1 = CGPoint(
                    x: p1.x + (p2.x - p0.x) / 6.0,
                    y: p1.y + (p2.y - p0.y) / 6.0
                )
                let cp2 = CGPoint(
                    x: p2.x - (p3.x - p1.x) / 6.0,
                    y: p2.y - (p3.y - p1.y) / 6.0
                )

                path.addCurve(to: p2, controlPoint1: cp1, controlPoint2: cp2)
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trajectoryLayer.path = path.cgPath

        // Position tip glow at the leading point
        if let lastPoint = points.last {
            tipLayer.isHidden = false
            tipLayer.position = lastPoint
        }

        CATransaction.commit()
    }
}
