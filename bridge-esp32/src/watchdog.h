#pragma once

// The link watchdog, ported from OpenSteer.Core/Watchdog.cs.
//
// Pure: no FreeRTOS, no ESP-IDF, no clock of its own. The caller injects `now` as
// a microsecond count, which is what lets the decay curve and both slews be
// checked against tools/golden_vectors.json without a chip attached.
//
// It lives in its own pair of files rather than inside hid_task.cpp, for the same
// reason OpenSteer.Core is a separate project from OpenSteer.Server: the moment
// it is entangled with the hardware, the only way to find out whether it coasts
// correctly is to unplug a phone and watch a car.
//
// The fail-safe emits brake 0, not 65535. A full brake injected while the link is
// down destabilises the tyre model and can spin a car mid-corner. Coasting with
// the wheel centred and the throttle shut is recoverable.

#include <stdint.h>

#include "wire_protocol.h"

namespace osteer {

enum class WdState : uint8_t {
    Idle = 0,
    Live,
    Decaying,
    FailSafe,
    Recovering,
};

/// What the joystick should report right now.
struct ControlState {
    int16_t steer = 0;
    uint16_t throttle = 0;
    uint16_t brake = 0;
    uint16_t clutch = 0;
    uint32_t buttons = 0;

    bool operator==(const ControlState& other) const {
        return steer == other.steer && throttle == other.throttle &&
               brake == other.brake && clutch == other.clutch &&
               buttons == other.buttons;
    }

    bool operator!=(const ControlState& other) const { return !(*this == other); }
};

struct WdEvent {
    WdState from = WdState::Idle;
    WdState to = WdState::Idle;
    int64_t silenceUs = 0;
    int64_t slewUs = 0;
};

class Watchdog {
public:
    /// Records the freshest accepted packet. Does not transition on its own.
    void onPacket(int64_t nowUs, const UplinkPacket& pkt);

    /// The link dropped for a reason we were told about, rather than one we had to
    /// infer from silence. Goes straight to the fail-safe: waiting out 250 ms of
    /// timeout when the access point has already said the station left would leave
    /// the last steering angle applied for a quarter of a second.
    void onLinkDown(int64_t nowUs);

    /// Runs on every pass, whether a packet arrived or the wait timed out. Returns
    /// true when `out` changed and a HID report is therefore due.
    bool evaluate(int64_t nowUs, ControlState& out);

    WdState state() const { return state_; }

    /// True once the fail-safe has fired and the alert has not been read.
    bool alertPending() const { return alertPending_; }
    void clearAlert() { alertPending_ = false; }

    bool takeEvent(WdEvent& out);

    /// How long the task may sleep before it must look again.
    ///
    /// Idle and fail-safe have nothing pending, so the task blocks outright rather
    /// than waking to discover that nothing has changed; a packet or a link-down
    /// message is what brings it back. Returns a negative value to mean "wait
    /// forever".
    int64_t nextDeadlineMs(int64_t nowUs) const;

private:
    void applyPacket(int64_t nowUs);
    void applyTimeouts(int64_t nowUs);
    void computeOutput(int64_t nowUs);
    void beginRecovery(int64_t nowUs, int16_t fromSteer, uint16_t fromThr,
                       uint16_t fromBrk, uint16_t fromClu);
    void transition(WdState to, int64_t silenceUs = 0, int64_t slewUs = 0);

    WdState state_ = WdState::Idle;
    ControlState out_{};
    ControlState last_{};
    ControlState pending_{};

    int64_t tLastUs_ = 0;
    int64_t tRecoverUs_ = 0;

    uint16_t decayThr0_ = 0;
    uint16_t decayBrk0_ = 0;

    int16_t slewFromSteer_ = 0;
    uint16_t slewFromThr_ = 0;
    uint16_t slewFromBrk_ = 0;
    uint16_t slewFromClu_ = 0;

    bool hasPending_ = false;
    bool alertPending_ = false;
    bool hasEvent_ = false;
    WdEvent event_{};
};

// Shared with the tests, and with anything else that has to round the same way
// the daemon does.

/// Half away from zero, grouped exactly as AxisMath.RoundHalfAway in the C# core.
int roundHalfAway(double v);

/// Linear interpolation, identical to AxisMath.Lerp including its early exits.
int lerpInt(int from, int to, double alpha);

double clamp01(double v);

}  // namespace osteer
