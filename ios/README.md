# DuoDesk iOS

iPhone + iPad companion for DuoDesk. Side-loaded distribution — the IPA on every GitHub
Release is **unsigned**, and users resign it with their own cert.

**Status: Phases 1 and 2.** Pair over Wi-Fi, remote (touchpad and keyboard), clipboard, files,
the computer's notifications, and the computer's screen on the device. It compiles in CI; it
has not yet been run on a device or against a real computer. See
[`../docs/ios.md`](../docs/ios.md) for the plan, what was checked, and the known gaps.

**The computer needs a DuoDesk with iOS support** (`P.OS.IOS`, in this branch). An older
one pairs with the iPhone but files it as a Windows PC and ignores the remote.

## Install (users)

Four side-load paths. All of them resign the same IPA from the latest release.

| Path | Cert validity | Cost | Notes |
|---|---|---|---|
| [Signulous](https://www.signulous.com) | ~1 year | Paid | Recommended: the longest-lived cert. We haven't confirmed which entitlements their profile includes (multicast discovery, camera while locked), so some features may be reduced; Settings shows what this build has. Re-sign before the cert expires; the app shows a banner starting 30 days before. |
| [AltStore / SideStore](https://altstore.io) | 7 days | Free | Needs AltServer running on a Mac or PC on the same Wi-Fi to refresh. Some features reduced — see Settings. |
| [Sideloadly](https://sideloadly.io) | 7 days | Free | Windows-friendly alternative to AltStore. Same reduced-mode caveats. |
| Xcode (free personal team) | 7 days | Free | For contributors building from source. Open `DuoDesk.xcodeproj` after running `xcodegen generate`. |
| [TrollStore](https://github.com/opa334/TrollStore) | Permanent | Free (device-dependent) | Works on iOS 15.0 – 16.6.1 (and some 17.0 forks). Not actively supported but the IPA installs. |

Download the latest `DuoDesk-<version>.ipa` from the [releases
page](https://github.com/0xCodez/DuoDesk/releases) and feed it to any of the above.

## Build (contributors)

Requires macOS, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
cd ios
xcodegen generate
open DuoDesk.xcodeproj
# or, to produce an unsigned IPA from the command line:
./build-ipa.sh
```

The IPA lands in `ios/dist/DuoDesk-<version>.ipa`. Nothing in the project file is signed;
`CODE_SIGNING_ALLOWED` is `NO`. Resign for your own device from Xcode's Signing & Capabilities
tab (change the team, let Xcode manage automatically) or run the project with a device plugged
in.

## Layout

```
ios/
  project.yml           XcodeGen source (DuoDesk.xcodeproj is generated, not committed)
  build-ipa.sh          Command-line archive -> unsigned IPA
  package.json          Version source for the workflow
  DuoDesk/
    App.swift           SwiftUI entry; AppModel owns the session and the features
    Protocol.swift      Wire-protocol constants ported from ../shared/protocol.js
    Store.swift         Keychain tokens, UserDefaults for paired hosts
    Discovery.swift     UDP beacons on 47801
    Link.swift          PeerLink: WSS on 47800 with a pinned sha256 fingerprint
    Pairing.swift       SAS pairing state machine
    BLECentral.swift    Core Bluetooth: lists nearby computers (no session over it yet)
    USBTether.swift     127.0.0.1 listener (not wired to a session yet)
    Features/
      Feature.swift     Feature protocol, Peer, the ordered link-event inbox
      PairSyncFeature   The two-way switches shared with the computer
      Clipboard.swift   Text and pictures both ways
      Files.swift       The batch file protocol both ways
      Notifs.swift      The computer's notifications as local notifications
      Remote.swift      remote.* (hello/release/state, pointer, keys)
      KeyMap.swift      Characters and USB key usages -> KeyboardEvent.code
      Screen.swift      The computer's screen: window.TD shim around the Android viewer page
      WOL.swift         Wake-on-LAN magic packet
    UI/                 SwiftUI pages and the UIKit touchpad / key capture
    Util/
      SigningPosture.swift  Detects reduced-mode features at launch
    Resources/          Assets.xcassets (Info.plist and entitlements are generated)
```

The viewer page itself is not in `ios/`: `project.yml` bundles
`../android/app/src/main/assets/web` as a folder, so both apps play the computer's screen
with the same `viewer.html`/`viewer.js`.

The Xcode project file is **not** committed; `project.yml` is the source of truth. CI runs
`xcodegen generate` before building. This keeps diffs reviewable and avoids merge wars on
`project.pbxproj`.

## What works today, what doesn't

See [the plan's feature matrix](../docs/ios.md#feature-matrix) and
[Built so far](../docs/ios.md#built-so-far). Not done yet: the Bluetooth and USB links carry no
session, folders can't be sent, no gamepad, no chat, no camera or screen sharing from the
device (Phase 3), no calls (Phase 4). iOS does not allow texts, other apps' notifications, or
controlling the device from the computer, so those will never be here.

## License

GPL-3.0, same as the rest of DuoDesk.
