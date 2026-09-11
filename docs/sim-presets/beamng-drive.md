# BeamNG.drive

BeamNG is the most forgiving of the three to set up and the least forgiving to
drive. Its tyre and suspension model is soft-body, so it rewards smooth steering
and punishes the sawing motion a badly configured phone encourages.

## Quick version

1. Start the OpenSteer daemon. Start BeamNG.
2. **Options, Controls, Bindings**. The virtual pad appears as an Xbox 360
   controller.
3. Bind steering, throttle, brake and the two paddles.
4. Open the steering binding's detail panel and set **Filter: Direct**,
   **Deadzone 0**, **Linearity 1.0**.
5. Turn controller vibration off.

## Which device it binds as

**Mode A, the default:** the daemon presents an Xbox 360 pad through ViGEmBus.
BeamNG reads it through XInput and calls it a gamepad.

**The ESP32 bridge:** a plain HID joystick with four separate 16-bit axes. BeamNG
reads that through DirectInput and treats it as a wheel-like device. This matters:
BeamNG applies a different default input filter to each class, and the wheel
filter is the one you want in both cases. See the filter section below.

If both are plugged in at once, BeamNG will see two devices and may bind the wrong
one. Unplug the bridge while using Mode A.

## Bindings

**Options, Controls, Bindings, Vehicle.**

| Action | Mode A control | Bridge control |
|---|---|---|
| Steering | Left stick X | X axis |
| Throttle | Right trigger | Y axis |
| Brake | Left trigger | Z axis |
| Shift up | Right bumper | Button 1 |
| Shift down | Left bumper | Button 2 |
| Handbrake | B | Button 3 |

Leave the clutch unbound. The phone sends zero on that axis always, so a bound
clutch would sit permanently at rest and, on a manual car, do nothing useful.

## The steering filter, which is the setting that matters

Click the steering binding to open its detail panel. BeamNG offers a filter per
binding, and the choice changes the feel more than anything else on this page.

| Filter | What it does | Use it? |
|---|---|---|
| **Direct** | Passes your input through unchanged | **Yes** |
| Gamepad | Adds countersteer assistance, speed-sensitive limiting and smoothing | No |
| Wheel | Treats the axis as a wheel with a rotation range, minimal processing | Acceptable |
| Key | Ramps from a digital press | No |

**Pick Direct.** The Gamepad filter exists because a thumbstick has about two
centimetres of travel and needs help to be drivable. Your phone has 900 degrees of
rotation and needs none. Worse, the Gamepad filter includes automatic countersteer
that fights you during a slide, which is the one moment you most need the car to
do exactly what your hands said.

If Direct feels too sharp, **do not switch to Gamepad**. Raise lock to lock in the
OpenSteer app instead. That changes the ratio without inserting a filter between
your hands and the car.

The Wheel filter is a reasonable second choice, especially with the ESP32 bridge
where BeamNG will likely default to it anyway. It does far less than the Gamepad
filter.

## The other values in the same panel

| Setting | Value | Why |
|---|---|---|
| Deadzone | **0** | The phone already trims a deadband. A second one subtracts from a range that was already trimmed, and full lock stops being reachable. |
| Linearity | **1.0** | Linear. This is a response curve and the phone has applied one. |
| Sensitivity | **1.0** | Leave it. Change lock to lock in the app instead, so there is one place that decides the ratio. |
| Invert | off | Unless you want to steer backwards, which some people genuinely do. |

**Options, Controls, Force Feedback:** turn vibration off. The virtual pad has no
motors, and on the bridge there is no return path at all. Haptics come from the
phone.

## Lock to lock

Set it in the OpenSteer app.

| Vehicle | Try |
|---|---|
| Open wheel and formula | 360 |
| Track and sports | 540 |
| Road cars and trucks | 900 |
| Anything on dirt | 900 |

BeamNG's soft-body model makes large, slow steering inputs feel much better than
fast ones, so err on the side of more rotation than you think you need.

## Force feedback

**There is none, in either mode.** BeamNG does not publish the shared memory page
that OpenSteer's telemetry reader attaches to; that reader is written against
Assetto Corsa's `acpmf_physics`. The phone will show its link as degraded after
half a second, which is correct and costs you nothing but the haptics. Steering,
pedals and buttons all keep working normally.

## When it feels wrong

**The car countersteers by itself.** The Gamepad filter is on. Switch the steering
binding to Direct.

**Steering is twitchy at speed.** Raise lock to lock in the app. Do not reach for
the Gamepad filter, which fixes the symptom by taking the car away from you.

**The car will not turn far enough.** Two deadzones are stacked. Set BeamNG's to 0.

**The wheel drifts while you hold still.** Press CENTRE in the app.

**The steering input bar jumps around in the bindings screen.** Something else is
bound to the same axis, usually a real controller BeamNG found first. Clear the
other binding.
