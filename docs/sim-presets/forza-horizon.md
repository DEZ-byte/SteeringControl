# Forza Horizon 4 and 5

Both games behave the same way here, and the menus are in the same places.

Forza is the easiest of the three to get driving and the fussiest to get right,
because its controller handling assumes a thumbstick and its defaults are built
around one.

## Quick version

1. Start the OpenSteer daemon. Start Forza.
2. **Settings, Controls, Advanced Controls**.
3. Set every **deadzone inside to 0** and every **deadzone outside to 100**.
4. **Steering Linearity 50** in FH5, which is its linear setting.
5. **Vibration Scale 0**.
6. Drive.

## Use Mode A

Forza Horizon binds XInput controllers and is unreliable with generic HID
joysticks, so the ESP32 bridge is not a supported path here. Use the Windows
daemon in Mode A, which presents an Xbox 360 pad and is exactly what Forza
expects.

There is nothing to bind. Forza does not offer per-control rebinding for
controllers beyond a handful of fixed layouts, and the default layout already
matches what OpenSteer sends.

| Phone | Forza |
|---|---|
| Steering | Left stick X |
| Throttle | Right trigger |
| Brake | Left trigger |
| Upshift | Right bumper |
| Downshift | Left bumper |
| Handbrake | B |

## Advanced Controls

**Settings, Controls, Advanced Controls.** This page is the whole setup.

Forza gives every axis two deadzones. **Inside** is how far the axis must move
from rest before the game notices. **Outside** is how far from the end it stops
reading more. The pair exists because real thumbsticks wear out: an old stick
rests slightly off centre and no longer reaches its own corners.

Your axis is a number in a packet. It rests at exactly zero and it reaches exactly
full. Both corrections are not merely unnecessary, they are actively harmful:
inside costs you fine control around the straight-ahead, and outside costs you
full lock.

| Setting | Value |
|---|---|
| Steering Axis Deadzone Inside | **0** |
| Steering Axis Deadzone Outside | **100** |
| Acceleration Axis Deadzone Inside | **0** |
| Acceleration Axis Deadzone Outside | **100** |
| Deceleration Axis Deadzone Inside | **0** |
| Deceleration Axis Deadzone Outside | **100** |
| Clutch Axis Deadzone Inside | **0** |
| Clutch Axis Deadzone Outside | **100** |
| Handbrake Axis Deadzone Inside | **0** |
| Handbrake Axis Deadzone Outside | **100** |
| Steering Linearity (FH5) | **50** |
| Vibration Scale | **0** |
| Force Feedback Scale | **0** |

**Steering Linearity is centred at 50, not 0.** This is the one value on the page
where zero is wrong. Forza's scale runs from 0 to 100 with 50 as linear; below 50
softens the centre, above 50 sharpens it. Setting it to 0 gives the softest
possible curve, which stacks on top of the curve the phone already applied and
produces steering that feels broken near straight-ahead. FH4 does not expose this
setting at all, so there is nothing to do there.

**Vibration and force feedback scale to 0.** The virtual pad has no motors, so the
setting does nothing either way, but leaving it on means Forza spends effort
computing effects for a device that cannot play them.

## Choosing how far to turn the phone

Set this in the OpenSteer app, not in the game.

**This is not the car's steering lock.** It is how far you rotate the phone to
command full lock, and the two numbers have nothing to do with each other. A real
900 degree wheel turns two and a half times. Your hands manage about 90 degrees
each way before your arms cross over.

That is why the old advice to start at 900 was wrong, and why the car would barely
turn. At 900, a 90 degree wrist turn asks for a fifth of the car's lock and there
is no way to ask for more.

| Phone rotation | You turn | Feels |
|---|---|---|
| 120° | 60° each way | quick, twitchy at speed |
| 150° | 75° each way | quick |
| **180°** | **90° each way** | **the default, start here** |
| 240° | 120° each way | calm, needs a stretch for full lock |
| 360° | 180° each way | needs a regrip; for drifting |

Start at 180. If the car darts, go up. If you cannot reach full lock in a hairpin,
go down.

Forza has a lot of built-in steering assistance and expects small, quick
inputs, so 150 often suits it better than 180.

## Assists

Forza's driving assists are a separate question from the input chain and are a
matter of taste, with one exception.

**Turn Steering Assist off.** Under Settings, Difficulty, it is listed as
"Steering". Set it to Simulation. The assist steers for you based on the racing
line, which means the car does things your hands did not ask for, and no amount of
input tuning will make that feel right.

Traction control, stability control and the braking line are all fine to leave on.
They act on the car, not on your input.

## Force feedback

**There is none.** Forza does not publish the shared memory page the OpenSteer
telemetry reader attaches to; that reader is written against Assetto Corsa. The
phone shows its link as degraded after half a second, which is accurate. Steering,
pedals and buttons are unaffected.

## When it feels wrong

**The car will not steer fully.** A deadzone outside is below 100. Set all of them
to 100.

**The straight-ahead feels dead.** A deadzone inside is above 0, or FH5's Steering
Linearity is below 50.

**The car steers on its own through corners.** Steering Assist is on. Settings,
Difficulty, Steering, Simulation.

**Throttle or brake do not reach full.** The acceleration or deceleration deadzone
outside is below 100.

**Nothing responds at all.** Forza only reads one controller at a time and binds
the first it finds. Unplug other controllers, then restart the game. Forza checks
at start-up and does not always notice a device that appears later.
