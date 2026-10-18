# Sim presets

Per-game setup for OpenSteer. One page each for Assetto Corsa, BeamNG.drive and
Forza Horizon 4/5.

## Turn off the game's input shaping

Turn every assist, filter, deadzone and smoothing option in the game off, not just
down.

OpenSteer shapes the steering once, on the phone. Degrees of rotation, deadband and
response curve are applied in `SteerMapper` before the packet is built (see
[ARCHITECTURE.md](../ARCHITECTURE.md)), so the Windows daemon has no shaper.
Every filter left enabled in the game is a second shaper on top of the first.

That causes three problems. A game-side steering filter works by lagging its
input, so it adds latency to a chain designed to stay under 3 ms. A game-side
deadzone subtracts from a range the phone has already trimmed, so full lock stops
being reachable. And two response curves multiplied together give a very soft
center and very sharp ends, so the car feels unresponsive near straight-ahead and
twitchy near full lock.

Set the shaping in the OpenSteer app instead. It is under the settings button:
phone rotation, deadband, response.

**The rotation setting is how far you turn the phone, not the car's steering
lock.** The default of 180 means full lock at ninety degrees each way. A
wheel-sized number like 900 means a ninety degree turn can only ever ask for a
fifth of the car's lock, and the car will barely respond.

## What the PC sees

In Mode A, which is the default and the only verified path, OpenSteer presents an
Xbox 360 controller through ViGEmBus. Games see a normal XInput pad, so use each
game's controller setup, not its wheel setup.

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
measured results. The presets have been tested with the keyboard and loopback
tools, not with a phone: the iOS app builds and passes its tests in CI but has not
yet run on a physical iPhone. Treat the numbers as a reasonable first setup and
expect to adjust the phone rotation setting to taste.

Where a page gives an exact configuration file key, it also gives the menu path
for the same setting. Use the menu if the two disagree: game updates rename keys,
and the menu shows the value the game is actually using.
