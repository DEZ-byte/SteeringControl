# BeamNG.drive iPhone Steering Wheel Setup Guide (OpenSteer)

BeamNG is the easiest of the three to set up but the most demanding to drive. Its
soft-body tire and suspension model rewards smooth steering and punishes the
sawing motion a badly configured phone encourages.

## Quick setup

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
reads that through DirectInput and treats it as a wheel-like device. BeamNG
applies a different default input filter to each class, so check the filter in
either case; see the filter section below.

If both are plugged in at once, BeamNG will see two devices and may bind the wrong
one. Unplug the bridge while using Mode A.

## BeamNG.drive bindings for the iPhone wheel

**Options, Controls, Bindings, Vehicle.**

| Action | Mode A control | Bridge control |
|---|---|---|
| Steering | Left stick X | X axis |
| Throttle | Right trigger | Y axis |
| Brake | Left trigger | Z axis |
| Shift up | Right bumper | Button 1 |
| Shift down | Left bumper | Button 2 |
| Handbrake | B | Button 3 |

Leave the clutch unbound. The phone always sends zero on that axis, so a bound
clutch would sit permanently at rest and, on a manual car, do nothing useful.

## The steering filter

Click the steering binding to open its detail panel. BeamNG offers a filter per
binding, and the choice changes the feel more than anything else on this page.

| Filter | What it does | Use it? |
|---|---|---|
| **Direct** | Passes your input through unchanged | **Yes** |
| Gamepad | Adds countersteer assistance, speed-sensitive limiting and smoothing | No |
| Wheel | Treats the axis as a wheel with a rotation range, minimal processing | Acceptable |
| Key | Ramps from a digital press | No |

Pick Direct. The Gamepad filter exists because a thumbstick has about two
centimeters of travel and needs help to be drivable. The phone gives you ninety
degrees of wrist rotation each way and needs none. The Gamepad filter also
includes automatic countersteer that works against you during a slide, when you
most need the car to follow your hands.

If Direct feels too sharp, do not switch to Gamepad. Increase the phone rotation
setting in the OpenSteer app instead. That changes the ratio without inserting a
filter between your hands and the car.

The Wheel filter is a reasonable second choice, especially with the ESP32 bridge
where BeamNG will likely default to it anyway. It does far less than the Gamepad
filter.

## The other values in the same panel

| Setting | Value | Why |
|---|---|---|
| Deadzone | **0** | The phone already trims a deadband. A second one subtracts from a range that was already trimmed, and full lock stops being reachable. |
| Linearity | **1.0** | Linear. This is a response curve and the phone has applied one. |
| Sensitivity | **1.0** | Leave it. Change the phone rotation setting in the app instead, so there is one place that decides the ratio. |
| Invert | off | Turn on only if you want reversed steering. |

**Options, Controls, Force Feedback:** turn vibration off. The virtual pad has no
motors, and on the bridge there is no return path at all. Haptics come from the
phone.

## Steering rotation: how far to turn the phone

Set this in the OpenSteer app, not in the game.

**This is not the car's steering lock.** It is how far you rotate the phone to
command full lock, and the two numbers are independent. A real 900 degree wheel
turns two and a half times. Your hands manage about 90 degrees each way before
your arms cross over.

Older advice said to start at 900, which makes the car barely turn: a 90 degree
wrist turn asks for a fifth of the car's lock and there is no way to ask for more.

| Phone rotation | You turn | Feels |
|---|---|---|
| 120° | 60° each way | quick, twitchy at speed |
| 150° | 75° each way | quick |
| **180°** | **90° each way** | **the default, start here** |
| 240° | 120° each way | calm, needs a stretch for full lock |
| 360° | 180° each way | needs a regrip; for drifting |

Start at 180. If the car darts, go up. If you cannot reach full lock in a hairpin,
go down.

BeamNG's soft-body model rewards smooth inputs, so if you are between
two settings take the larger one.

## Force feedback and haptics

BeamNG sends no telemetry to the phone in either mode. It does not publish the
shared memory page that OpenSteer's telemetry reader attaches to; that reader is
written against Assetto Corsa's `acpmf_physics`. In Mode A the daemon still sends
its 60 Hz downlink, filled with zeros, so the phone never marks its link as degraded
and its status line keeps reading "Streaming to" and the PC's address. The ESP32
bridge sends no downlink at all. The phone then keeps its link up and does not mute
haptics, and its status line keeps reading "Streaming to" and the bridge's address.
Either way there is no engine rumble and no ABS or traction control tick, but the
shift click and the brake lockup thud, which come from your own inputs, still play.
Steering, pedals and buttons work normally.

## Troubleshooting: when it feels wrong

**The car countersteers by itself.** The Gamepad filter is on. Switch the steering
binding to Direct.

**The car barely turns.** The phone rotation setting is too large. It is not the
car's steering lock; it is how far you turn the phone. Set it to 180.

**Steering is twitchy at speed.** Increase the phone rotation setting. Do not use
the Gamepad filter for this; it reduces twitchiness by limiting and overriding your
input.

**The car will not turn far enough.** Two deadzones are stacked. Set BeamNG's to 0.

**The wheel drifts while you hold still.** Press CENTER in the app.

**The steering input bar jumps around in the bindings screen.** Something else is
bound to the same axis, usually a real controller BeamNG found first. Clear the
other binding.
