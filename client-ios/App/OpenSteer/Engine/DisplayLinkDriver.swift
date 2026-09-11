import QuartzCore
import UIKit

/// Drives the on-screen wheel from the display's own refresh clock.
///
/// The steering loop runs at 120 Hz and never waits for the screen. The screen
/// pulls the latest finished snapshot whenever it is about to draw, which is what
/// keeps a slow frame from ever delaying a steering packet.
///
/// ProMotion needs two things together and gives 60 Hz if either is missing: the
/// `CADisableMinimumFrameDurationOnPhone` key in the Info.plist, and an explicit
/// frame rate range here. Asking for a preferred 120 with a floor of 80 lets iOS
/// drop the rate to save power when nothing is moving, without ever falling to
/// the 60 Hz that would make the wheel visibly lag the hands holding it.
@MainActor
final class DisplayLinkDriver {
    private var link: CADisplayLink?
    private let onFrame: (CADisplayLink) -> Void

    /// Measured `targetTimestamp − timestamp`, which is the display's actual
    /// frame interval. The on-device display cadence check reads this: about
    /// 8.3 ms on a ProMotion panel, about 16.7 ms on a 60 Hz one.
    private(set) var lastFrameIntervalMs: Double = 0

    init(onFrame: @escaping (CADisplayLink) -> Void) {
        self.onFrame = onFrame
    }

    func start() {
        guard link == nil else { return }

        let link = CADisplayLink(target: DisplayLinkProxy(owner: self),
                                 selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80,
                                                        maximum: 120,
                                                        preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        lastFrameIntervalMs = (link.targetTimestamp - link.timestamp) * 1000.0
        onFrame(link)
    }
}

/// `CADisplayLink` retains its target, so pointing it straight at the driver
/// would keep the driver alive forever and leak a running link with it.
@MainActor
private final class DisplayLinkProxy: NSObject {
    private weak var owner: DisplayLinkDriver?

    init(owner: DisplayLinkDriver) {
        self.owner = owner
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        owner?.tick(link)
    }
}
