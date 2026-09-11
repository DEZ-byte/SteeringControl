# Sim presets

Per-game setup for OpenSteer. One page each for Assetto Corsa, BeamNG.drive and
Forza Horizon 4/5.

## The one rule that matters

**Turn every assist, filter, deadzone and smoothing option in the game off.**

Not down. Off.

OpenSteer already shapes the steering, once, on the phone. Degrees of rotation,
deadband and response curve are applied in `SteerMapper` before the packet is
built, which is why the Windows daemon has no shaper at all and its `--dor` flag
only prints. Every filter you leave enabled in the game is a second shaper
stacked on top of the first.

That stacking is not merely redundant. A game-side steering filter works by
lagging its input, so it adds milliseconds to a chain the entire project exists to
keep under three. A game-side deadzone subtracts from a range the phone has
already trimmed, so full lock stops being reachable. And two response curves
multiplied together give a centre so soft the car feels broken and ends so sharp
it feels twitchy, which is the exact complaint people have about phone steering in
the first place.

Set the shaping in the OpenSteer app instead. It is under the settings button:
lock to lock, deadband, response.

## What the PC sees

In Mode A, which is the default and the only verified path, OpenSteer presents an
Xbox 360 controller through ViGEmBus. Games see a normal XInput pad, so use each
game's **controller** setup, never its wheel setup.

| Phone input | Arrives as |
|---|---|
| Steering | Left stick X, full 16-bit range |
| Throttle | Right trigger |
| Brake | Left trigger |
| Upshift paddle | Right bumper |
| Downshift paddle | Left bumper |
| Handbrake | B |

The ESP32 bridge is different: it presents a plain HID joystick with four separate
16-bit axes, so the games see a wheel-like device instead. Where that changes the
setup, each page says so.

## Pages

| Game | Page |
|---|---|
| Assetto Corsa | [assetto-corsa.md](assetto-corsa.md) |
| BeamNG.drive | [beamng-drive.md](beamng-drive.md) |
| Forza Horizon 4 and 5 | [forza-horizon.md](forza-horizon.md) |

## Status

These are starting points written from the games' documented settings, not
measured results. None has been driven with a real phone yet, because the iOS app
needs a Mac to build and the force-feedback road test needs Assetto Corsa installed.
Treat the numbers as a sane first setup and expect to adjust lock to lock to taste.

Where a page gives an exact configuration file key, it also gives the menu path
for the same setting. Use the menu if the two ever disagree: game updates rename
keys, and a menu you can see is worth more than a file you cannot verify.
