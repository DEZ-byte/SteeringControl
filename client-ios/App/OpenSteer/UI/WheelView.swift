import SwiftUI
import UIKit
import OpenSteerCore

/// The rotating wheel graphic.
///
/// It drives itself. A display link reads the latest finished motion snapshot and
/// sets one `CALayer` transform, which never goes through SwiftUI's diffing and
/// never republishes an observable object. Pushing 120 updates a second through
/// `@Published` would re-evaluate the whole view tree on every frame for a single
/// rotation value.
struct WheelView: UIViewRepresentable {
    let store: SnapshotStore
    /// Phone rotation, lock to lock. The marker turns red once on the stops.
    let degreesOfRotation: Double

    func makeUIView(context: Context) -> WheelLayerView {
        let view = WheelLayerView()
        view.store = store
        view.degreesOfRotation = degreesOfRotation
        view.begin()
        return view
    }

    func updateUIView(_ view: WheelLayerView, context: Context) {
        view.degreesOfRotation = degreesOfRotation
    }

    static func dismantleUIView(_ view: WheelLayerView, coordinator: ()) {
        view.end()
    }

    final class WheelLayerView: UIView {
        var store: SnapshotStore?
        var degreesOfRotation: Double = 900

        private let rim = CAShapeLayer()
        private let spokes = CAShapeLayer()
        private let marker = CAShapeLayer()
        private var driver: DisplayLinkDriver?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear

            for shape in [rim, spokes] {
                shape.fillColor = UIColor.clear.cgColor
                shape.lineCap = .round
                layer.addSublayer(shape)
            }

            rim.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
            rim.lineWidth = 10
            spokes.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
            spokes.lineWidth = 6

            // The top marker is what makes the rotation readable at a glance. A
            // plain circle turning looks identical at every angle.
            marker.fillColor = UIColor.systemOrange.cgColor
            layer.addSublayer(marker)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        func begin() {
            guard driver == nil else { return }
            let driver = DisplayLinkDriver { [weak self] link in
                guard let self else { return }
                self.applyLatestAngle()
                self.store?.publishDisplayInterval(
                    (link.targetTimestamp - link.timestamp) * 1000.0)
            }
            driver.start()
            self.driver = driver
        }

        func end() {
            driver?.stop()
            driver = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            rebuildPaths()
        }

        private func rebuildPaths() {
            let side = min(bounds.width, bounds.height)
            guard side > 20 else { return }

            let centre = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = side / 2 - 12

            for shape in [rim, spokes, marker] {
                // Rotating about the centre of the view, not the corner of the
                // layer, which is where a default anchor point would put it.
                shape.bounds = bounds
                shape.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                shape.position = centre
            }

            rim.path = UIBezierPath(arcCenter: centre, radius: radius,
                                    startAngle: 0, endAngle: .pi * 2,
                                    clockwise: true).cgPath

            let spokePath = UIBezierPath()
            for index in 0..<3 {
                let angle = Double(index) * (2 * .pi / 3) + .pi / 2
                spokePath.move(to: centre)
                spokePath.addLine(to: CGPoint(x: centre.x + cos(angle) * radius,
                                              y: centre.y + sin(angle) * radius))
            }
            spokes.path = spokePath.cgPath

            let markerSize: CGFloat = 16
            marker.path = UIBezierPath(ovalIn: CGRect(
                x: centre.x - markerSize / 2,
                y: centre.y - radius - markerSize / 2,
                width: markerSize,
                height: markerSize)).cgPath
        }

        private func applyLatestAngle() {
            guard let snapshot = store?.readMotion() else { return }

            // The driver turns the phone anticlockwise to steer left, and the
            // wheel on screen has to follow the hands exactly. Any smoothing here
            // would show up as the graphic lagging the real thing.
            let radians = CGFloat(snapshot.thetaDegrees * degreesToRadians)
            let transform = CATransform3DMakeRotation(radians, 0, 0, 1)

            // No implicit animation. CALayer would otherwise interpolate every
            // change over a quarter second, which at 120 Hz means the graphic is
            // permanently a quarter second behind.
            // On the stops. Worth showing, because the wheel keeps turning in the
            // driver's hands after the axis has stopped responding.
            let atLock = abs(snapshot.thetaDegrees) >= degreesOfRotation / 2
            let markerColour = atLock ? UIColor.systemRed : UIColor.systemOrange

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rim.transform = transform
            spokes.transform = transform
            marker.transform = transform
            marker.fillColor = markerColour.cgColor
            CATransaction.commit()
        }
    }
}
