# Assetto Corsa

Assetto Corsa is the reference game for this project. It is the one whose
telemetry the daemon reads, and the force feedback you get on the phone comes out
of its shared memory.

## Quick version

1. Start the OpenSteer daemon. Start Assetto Corsa.
2. In Content Manager: **Settings, Controls, Input method: Gamepad**.
3. Assign steering, throttle, brake and the two paddles.
4. Set gamepad **Steering gamma 1.0**, **filter 0**, **deadzone 0**, **speed sensitivity 0**.
5. Turn the in-game vibration off. The phone does the haptics.
6. Drive.

## The preset file

[`assetto-corsa/OpenSteer_Xbox360.ini`](assetto-corsa/OpenSteer_Xbox360.ini)

Copy it to:

```
%USERPROFILE%\Documents\Assetto Corsa\cfg\controllers\savedsets\OpenSteer_Xbox360.ini
```

Then load it under **Settings, Controls**, from the preset dropdown at the top.

### If you do not have Content Manager

The stock launcher, `AssettoCorsa.exe` in the game folder, has the same Controls
page and reads the same `savedsets` folder. The preset appears in its dropdown
too.

The folder does not exist until the game has been run once. Launch Assetto Corsa,
let it reach the main menu, quit, and the whole `cfg` tree will be there.

If the dropdown does not show the preset for any reason, set the four gamepad
values by hand instead. They are listed in the table below, and the menu is the
authority anyway.

**Check the four gamepad values on screen after loading it.** Content Manager
rewrites this file when it saves, and both it and the game have renamed keys
across versions. The file is a convenience; the menu is the truth. Every setting
in it is listed below with its menu location so you can confirm each one by eye.

## Why every number is what it is

| Setting | Value | Why |
|---|---|---|
| Input method | Gamepad | Mode A is an Xbox 360 pad. The wheel path expects a device with a physical rotation range and force feedback motors, and picking it gives a steering axis that behaves nothing like the one you are sending. |
| Steering gamma | **1.0** | Linear. Gamma is a response curve, and the phone has already applied one. Two curves multiplied together give a dead centre and twitchy ends. |
| Steering filter | **0** | A filter is a low-pass on your input. It smooths by delaying, which is latency added to a chain built to stay under three milliseconds. |
| Steering deadzone | **0** | The phone already trims a deadband before the packet is built. Subtracting a second one means full lock is no longer reachable. |
| Steering speed | **0** | This is speed-sensitive steering, which quietly changes your lock ratio with velocity. You cannot build muscle memory against a ratio that moves. |
| Speed sensitivity | **0** | Same reason. |
| Rumble | **0** | The pad is virtual and has no motors. The haptics you feel come from the phone, driven by the daemon reading shared memory. |

## Force feedback to the phone

**There is nothing to enable.** Assetto Corsa publishes its physics page
unconditionally, under the name `Local\acpmf_physics`, and the daemon attaches to
it on its own. The whole path has been verified against a mock of that page.

Two things are worth knowing when it looks like it is not working.

**The page only updates during a session.** Sitting in a menu, the numbers are
stale or zero. The daemon reports this honestly: its status line shows the shared
memory as stale and it sends zeroes as a heartbeat rather than pretending.

**In-game force feedback strength does not affect it.** That slider drives a
physical wheel's motors. The phone's haptics are computed from engine speed, ABS,
traction control and tyre slip, read straight out of the physics page. Turning the
in-game slider to zero changes nothing on the phone.

## Driving it without a phone

`tools/drive_keys.py` sends the same packets the phone sends, at the same rate, so
the daemon cannot tell the difference. It is the fastest way to find out whether
the PC half works before any of the phone half exists.

```bash
python tools/drive_keys.py
```

A and D steer, W and S are the pedals, Space is the handbrake, E and Q shift, Esc
stops. It reads the keyboard globally, so it keeps working after you switch to the
game.

The buttons stay dead for the first five seconds on purpose. A virtual pad's
buttons are wired to Windows menu navigation when no game has the focus, so a
handbrake press on the desktop clicks whatever is under it. The countdown is there
so you can switch to the game first.

## Assignments

Content Manager, **Settings, Controls, Gamepad**.

| Action | Control |
|---|---|
| Steer | Left stick X |
| Throttle | Right trigger |
| Brake | Left trigger |
| Shift up | Right bumper |
| Shift down | Left bumper |
| Handbrake | B |

Leave the clutch unassigned. The phone has no clutch control, so it sends zero on
that axis always, and binding it would give you a clutch pedal stuck at rest.

## Choosing a lock to lock

Set this in the OpenSteer app, not in the game. Start at 900 degrees and work down
if the car feels slow to respond.

| Cars | Try |
|---|---|
| Formula and open wheel | 360 |
| GT and touring | 540 |
| Road cars | 900 |
| Drift | 900 |

A larger number means more phone rotation for the same steering, which is easier
to hold steady at speed and harder to place quickly. Smaller is the reverse.

## When it feels wrong

**The car darts at the smallest movement.** Lock to lock is too small, or you left
a gamma above 1.0 in the game. Check the gamepad gamma is 1.0, then raise lock to
lock in the app.

**Steering feels vague around centre.** Two deadzones are stacked. Set the game's
deadzone to 0 and use the app's deadband alone.

**Steering lags your hands.** A filter is on somewhere. Set the game's steering
filter and steering speed to 0.

**The wheel drifts while you hold still.** Press CENTRE in the app. The gyroscope
has no absolute reference about the screen normal, so it recentres wherever the
phone is pointing. A phone held flat drifts fastest; held up like a wheel, gravity
constrains it and drift is negligible.

**No haptics.** Check you are in a session and moving, not in a menu. Then check
the daemon's status line says the shared memory is attached.
