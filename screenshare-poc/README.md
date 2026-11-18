# Screen sharing PoC (#71843)

Support views and controls the driver's screen. No backend: the Mac runs the media server
(LiveKit) and the support page; iPhone and Mac share one network. The iOS app finds the Mac
by itself (Bonjour), so nothing is typed in.

## Requirements
- macOS with Xcode (iOS 27 SDK for the whole-device mode), git, curl
- Node.js (support page): https://nodejs.org
- JDK 17–24, or Android Studio (its bundled JDK is picked up)
- A physical iPhone in the team's provisioning profile (team `P38WB3866W`)

## First run on a new Mac
```bash
./setup.sh   # once: downloads XcodeGen, builds LiveKit server into tools/, generates the Xcode project
./run.sh     # every time: media server + support page + network announcement
```
Then open `iosApp/ScreenSharePoC.xcodeproj`, pick the iPhone, Run.
Open http://localhost:8080 on the Mac. The app shows "Support can reach you" once it found the Mac.

`setup.sh` takes a few minutes the first time (LiveKit has no macOS binaries, so it is built from source;
a Homebrew `livekit-server` or `xcodegen` on PATH is used instead when present).

## Demo flow
1. Page: "Request · app" (only this app) or "Request · device" (whole screen, iOS 27+).
2. iPhone: Accept → system consent (device mode: pick "Entire screen").
3. Page: "Request control" → iPhone: Allow → click the video to tap, drag to scroll, "Pointer" to point.
4. Either side can end; the driver can turn control off and keep viewing.

## Android (emulator or phone)
```bash
./gradlew :androidApp:installDebug   # with an emulator running or a phone attached
```
The emulator reaches the Mac at `10.0.2.2` (no setup); a phone on the same Wi-Fi finds it by Bonjour.
Remote control needs a one-time switch: Settings → Accessibility → "ScreenShare PoC remote control" → On.
Run one driver app at a time (iOS joins as `driver`, Android as `driver-android`).

Android 15+ hides the whole app from screen sharing while a password field is on screen
("App content hidden from screen share for security"); the demo shows it with "Show / hide password field".

## Troubleshooting
- App stays on "Looking for the support server…": `run.sh` is not running, the iPhone is on another
  network, or Local Network access was denied (Settings → Privacy → Local Network).
- Bonjour blocked on the network: type the Mac's IP in the app (Session → Settings → Server).
- Ports 7880/8080 busy: another `run.sh` is running.

## Layout
- `shared/` — KMP: message protocol, session state machine, `ScreenShareEngine` interface, tests.
- `androidApp/` — Android driver app: LiveKit screen sharing (MediaProjection), remote control through an
  accessibility service (real gestures anywhere on the device), pointer overlay, the same shared session rules.
- `iosApp/` — SwiftUI app: LiveKit engine, own downscaled app capture, command executor, pointer overlay,
  Bonjour discovery, demo screens. `project.yml` is the source; the `.xcodeproj` is generated.
- `web/` — support console (`index.html`) and token server (`server.mjs`, LiveKit dev keys — local use only).
- `scripts/java-home.sh` — finds a JDK for Gradle (used by Xcode's KMP build step).
