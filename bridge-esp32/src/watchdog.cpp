#include "watchdog.h"

#include <math.h>

#include "config.h"

namespace osteer {

double clamp01(double v) {
    return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
}

int roundHalfAway(double v) {
    return static_cast<int>(v >= 0.0 ? floor(v + 0.5) : ceil(v - 0.5));
}

int lerpInt(int from, int to, double alpha) {
    if (alpha <= 0.0) {
        return from;
    }
    if (alpha >= 1.0) {
        return to;
    }
    return roundHalfAway(from + (to - from) * alpha);
}

namespace {

inline double msSince(int64_t fromUs, int64_t nowUs) {
    return static_cast<double>(nowUs - fromUs) / 1000.0;
}

uint16_t decayTo(uint16_t v0, double factor) {
    int v = roundHalfAway(static_cast<double>(v0) * factor);
    return v < cfg::kDecayFloor ? static_cast<uint16_t>(0) : static_cast<uint16_t>(v);
}

int absDiff(int a, int b) {
    return a > b ? a - b : b - a;
}

}  // namespace

void Watchdog::onPacket(int64_t nowUs, const UplinkPacket& pkt) {
    pending_.steer = saturateSteer(pkt.steer);
    pending_.throttle = pkt.throttle;
    pending_.brake = pkt.brake;
    pending_.clutch = pkt.clutch;
    pending_.buttons = pkt.buttons;
    hasPending_ = true;
    tLastUs_ = nowUs;
}

void Watchdog::onLinkDown(int64_t nowUs) {
    if (state_ == WdState::Idle || state_ == WdState::FailSafe) {
        return;
    }

    // Deliberately skips the decay. The decay exists to ride out silence that
    // might still be a live link having a bad moment; a station that has
    // disconnected is not coming back inside 250 ms, and holding the last
    // steering angle meanwhile is exactly what the fail-safe is for.
    hasPending_ = false;
    alertPending_ = true;
    transition(WdState::FailSafe, static_cast<int64_t>(msSince(tLastUs_, nowUs) * 1000.0));
}

bool Watchdog::takeEvent(WdEvent& out) {
    out = event_;
    bool had = hasEvent_;
    hasEvent_ = false;
    return had;
}

void Watchdog::transition(WdState to, int64_t silenceUs, int64_t slewUs) {
    event_.from = state_;
    event_.to = to;
    event_.silenceUs = silenceUs;
    event_.slewUs = slewUs;
    hasEvent_ = true;
    state_ = to;
}

bool Watchdog::evaluate(int64_t nowUs, ControlState& out) {
    if (hasPending_) {
        applyPacket(nowUs);
        hasPending_ = false;
    }

    applyTimeouts(nowUs);
    computeOutput(nowUs);

    if (out_ == out) {
        return false;
    }

    out = out_;
    return true;
}

void Watchdog::applyPacket(int64_t nowUs) {
    last_ = pending_;

    switch (state_) {
        case WdState::Idle:
            transition(WdState::Live);
            break;

        case WdState::Live:
            break;

        case WdState::Decaying:
            // A short hiccup should not cost a 300 ms slew. If the returning
            // angle is close to the one being held, snap straight back.
            if (absDiff(pending_.steer, out_.steer) <= cfg::kSnapThreshold) {
                transition(WdState::Live);
            } else {
                beginRecovery(nowUs, out_.steer, out_.throttle, out_.brake, out_.clutch);
            }
            break;

        case WdState::FailSafe:
            // Everything is already at zero, so both slews start from zero.
            beginRecovery(nowUs, 0, 0, 0, 0);
            break;

        case WdState::Recovering:
            break;
    }
}

void Watchdog::beginRecovery(int64_t nowUs, int16_t fromSteer, uint16_t fromThr,
                             uint16_t fromBrk, uint16_t fromClu) {
    tRecoverUs_ = nowUs;
    slewFromSteer_ = fromSteer;
    slewFromThr_ = fromThr;
    slewFromBrk_ = fromBrk;
    slewFromClu_ = fromClu;
    transition(WdState::Recovering);
}

void Watchdog::applyTimeouts(int64_t nowUs) {
    if (state_ == WdState::Idle || state_ == WdState::FailSafe) {
        return;
    }

    double s = msSince(tLastUs_, nowUs);

    if (s >= cfg::kHardMs) {
        alertPending_ = true;
        transition(WdState::FailSafe, static_cast<int64_t>(s * 1000.0));
        return;
    }

    if (s > cfg::kSoftMs && state_ != WdState::Decaying) {
        decayThr0_ = out_.throttle;
        decayBrk0_ = out_.brake;
        transition(WdState::Decaying, static_cast<int64_t>(s * 1000.0));
    }
}

void Watchdog::computeOutput(int64_t nowUs) {
    switch (state_) {
        case WdState::Idle:
            break;

        case WdState::Live:
            out_ = last_;
            break;

        case WdState::Decaying: {
            double s = msSince(tLastUs_, nowUs);

            // Exponential in elapsed time rather than per tick, so jitter in when
            // the task happens to wake cannot bend the curve.
            double f = exp(-(s - cfg::kSoftMs) / cfg::kTauMs);
            out_.throttle = decayTo(decayThr0_, f);
            out_.brake = decayTo(decayBrk0_, f);

            // Steering is held, not decayed. Centring the wheel mid-corner is
            // worse than keeping the last known angle for 150 ms.
            out_.buttons = 0u;  // never let a shift paddle stick
            break;
        }

        case WdState::FailSafe:
            out_ = ControlState{};
            break;

        case WdState::Recovering: {
            double elapsed = msSince(tRecoverUs_, nowUs);
            double a = clamp01(elapsed / cfg::kSteerSlewMs);
            double b = clamp01(elapsed / cfg::kPedalSlewMs);

            out_.steer = static_cast<int16_t>(lerpInt(slewFromSteer_, last_.steer, a));
            out_.throttle = static_cast<uint16_t>(lerpInt(slewFromThr_, last_.throttle, b));
            out_.brake = static_cast<uint16_t>(lerpInt(slewFromBrk_, last_.brake, b));
            out_.clutch = static_cast<uint16_t>(lerpInt(slewFromClu_, last_.clutch, b));

            // Buttons are never slewed. Half a gear change is not a thing.
            out_.buttons = last_.buttons;

            if (a >= 1.0) {
                transition(WdState::Live, 0, static_cast<int64_t>(elapsed * 1000.0));
            }
            break;
        }
    }
}

int64_t Watchdog::nextDeadlineMs(int64_t nowUs) const {
    switch (state_) {
        case WdState::Idle:
        case WdState::FailSafe:
            // Nothing is pending. Only a packet or a link-down message can change
            // anything from here, and both arrive through the mailbox.
            return -1;

        case WdState::Decaying:
            return cfg::kDegradedTickMs;

        case WdState::Live:
        case WdState::Recovering:
        default: {
            // Wake exactly when the link would have gone quiet for too long. At
            // 120 Hz a packet almost always arrives first and this deadline is
            // never reached, so the task sleeps through the gaps.
            double remaining = cfg::kSoftMs - msSince(tLastUs_, nowUs);
            if (remaining < 1.0) {
                return 1;
            }
            return static_cast<int64_t>(remaining);
        }
    }
}

}  // namespace osteer
