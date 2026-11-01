# iOS

Side-loaded iPhone and iPad companion for DuoDesk. Pair with any Mac, Windows PC or
Linux box the way the Android companion does, speak the same wire protocol, keep the
"no account, no cloud" promise.

Distribution is intentionally **side-load only**: an unsigned IPA on each GitHub Release.
Users resign it themselves with [Signulous](https://www.signulous.com) (year-long cert),
[AltStore / SideStore](https://altstore.io) (seven-day refresh, free Apple ID), or
[Sideloadly](https://sideloadly.io). No App Store build, no TestFlight, no notarized IPA.

Status: **planning**. Nothing in `/ios` yet. This document is the plan.

## Goals

- Match the Android companion feature-for-feature **where iOS has an API that reaches
  the same outcome**. Everywhere it doesn't, be honest about it in the UI (page present,
  explains why it is empty) rather than pretending the feature exists.
- Speak the existing wire protocol (`shared/protocol.js`, `PROTOCOL_VERSION: 1`) without
  the desktop side needing changes except where a feature is iOS-only (phone screen
  share — see Phone screen).
- Target iOS 16+ (SwiftUI 4, Swift Concurrency, `UIPasteControl`,
  `NSFileProviderReplicatedExtension`, `DataScannerViewController`, iPad extended-display
  scenes). iPhone 11+ and all iPads that run iOS 16.
- Build on `macos-latest` in GitHub Actions, mirror `build-android.yml`, ship an
  **unsigned IPA** on each release.

## Non-goals

Features that are structurally impossible on iOS to a third-party app and will not be in
the companion at any version:

| Feature | Why not |
|---|---|
| Read SMS / iMessage from the phone | No API exists; Apple reserves `Messages` to itself |
| Answer / end GSM calls from the PC | CallKit observes VoIP calls only, cannot drive the cellular stack |
| Mirror other apps' notifications to PC | No equivalent of `NotificationListenerService` |
| Mac/PC injecting mouse / keyboard into iOS | No synthetic input API on iOS |
| Mac/PC drawing a cursor over other apps on iOS | No cross-app overlay API |
| Phone-as-Bluetooth-HID gamepad for the PC | No outbound Bluetooth Classic HID; BLE-HID over `CBPeripheralManager` is unreliable with macOS/Windows and we don't ship it |
| Read system-wide "now playing" | `MPNowPlayingInfoCenter` is write-only to third-party apps |
| Toggle Wi-Fi / Bluetooth / DND / lock / sleep the device | All private APIs |
| List installed apps / read wallpaper | Private APIs |
| Host a Wi-Fi Direct group or Personal Hotspot | No public API; iOS can only *join* a hotspot via `NEHotspotConfiguration` |
| Read other apps' current foreground state (`phone.activeApp`) | No API |

These will appear in the companion as pages that say what they would do and point at the
Android app for users who need them.

## Platform constraints that shape every design decision

Five iOS realities that are not negotiable with any amount of entitlement work and that
every feature plan below has to respect:

1. **APNs is bound to the signer, not DuoDesk.** A Signulous-signed build gets
   `aps-environment`, but the APNs certificate / token lives in Signulous's Apple account
   under their bundle ID. We cannot run a DuoDesk push backend against a Signulous-signed
   build. That removes PushKit VoIP push, push-to-start Live Activities, and silent
   remote wake from the possible designs — **PC → phone wake / notification mirroring is
   foreground-first.**
2. **Background execution is capped at ~10 minutes even with `voip` background mode, and
   TCP sockets do not survive device suspension.** Apple DTS says so explicitly. The
   companion runs in two modes: **active** (app foreground OR a user-started ReplayKit
   broadcast OR a BLE central scan with a nearby peer) and **sleeping** (nothing is
   guaranteed). We surface that state in the UI.
3. **MultipeerConnectivity is deprecated in iOS 26 and already flaky on iPhone 13+.** Its
   documented successor Wi-Fi Aware is iOS 26+, iPhone 12+, needs a managed entitlement,
   and has no macOS/Windows/Linux/Android peer. **Treat shared-Wi-Fi + Bonjour as the
   only reliable transport.** BLE is the fallback. USB (via usbmuxd on the PC) is the
   secondary tether.
4. **Signulous certificates get revoked occasionally.** When Apple revokes a
   re-signer cert every installed copy stops launching until users re-install. Treat
   this as an operational cost, not a one-off: the companion must show a visible
   "re-install from <signulous.com>" banner starting 30 days before expiry, and the
   website must link to a current signing guide.
5. **Clipboard, camera-in-background, and ReplayKit all have hard ceilings no
   entitlement softens.** `UIPasteControl` or a foreground-only read is the only way to
   avoid the paste toast; the camera cannot run with the screen locked without the
   Apple-managed `multitasking-camera-access` entitlement; a Broadcast Upload Extension
   is capped at ~50 MB RAM. Features scoped accordingly.

Any plan that assumes "the companion stays online all day in the background" is wrong on
iOS. The design is foreground-biased by necessity.

## Transports

Mirrors the Android transport stack (`shared/netlink.js`, `shared/blepipe.js`, UDP
beacons) except where iOS forces a different API.

| Transport | iOS API | Role | Entitlement / Info.plist |
|---|---|---|---|
| **UDP broadcast on 47801** (`DISCOVERY_PORT`, same as desktop + Android) | `NWConnection` to `255.255.255.255:47801` with `allowFastOpen`, plus matching `NWListener` | Discovery beacons, probes, invites | `NSLocalNetworkUsageDescription`, `com.apple.developer.networking.multicast` (Apple-managed, usually in a Signulous bundle), and the type listed in `NSBonjourServices` because iOS otherwise silently drops the probe |
| **WSS on 47800** (`PORT`, same) | `URLSessionWebSocketTask` with `maximumMessageSize = 16 * 1024 * 1024` and a `URLSessionDelegate` that pins by `sha256` of the leaf DER (same `fp` the Android app pins) | Pairing + control + every `t:*` RPC | `NSLocalNetworkUsageDescription` |
| **BLE central pipe** (`shared/blepipe.js`, host advertises `SERVICE 0xb7f30001…`) | `CBCentralManager` + GATT `INFO`/`CTRL`/`UP`/`DOWN` characteristics, same framing | Tunnels the WSS session byte-for-byte when the LAN is missing | `NSBluetoothAlwaysUsageDescription`, `UIBackgroundModes = bluetooth-central`; background scan requires an explicit service UUID filter |
| **BLE peripheral** (phone advertises `PHONE_SERVICE 0xb7f30006…` and the PC connects outbound) | `CBPeripheralManager` with a GATT service of the same shape | Lets a PC that cannot advertise still reach the phone over BLE | `UIBackgroundModes = bluetooth-peripheral`; background adverts land in the overflow area and are only readable by a scanner that filters by the explicit UUID (PCs do — they know it) |
| **USB tether** | `NWListener` on `127.0.0.1:47800`; PC side uses `usbmuxd` (built into macOS, `libimobiledevice` on Linux/Windows) | Second screen / webcam / low-latency control when a cable is in | None on the iOS side; requires device-wide Developer Mode in iOS 16+ |
| **MultipeerConnectivity** (legacy) | `MCSession` with `_duodesk._tcp` as serviceType | Short-term fallback only; **not** the primary transport. Expect to retire this once iOS 26's bugs on iPhone 13+ get worse. | `NSLocalNetworkUsageDescription`, `NSBonjourServices` |

iOS cannot host Wi-Fi Direct or Personal Hotspot. For `net.join` the companion can
**join** a Wi-Fi SSID the PC publishes using `NEHotspotConfiguration` (Hotspot
Configuration capability — not available on a free Apple ID, works on Signulous). It
cannot host.

The companion is always a **guest** on the WSS layer (same as the Android app). The
phone-side TLS keypair only matters for the FolderShare in-app server; the Signulous
cert does not need any iOS-side CA plumbing.

## Pairing

Exact same flow as `shared/link.js` / `mac/pairing.js`: UDP beacon →
`pair.start / pair.nonce / pair.reveal` → both sides compute the six-digit SAS from
`sha256("macshare-sas-v1" || fp || nw || nm)` → user taps **Codes match** → `pair.ok`
hands the phone a 32-byte hex token. Phone stores
`{id, name, os, address, port, fp, token}` in `Keychain` (not `UserDefaults` — the token
is the one secret).

On reconnect: `hello {v:1, id, name, os:"ios", token, fx:1}` and the host sends
`welcome`. We identify as `os:"ios"`, which the Android companion already treats as
"phone peer" for `PHONE_GRACE_MS`.

QR pairing uses `DataScannerViewController` (iOS 16+) for the scan side and
`CIFilter.qrCodeGenerator()` to display. Universal Links on
`https://getduodesk.vercel.app/pair?…` are the preferred invite form; the custom
`twindesk://pair?…` scheme stays as a fallback.

## Feature matrix

Mapped from the Android module audit. Legend: **✓** ships in phase shown, **◐** ships
reduced from Android, **—** cannot ship.

| Feature | iOS plan | Phase |
|---|---|---|
| Pair over Wi-Fi + BLE + USB | ✓ `URLSessionWebSocketTask` + Core Bluetooth + usbmuxd | 1 |
| QR pair | ✓ `DataScannerViewController` scan, `CIFilter` display | 1 |
| Overview / sidebar / pages UI | ✓ SwiftUI `NavigationSplitView` matching Aurora look | 1 |
| Phone-as-remote (trackpad + keyboard) | ✓ UIKit touch + hidden `UITextField`, same `remote.*` messages | 1 |
| Phone-as-gamepad | ✓ `GCVirtualController` → serialize into `remote.pad` (the PC still owns the virtual HID) | 1 |
| Clipboard text sync | ✓ `UIPasteboard` + `UIPasteControl`; **foreground only** on phone→PC | 2 |
| Clipboard image sync | ✓ Same, chunked `clip.image` + `clip.image.part` under 10 MiB | 2 |
| File send / receive | ✓ `file.offer` / `file.chunk` / `file.end` plus `fx` fast-files over HTTPS PUT | 2 |
| Share extension (receive files into DuoDesk from any app) | ✓ Share Extension target | 2 |
| iPad as second screen | ✓ `rtc2.*` offer, `VTDecompressionSession` → `AVSampleBufferDisplayLayer`; `in.*` absolute coords from the viewer | 2 |
| Phone camera as PC webcam | ✓ `AVCaptureSession` + `VTCompressionSession` H.264/HEVC → `cam.offer` WebRTC. Low-latency H.264 mode. **Foreground / unlocked only** on free sideload; Signulous may grant `multitasking-camera-access` on request for locked-screen capture | 3 |
| Screen broadcast (phone screen → PC) | ✓ **New feature; needs matching desktop work.** Broadcast Upload Extension target (`RPBroadcastSampleHandler`); extension encodes H.264 and ships `CMSampleBuffer` to the main app over an App Group `CFMessagePort`, main app sends via a new `phone.screen.*` WebRTC path (brand new — scrcpy has no iOS counterpart) | 3 |
| Files app provider (DuoDesk folder in Files) | ✓ `NSFileProviderReplicatedExtension` target backed by the paired PC's share | 3 |
| In-app DuoDesk chat | ✓ `chat.*` messages (phase 2 of this doc proposes adding to protocol.js) stored in SwiftData; iOS can send while foreground, receives queued messages on next foreground | 2 |
| PC → phone notifications (one-way) | ◐ Local `UNNotificationRequest` when the companion is awake. **No remote-push wake** on sideload — if the app is suspended, the notification waits until next foreground. | 2 |
| Phone media / photos browse | ✓ `PHPhotoLibrary` + `PHAsset`, same `media.list / media.thumb / media.view / media.save` messages | 3 |
| Screenshot auto-copy | ✓ `PHPhotoLibraryChangeObserver` filtering `PHAssetMediaSubtype.photoScreenshot` | 3 |
| Folder share (phone → PC) | ◐ File Provider Extension exposes **the DuoDesk app's own documents** and anything the user imports via `UIDocumentPicker` security-scoped bookmark; no system-wide folder host | 3 |
| Call audio bridge | ◐ **Foreground only.** The companion can route call audio while the app is open, cannot wake on an incoming call because APNs is bound to Signulous. CallKit UI is wired as the in-app surface and goes nowhere else. | 4 |
| Call log, contacts, dial | ◐ `Contacts.framework` for contacts; `tel:` URL to dial. Call log unreadable — the Calls page omits history. | 4 |
| ReZume (continue what you were doing) | ✓ In-app Handoff via `NSUserActivity`; iOS can offer the current URL / document in the DuoDesk app and take an offered one from a Mac/Win/Linux peer | 4 |
| Wake-on-LAN from phone | ✓ `NWConnection` UDP broadcast with the magic packet | 1 |
| Quick Settings tile (clip) | ◐ iOS 18 **Controls** framework widget as an approximate equivalent | 4 |
| App Intents / Shortcuts | ◐ App Intents donations for recent peers; closest to Android's dynamic Sharing Shortcuts | 4 |
| Device controls (ring, volume) | ◐ Ring: play a loud sound in the companion app. Volume read: unreliable on iOS 17+ (`MPVolumeView` deprecated). Lock / sleep / Wi-Fi / BT / DND toggles: — | 4 |
| Phone info to PC | ◐ Model, battery, screen size via `UIDevice` + `ProcessInfo` + `UIScreen`. Wallpaper, installed apps: — | 2 |
| SMS / MMS, notification mirror, foreground-app detection | — | — |
| Mac controls phone's apps (`phone.send`, `phone.in`, `phone.mirror`) | — (no synthetic input / no scrcpy on iOS) | — |
| Mac draws cursor on phone (`phone.pointer`) | — (no cross-app overlay) | — |

## Protocol compatibility

Everything in `shared/protocol.js` the companion needs is already defined. There are
three protocol additions worth proposing in a follow-up PR (iOS can ship without them
by polyfilling, but desktop support will be cleaner with them):

1. **`phone.screen.*`** — a WebRTC path for streaming an iOS screen broadcast up to a
   paired PC. Mirrors `cam.offer / cam.answer / cam.ice / cam.state` with `kind:"screen"`.
   The Android companion uses scrcpy; iOS cannot. Desktop clients need a new "iOS
   phone screen" viewer path or they can reuse the existing `screen.*` renderer with a
   new `source:"ios-broadcast"` field.
2. **`remote.kd / remote.ku` key naming** — the companion sends KeyboardEvent-style
   `code`, same as the browser remote already does. The old Android `phone.in a:"k"`
   path with Android keycodes is **not** implemented on iOS.
3. **`clip.policy {paste: "manual"}`** — explicit flag the companion sets so the desktop
   does not auto-request clipboard on every change (iOS cannot read the pasteboard in
   the background without a toast). Desktop side already respects `clip.policy.accept`
   so this is additive.

Everything else — pairing, hello/welcome, clip, file, drag, remote, in, screen, cam,
audio, chat (new), notif, media, fs, share, rz, dev, pair.sync, wol, hub, net — is
spoken as-is. Android-only messages (`adb.*`, `smb.*`, `ssh.*`, `sms.*`, `phone.send`,
`phone.in a:"d"|"m"|"u"|"s"|"k"` applied by Accessibility, `phone.sound`, `phone.pointer`,
`phone.activeApp`, `call.log`) are **not** sent by iOS; incoming ones get answered with
`{perm:"none"}` on the matching `*.policy` or `hub.state` so the desktop UI hides them.

The pinned-fingerprint TLS, the hybrid logical clock on `clip`, the `fx` HTTPS fast-files
path, and the `PHONE_GRACE_MS` 30-second takeover window all port over without protocol
changes — only iOS-side implementation.

## Project layout

```
ios/
  DuoDesk.xcodeproj              # or Package.swift if we go SPM-only
  DuoDesk/                        # main app target
    App.swift
    Pairing.swift                 # ~ Core.kt + Link.kt
    Protocol.swift                # ~ Proto.kt — port of shared/protocol.js constants + sasCode
    Store.swift                   # Keychain for tokens, UserDefaults for everything else
    Discovery.swift               # UDP beacon + probe
    Bonjour.swift                 # optional NWBrowser helper
    BLECentral.swift              # ~ Ble.kt
    BLEPeripheral.swift           # ~ BleServe.kt
    Multipeer.swift               # ~ Netlink.kt replacement (legacy, foreground only)
    USBTether.swift               # 127.0.0.1 listener for usbmuxd on the PC
    UI/
      Aurora/                     # SwiftUI port of the Aurora shell & pages
      Pages/
        OverviewPage.swift
        PairingPage.swift
        RemotePage.swift
        ClipboardPage.swift
        FilesPage.swift
        CameraPage.swift
        BroadcastPage.swift
        PhoneScreenPage.swift     # a landing + "start broadcast" button
        CallsPage.swift
        MediaPage.swift
        ReZumePage.swift
        ChatPage.swift
        SettingsPage.swift
    Features/
      Clipboard.swift             # UIPasteControl + changeCount polling on foreground
      FileClip.swift              # fclip.* using NSItemProvider promises
      Files.swift                 # file.* over control channel + fx over URLSession
      Camera.swift                # AVCaptureSession → VTCompressionSession → WebRTC
      Viewer.swift                # VTDecompressionSession → AVSampleBufferDisplayLayer
      WebRTC.swift                # thin wrapper around GoogleWebRTC or Apple's new Media
      Remote.swift                # trackpad + keyboard + gamepad input serialization
      Notify.swift                # UNUserNotificationCenter
      Chat.swift                  # new; SwiftData store
      Media.swift                 # PHPhotoLibrary
      Screenshots.swift           # PHPhotoLibraryChangeObserver
      Rezume.swift                # NSUserActivity
      WOL.swift                   # magic-packet sender
      DeviceInfo.swift            # UIDevice / ProcessInfo
      Calls.swift                 # Contacts + tel: URL; CallKit audio-only
    Util/
      AppGroupBridge.swift        # IPC with extensions over CFMessagePort + shared container
      LogRing.swift
    Resources/
      Info.plist
      DuoDesk.entitlements
  BroadcastUpload/                # Broadcast Upload Extension target
    SampleHandler.swift           # RPBroadcastSampleHandler → encode → App Group pipe
    BroadcastUpload.entitlements
  FileProvider/                   # NSFileProviderReplicatedExtension target
    Extension.swift
    FileProvider.entitlements
  Share/                          # Share Extension target (receive files into DuoDesk)
    ShareViewController.swift
    Share.entitlements
  Controls/                       # iOS 18 Controls widget target (clip-tile analog)
    ClipControl.swift
  dist/                           # IPA output (git-ignored)
  package.json                    # single source of version string, mirror android/'s layout
  build-ipa.sh                    # xcodebuild archive + hand-rolled Payload/*.app zip
  README.md                       # how to resign (Signulous / AltStore / Sideloadly / Xcode)
  entitlements/
    DuoDesk.entitlements          # requested bundle (see table below)
```

Four extension targets. They all share one App Group
(`group.com.twindesk.ios.shared`) for IPC. The main app does all network I/O; extensions
hand data over the pipe. This keeps the ~50 MB Broadcast Upload memory budget tight by
pushing encoding into the extension and leaving the socket in the main app.

## Entitlements and Info.plist

The companion requests the following in its entitlements file. Signulous grants the
"usually grants" column at profile build time; free-team sideloads skip the ones marked
in the audit as fragile and the affected features fall back to foreground-only.

| Key | Target | Needed for | Signulous | Free team |
|---|---|---|---|---|
| `aps-environment` | main app | nothing we rely on — see note | granted (unusable from our backend) | — |
| `com.apple.developer.networking.multicast` | main app | UDP broadcast beacons | usually | — |
| `com.apple.developer.networking.HotspotConfiguration` | main app | `net.join` | usually | — |
| `com.apple.developer.avfoundation.multitasking-camera-access` | main app | locked-screen webcam | on request | — |
| `com.apple.security.application-groups` = `group.com.twindesk.ios.shared` | all | main↔extension IPC | usually | fragile |
| `com.apple.developer.fileprovider.*` | File Provider | Files app folder | usually | fragile |
| `com.apple.developer.networking.wifi-info` | main app | reporting SSID in `net.*` | usually | works |

Info.plist on the main app:

```
NSLocalNetworkUsageDescription   = "DuoDesk talks to your computer on the same Wi-Fi."
NSBluetoothAlwaysUsageDescription = "DuoDesk uses Bluetooth to find and connect to your computer."
NSCameraUsageDescription         = "DuoDesk uses the camera for QR pairing and the webcam feature."
NSMicrophoneUsageDescription     = "DuoDesk uses the microphone when the webcam feature records audio too."
NSPhotoLibraryUsageDescription   = "DuoDesk sends photos you choose to your computer."
NSContactsUsageDescription       = "DuoDesk reads contacts so you can see who is calling and dial from the computer."
NSBonjourServices                = [ "_duodesk._tcp", "_duodesk._udp" ]
UIBackgroundModes                = [ "bluetooth-central", "bluetooth-peripheral",
                                     "voip", "audio", "fetch", "processing" ]
UIFileSharingEnabled             = YES
LSApplicationQueriesSchemes      = [ "tel", "sms", "mailto" ]
CFBundleURLTypes                 = [ { CFBundleURLSchemes = [ "twindesk" ] } ]
```

The `voip` background mode is present only to keep the control socket alive for the
10-minute best-effort window on the paths that reach it (Camera, Broadcast). We do
**not** register for PushKit VoIP pushes; Apple's throttling makes it pointless, and the
cert story blocks real use anyway.

## Side-load distribution

The IPA ships **unsigned / ad-hoc**. Each resigner wraps it with their own cert and
provisioning profile.

- **Signulous (recommended for most users)** — upload the IPA to
  <https://www.signulous.com>, pay for a 1-year certificate, install the resigned IPA via
  their link. The profile is in Signulous's Apple account; some entitlements
  (`multitasking-camera-access`, `pushkit.unrestricted-voip`) depend on what Signulous
  holds — the companion checks what it actually has at launch and disables the dependent
  features cleanly.
- **AltStore / SideStore** — install [AltServer](https://altstore.io) on a Mac or PC, add
  the IPA, install to the paired iPhone. Certificate expires every seven days;
  AltServer refreshes on the same Wi-Fi. No `aps-environment`, no HotspotConfiguration,
  no reliable App Groups — expect the companion to run in a reduced mode and tell the
  user why on the Settings page.
- **Sideloadly** — same model as AltStore; useful for Windows users without AltServer.
- **Xcode free personal team** — contributors building from source: open
  `ios/DuoDesk.xcodeproj`, change the team to their Apple ID, build and run. Same
  seven-day expiry and reduced capability set as AltStore.
- **TrollStore** (A12–A15 devices, iOS 15–16.6.1 and some 17.0 forks) — permanent
  install, no cert expiry. We don't actively support it but the IPA is TrollStore-shaped
  so it should install.

The companion detects its own signing posture at launch
(`SecCodeCopySigningInformation` on its own binary) and shows the reduced-mode banner on
the Settings page when a feature can't work on this cert.

A **certificate-expiry banner** fires on the Overview page starting 30 days before the
embedded profile expires, with a one-tap deep link to <https://www.signulous.com> or the
corresponding AltStore / Sideloadly instructions.

## Build and release pipeline

New workflow `.github/workflows/build-ios.yml`, modeled on `build-android.yml`:

- Trigger: push `v*` tag, or `workflow_dispatch { tag, ref }`.
- Runner: `macos-latest` (required for `xcodebuild`).
- Steps:
  1. `actions/checkout@v4`
  2. `maxim-lobanov/setup-xcode@v1` pinned to a recent stable Xcode (currently 16.x on
     `macos-latest`).
  3. Read version from `ios/package.json` with `jq`, substitute into `Info.plist` via
     `PlistBuddy` (keeps parity with the pattern Android uses in `build.gradle.kts`).
  4. `xcodebuild archive -scheme DuoDesk -configuration Release -archivePath DuoDesk.xcarchive \
         -destination 'generic/platform=iOS' \
         CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
         ONLY_ACTIVE_ARCH=NO`
  5. Hand-roll the IPA:
     `mkdir Payload && cp -R DuoDesk.xcarchive/Products/Applications/DuoDesk.app Payload/ && \
      zip -qry "ios/dist/DuoDesk-$v.ipa" Payload`
  6. `actions/upload-artifact@v4` with name `duodesk-ios`.
  7. `gh release view "$TAG" || gh release create "$TAG" --prerelease` then
     `gh release upload "$TAG" ios/dist/DuoDesk-*.ipa --clobber` — same block as
     `build-android.yml`.

No new secrets needed. The macOS workflow's Developer-ID / notarytool / provisioning-
profile machinery is deliberately not inherited: the IPA is unsigned on purpose.

A single version source is overdue. In the same change as adding `/ios`, add a
`scripts/bump-version.sh` that updates:

- `mac/package.json`, `windows/package.json`, `linux/package.json`
- `android/app/build.gradle.kts` (`versionName`, `versionCode`)
- `ios/package.json` (new)
- `flake.nix` (currently drifted at `2.5.0-beta.1` — fix as part of this)
- The hard-coded `v2.5.0` URLs in `README.md`'s download table

## Website

Two changes to the download page, matching the audit:

1. `website/api/download.js` — add `ios: n => /^DuoDesk-.*\.ipa$/.test(n)` to `PICK`.
2. `website/index.html` — add a fifth `article.dl[data-os="ios"]` card and an `os-ios`
   SVG symbol. The CTA is "Download IPA" with a secondary line "Install with Signulous,
   AltStore or Sideloadly" linking to a new `website/sideload.html` page that walks
   through each option. The README's `## Download` section gets a matching
   `**🍏 iOS**<br><sub>16+</sub>` cell and a link to the IPA on the latest release.

## Milestones

Each phase is a pull request chain that ships a usable companion at the end of it.

### Phase 1 — Skeleton + pairing + remote (one working feature end to end)

- `/ios` Xcode project, main app target, SwiftUI shell, Aurora port of the sidebar and
  Overview/Pairing/Remote/Settings pages.
- `Pairing.swift`, `Protocol.swift`, `Store.swift`, `Discovery.swift`, `BLECentral.swift`
  (central only; peripheral in phase 3), `USBTether.swift`.
- QR pair + manual pair + reconnect with pinned fingerprint.
- Phone-as-remote: trackpad, keyboard, gamepad.
- `.github/workflows/build-ios.yml` producing an IPA.
- Website card + sideload page.
- README iOS cell.
- Signing-posture detection + reduced-mode banner.

Shippable as a point release (e.g. 2.6.0 if a desktop PR goes with it, or a
`v2.5.1-ios-preview` tag if iOS wants to move alone).

### Phase 2 — Clipboard + files + chat + viewer

- `Clipboard.swift` with `UIPasteControl` and `changeCount` polling on
  `applicationDidBecomeActive`.
- `Files.swift` with `file.*` over control channel and `fx` fast-files via `URLSession`
  upload tasks (TLS pinning with session tickets disabled).
- Share Extension target.
- `Chat.swift` + SwiftData store + protocol-side proposal to add `chat.*` messages
  (behind a `pair.sync chat` toggle for backward compatibility).
- `Viewer.swift` + `WebRTC.swift` — iPad-as-second-screen receives `rtc2.*` offers from a
  paired Mac/Win/Linux and renders.
- Local notifications when the app is foreground + a UI explanation of the suspension
  behavior.

### Phase 3 — Camera + screen broadcast + file provider + media + BLE peripheral

- `Camera.swift` AVCaptureSession → VTCompressionSession → WebRTC into `cam.*`.
- Broadcast Upload Extension target + `phone.screen.*` protocol addition proposal.
  **Needs a matching desktop PR** so Mac/Win/Linux can display an iOS phone screen.
- `NSFileProviderReplicatedExtension` target.
- `Media.swift` + `Screenshots.swift` for photo browsing and screenshot auto-copy.
- `BLEPeripheral.swift` so a PC can connect outbound.

### Phase 4 — Calls audio + ReZume + Controls widget + App Intents + device controls

- `Calls.swift` with CallKit UI, foreground-only audio bridge, `tel:` dial, Contacts
  search.
- `Rezume.swift` via `NSUserActivity`.
- iOS 18 Controls widget for a clip-tile analog.
- App Intents donations for recent peers.
- `DeviceInfo.swift` reporting the subset iOS exposes.

### Phase 5 — Polish

- iPadOS extended-display scene for driving an attached monitor.
- Universal Link `apple-app-site-association` (needs the paid dev account's team ID for
  Signulous builds — can be shipped if Signulous lets us use theirs).
- Logging / crash reporting that doesn't violate the no-cloud promise (`os_log`
  + a local ring buffer, user-triggered share to Mac over the pair).
- Localization pass.

## Open questions

Before phase 1 opens a PR, these need answers:

1. **Bundle ID and team.** Pick a `com.twindesk.ios` bundle (or `app.duodesk.ios` if we
   want to rebrand off the twindesk legacy). Signulous attaches its own team ID at
   resign time; our source-of-truth bundle ID still needs to be unique.
2. **Signulous entitlement check.** We depend on
   `multitasking-camera-access` for locked-screen webcam and
   `com.apple.developer.networking.multicast` for UDP discovery. Both are "may grant on
   request" — ask Signulous support directly whether their standard profile includes
   them, or whether we need to ask for a custom profile per release.
3. **WebRTC library choice.** `GoogleWebRTC` is unmaintained for current Xcode; the
   community `WebRTC-SDK` xcframework is the usual replacement. Confirm the Mac/Win/Linux
   WebRTC implementations (`shared/camshare.js`, `shared/camshare-mesh.js`) negotiate
   codecs the chosen iOS build supports (H.264 baseline is safe; HEVC is iPhone 7+ encode
   and iPhone 7+ decode but desktop support is partial).
4. **Protocol version bump.** Adding `phone.screen.*` and `chat.*` could ride on
   `PROTOCOL_VERSION: 1` with capability flags in `hello`, or we bump to `v: 2`. Prefer
   capability flags (keeps older desktops working with an iOS phone minus phone-screen /
   chat).
5. **Scrcpy-equivalent, or not?** Decide whether the desktop clients grow a WebRTC-based
   iOS-screen viewer (new work on three desktops), or whether iOS phone-screen share is
   explicitly scoped to a "the Mac's DuoDesk window shows your phone over WebRTC" mode
   that doesn't try to match scrcpy's per-app window behavior. The latter is
   phase-3 scope; the former is a separate project.
6. **Signulous link in the UI.** The 30-day expiry banner should deep-link somewhere.
   Confirm Signulous supports a per-user "my IPAs" URL we can send users to; otherwise
   link to a DuoDesk sideload-help page that explains the current refresh step.

## References

- [`shared/protocol.js`](../shared/protocol.js) — wire protocol constants and the
  `sasCode` function this companion ports verbatim.
- [`shared/link.js`](../shared/link.js) and [`mac/pairing.js`](../mac/pairing.js) —
  pairing state machine.
- [`shared/blepipe.js`](../shared/blepipe.js) — BLE service and characteristic UUIDs
  and the GATT framing the companion needs to match.
- [`android/app/src/main/java/com/twindesk/android/`](../android/app/src/main/java/com/twindesk/android/) — Android
  companion the iOS one is modeled on, module-for-module.
- [`.github/workflows/build-android.yml`](../.github/workflows/build-android.yml) —
  pipeline the iOS workflow mirrors.
