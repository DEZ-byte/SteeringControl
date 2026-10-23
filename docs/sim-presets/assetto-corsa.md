# Assetto Corsa iPhone Steering Wheel Setup & Preset (OpenSteer)

Assetto Corsa is the reference game for this project. It is the one whose
telemetry the daemon reads, and the force feedback sent to the phone comes from
its shared memory.

## Quick setup

1. Start the OpenSteer daemon. Start Assetto Corsa.
2. In Content Manager: **Settings, Controls, Input method: Gamepad**.
3. Assign steering, throttle, brake and the two paddles.
4. Set gamepad **Steering gamma 1.0**, **filter 0**, **deadzone 0**, **speed sensitivity 0**.
5. Turn the in-game vibration off. The phone does the haptics.
6. Drive.

## The OpenSteer controller preset for Assetto Corsa

[`assetto-corsa/OpenSteer_Xbox360.ini`](assetto-corsa/OpenSteer_Xbox360.ini)

Copy it to:

```
%USERPROFILE%\Documents\Assetto Corsa\cfg\controllers\presets\OpenSteer_Xbox360.ini
```

Use `presets`, not `savedsets`. Both folders exist, but only `presets` feeds the
preset list on the Controls page. A file in `savedsets` is ignored without any
message, which looks the same as a malformed file.

The folder does not exist until the game has been run once. Launch Assetto Corsa,
let it reach the main menu, quit, and the whole `cfg` tree appears.

Then load **OpenSteer_Xbox360** from the dropdown on the Controls page. This works
in the stock launcher and in Content Manager; they read the same folder.

The file is built from the game's own `X360Default.ini`, so every section the game
expects is present and in the shape it expects. Twenty-two values differ from
stock, and each one carries its reason inline.

**Check the four gamepad values on screen after loading it.** Content Manager
rewrites the file when it saves, and the game has renamed keys across versions.
If the file and the menu disagree, go by the menu.

## Why each value is set this way

| Setting | Value | Why |
|---|---|---|
| Input method | Gamepad | Mode A is an Xbox 360 pad. The wheel path expects a device with a physical rotation range and force feedback motors, and picking it gives a steering axis that behaves nothing like the one you are sending. |
| Steering gamma | **1.0** | Linear. Gamma is a response curve, and the phone has already applied one. Two curves multiplied together give a dead center and twitchy ends. |
| Steering filter | **0** | A filter is a low-pass on your input. It smooths by delaying, which adds latency to a chain designed to stay under three milliseconds. |
| Steering deadzone | **0** | The phone already trims a deadband before the packet is built. Subtracting a second one means full lock is no longer reachable. |
| Steering speed | **0** | This is speed-sensitive steering, which changes your lock ratio with velocity. A ratio that changes with speed is harder to learn. |
| Speed sensitivity | **0** | Same reason. |
| Rumble | **0** | The pad is virtual and has no motors. The haptics come from the phone, driven by the daemon reading shared memory. |

## iPhone haptics from Assetto Corsa telemetry

There is nothing to enable. Assetto Corsa publishes its physics page
unconditionally, under the name `Local\acpmf_physics`, and the daemon attaches to
it on its own. This path has been verified against a mock of that page,
`tools/inject_ac_shm.py`, and in a real drive: the daemon sent the iPhone its 60 Hz
downlink for the whole session, with live physics in it for the roughly 5 minutes on
track ([measurements](../../README.md#measured-on-track)).

If it seems not to work, check two things.

**The page only updates during a session.** In a menu, the numbers are stale or
zero. The daemon's status line shows the shared memory as stale, and it sends
zeroes as a heartbeat.

**In-game force feedback strength does not affect it.** That slider drives a
physical wheel's motors. The phone's haptics are computed from engine speed, ABS,
traction control and tire slip, read straight out of the physics page. Turning the
in-game slider to zero changes nothing on the phone.

## Testing Assetto Corsa without a phone

`tools/drive_keys.py` sends the same packets the phone sends, at 120 Hz where a real
iPhone sends 100, so the daemon handles them identically. Use it to check the PC side without a phone.

```bash
python tools/drive_keys.py
```

A and D steer, W and S are the pedals, Space is the handbrake, E and Q shift, Esc
stops. It reads the keyboard globally, so it keeps working after you switch to the
game.

The buttons stay disabled for the first five seconds. When no game has the focus,
a virtual pad's buttons drive Windows menu navigation, so a handbrake press on the
desktop clicks whatever is under it. The delay gives you time to switch to the
game.

## Steering, pedal and paddle assignments

With input method **Gamepad**, Assetto Corsa does not let you pick axes. The Xbox
layout is fixed, and it already matches what the daemon sends.

| Action | Control | Set by the preset |
|---|---|---|
| Steer | Left stick X | fixed |
| Throttle | Right trigger | fixed |
| Brake | Left trigger | fixed |
| Shift up | Right bumper | yes, stock was A |
| Shift down | Left bumper | yes, stock was X |
| Handbrake | B | already stock |

Two stock actions sat on the bumpers the paddles now use, so the preset frees
them.

The clutch stays unassigned. The phone always sends zero on that axis, so binding
it would give a clutch pedal permanently at rest.

## The keyboard shortcuts the preset clears

Assetto Corsa's keyboard shortcuts fire whatever the input method is set to, and
the stock Xbox preset puts several of them on the keys `tools/drive_keys.py`
drives with.

| Key | Stock action | What you would see |
|---|---|---|
| A | Toggle ABS | steering left switches ABS on and off |
| D | Rewind | steering right rewinds |
| W | Glance right | the throttle turns your head |
| S | Slow motion | braking drops the game to slow motion |
| Q | Glance left, hide damage | downshifting looks sideways |
| E | Celebrate | upshifting waves |
| R | Replay | re-centering starts a replay |
| Space | Pause replay | the handbrake pauses |

The preset sets all of those to unbound. If you build your own preset instead, do
the same, or keyboard testing will trigger these actions.

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

## Troubleshooting: when it feels wrong

**The car barely turns, even at full wrist rotation.** The phone rotation setting
is too large. It is not the car's steering lock; it is how far you turn the phone.
Set it to 180 in the app.

**The car darts at the smallest movement.** Phone rotation is too small, or you
left a gamma above 1.0 in the game. Check the gamepad gamma is 1.0, then raise the
rotation setting.

**Steering feels vague around center.** Two deadzones are stacked. Set the game's
deadzone to 0 and use the app's deadband alone.

**Steering lags your hands.** A filter is on somewhere. Set the game's steering
filter and steering speed to 0.

**The wheel drifts while you hold still.** Press CENTER in the app. The gyroscope
has no absolute reference about the screen normal, so it recenters wherever the
phone is pointing. A phone held flat drifts fastest; held up like a wheel, gravity
constrains it and drift is negligible.

**No haptics.** Check you are in a session and moving, not in a menu. Then check
the daemon's status line says the shared memory is attached.
