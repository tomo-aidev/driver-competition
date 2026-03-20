import UIKit

/// Shared trajectory rendering logic used by both live camera and video playback.
/// Draws tapered Catmull-Rom spline segments with glow effect.
final class TrajectoryRenderer {

    let containerLayer = CALayer()

    private let trajectoryColor = UIColor(
        red: 255/255, green: 115/255, blue: 81/255, alpha: 1.0 // #FF7351
    )

    func updateTrajectory(points: [CGPoint]) {
        containerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard points.count >= 2 else { return }

        let maxWidth = DetectionConfig.trajectoryLineWidth
        let minWidth: CGFloat = 2.0
        let count = points.count

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for i in 1..<count {
            let p1 = points[i - 1]
            let p2 = points[i]

            let ratio = CGFloat(i) / CGFloat(count)
            let width = maxWidth - (maxWidth - minWidth) * ratio

            let alpha: CGFloat
            if ratio < 0.1 {
                alpha = 0.5 + ratio * 5.0
            } else {
                alpha = 1.0
            }

            let segment = CAShapeLayer()
            let path = UIBezierPath()

            if count > 3 {
                let p0 = points[max(i - 2, 0)]
                let p3 = points[min(i + 1, count - 1)]

                path.move(to: p1)
                let cp1 = CGPoint(
                    x: p1.x + (p2.x - p0.x) / 6.0,
                    y: p1.y + (p2.y - p0.y) / 6.0
                )
                let cp2 = CGPoint(
                    x: p2.x - (p3.x - p1.x) / 6.0,
                    y: p2.y - (p3.y - p1.y) / 6.0
                )
                path.addCurve(to: p2, controlPoint1: cp1, controlPoint2: cp2)
            } else {
                path.move(to: p1)
                path.addLine(to: p2)
            }

            segment.path = path.cgPath
            segment.strokeColor = trajectoryColor.withAlphaComponent(alpha).cgColor
            segment.fillColor = nil
            segment.lineWidth = width
            segment.lineCap = .round
            segment.lineJoin = .round
            segment.shadowColor = trajectoryColor.cgColor
            segment.shadowRadius = 6
            segment.shadowOpacity = Float(alpha * 0.8)
            segment.shadowOffset = .zero

            containerLayer.addSublayer(segment)
        }

        CATransaction.commit()
    }
}
