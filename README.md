# AirliftSilence (iOS)

On-device switch for the iPhone call-recording announcement — no computer needed.

A minimal SwiftUI app built on the same AirTraffic sandbox escape as
[AirCard-iOS](https://github.com/Mak5er/AirCard-iOS). It talks to the phone's own internal
services over a `LocalDevVPN` loopback tunnel and swaps the three audio files iOS plays when call
recording starts and stops.

Three actions, available on screen and from Shortcuts:

| Action | What it does |
|---|---|
| **Silence the announcements** | writes the bundled silent files over the three announcement files |
| **Check** | reads them back and reports silenced / original / unknown build |
| **Restore the originals** | writes the bundled originals back |

The interface is English by default, with a Simplified Chinese translation — see
[Languages](#languages).

## Why detection needs a Rust change

`AirCard-iOS`'s shipped `AirliftFFI` can only *write*. The escape itself can only move objects
around, so reading a file means:

1. relocate the symlink into `Media`,
2. ask ATAirlock to move the target file out to a `Media` path (that's the same trick the
   reference PoC uses to verify its canary),
3. read it over AFC,
4. write it straight back.

This repository adds `al_exploit_read_file_hash()` to the Rust core for step 1–4 and returns the
file's **size + SHA-256** rather than raw bytes, so Swift never has to handle a binary buffer over
the C ABI. The write-back reuses the proven writer, so a read never leaves the device short a file.

The original write path is untouched on purpose.

## Requirements

- iOS 18.0 – 27.2 beta 2. **Apple patched the underlying `airlift` exploit in iOS 27.2 beta 3** —
  do not update past beta 2 or this stops working.
- [LocalDevVPN](https://github.com/rooootdev/LocalDevVPN) running in loopback mode (the app dials
  `10.7.0.1` by default, then falls back through the other tunnel gateways). **Never point it at
  `127.0.0.1`** — on iOS that makes `remotepairingdeviced` reject the control channel and enter a
  drop state where every later connection fails, recoverable only by toggling Developer Mode off
  and on.
- A pairing record. Either import one (AirDrop / Files → the app's Documents, as
  `airlift_pairing.plist`), or use the built-in on-device pairing: **Start pairing** → note the PIN →
  Settings › Privacy & Security › Developer Mode › **Pair with AirliftSilence**.
  Allow notifications when asked: the PIN is also delivered as a notification, because the moment it
  appears you are inside Settings typing it and the app's own screen is out of sight.
- The official Apple Books app installed and opened at least once — `com.apple.atc` refuses the
  sync otherwise, which is the #1 cause of "ReadyForSync not observed".

### Moving the pairing record around

Once a record exists, **Export pairing file** hands it to the share sheet — AirDrop, Save to Files,
and so on. Worth doing: re-signing a sideloaded build gives it a fresh container, so the record does not
survive a reinstall.

Getting one back in has three routes, in rough order of reliability:

1. **Import pairing file** — an in-app file picker. Works with the `.plist`,
   `.mobiledevicepairing` and `.mobilepairing` names the various sideloaders use.
2. Drop the file into the app's Documents folder (file sharing is on), named
   `airlift_pairing.plist`.
3. Open a `.plist` with *AirliftSilence* from the share sheet (`Open in AirliftSilence`).

## Build

The Rust core has to be compiled for iOS, so the build needs macOS. If you don't have a Mac,
**let GitHub build it** — `.github/workflows/build-ios.yml` runs on a macOS runner and uploads an
unsigned IPA (macOS runners are free for public repositories):

1. Push this repository to GitHub.
2. Actions → *Build unsigned IPA* → Run workflow.
3. Download the `AirliftSilence-unsigned-ipa` artifact.

On a Mac with Xcode:

```sh
brew install xcodegen
./build-ios.sh          # rust-core -> AirliftFFI.xcframework
./build-ipa.sh Release  # -> build/AirliftSilence.ipa (unsigned)
```

The IPA is deliberately **unsigned** — sign it with whatever you normally use (AltStore,
SideStore, Sideloadly, TrollStore, …).

> [!IMPORTANT]
> `SilenceApp.swift` force-references `ALGetGrappaToken`. The Rust side looks that symbol up with
> `dlsym`, so without the hard reference the linker may drop it and every sync then fails with
> *"Grappa session could not be established"* on iOS 27.0.1+. Keep that line.

## What it touches

All three recordings live in one directory, so a single write covers them:

```
/var/mobile/Library/CallServices/Greetings/default/StartDisclosureWithTone.m4a
/var/mobile/Library/CallServices/Greetings/default/StopDisclosure.caf
/var/mobile/Library/CallServices/Greetings/default/StartDisclosure.caf
```

The bundled `silent-*` files are plain `ffmpeg anullsrc` silence, matched to the duration and codec
of the versions shipping today (AAC 1.672 s, Opus 1.940 s, Opus 1.280 s), so playback timing is
unchanged. `Greeting.caf` and `GreetingWithTone.m4a` sit in the same folder and are deliberately
left alone — those are voicemail greetings, not recording announcements.

The `original-*` files hold Apple's current recordings so **Restore the originals** has something to
put back.
Those two are Apple's audio, bundled for your own device only — don't redistribute this repository
with them if that matters to you.

Both sets sit in one folder with a `silent-` / `original-` prefix, because XcodeGen flattens
directory contents into the bundle root and the two files share a name; the staging step copies each
one to its real filename before it is written to the device.

## Shortcuts and Siri

The app ships three `AppIntent`s, so it shows up in the Shortcuts app as an action of its own:

| Shortcut action | Notes |
|---|---|
| *Call-recording announcement* | one step with an **Action** menu: Check / Silence / Restore |
| *Silence the call-recording announcements* | no parameters — the one to put on the Home Screen |
| *Restore the call-recording announcements* | no parameters |

Each one returns the outcome as text (`Call-recording announcements: Silenced`, …) so a Shortcut can
branch on it or show it in a notification. Shortcuts are queued in the app: a run that arrives while
the on-screen check is still going waits for it, because the device only tolerates one session at a
time.

The intents open the app when they run. That is deliberate — a run is a long device-side session and
an iOS background intent gets cut off after a few seconds, which would tear the tunnel down
mid-transfer. Siri phrases are provided in both languages, e.g. *"AirliftSilence 去掉通话录音提示音"*.

The app also answers a URL scheme, for anything that can only open a URL (an *Open URLs* action, a
launcher, a bookmark):

```
airliftsilence://check
airliftsilence://silence
airliftsilence://restore
```

## Languages

English is the development language; Simplified Chinese ships as `zh-Hans`. Strings are **not** in a
String Catalog — the `.strings` files are hand-written and the keys are the English strings exactly
as they appear in the Swift sources:

```
ios-app/en.lproj/Localizable.strings        # English (development language)
ios-app/zh-Hans.lproj/Localizable.strings   # Simplified Chinese
ios-app/{en,zh-Hans}.lproj/InfoPlist.strings # the Local Network permission prompt
```

To add a language: copy `en.lproj` to `<language>.lproj`, translate the values (keep the keys and
their `%@` placeholders in the same order), add the language to `CFBundleLocalizations` in
`Info.plist`, and re-run `xcodegen generate`. `en.lproj` has to stay in place: XcodeGen only creates
localisation variant groups when it finds the development-language folder.

Nothing may drift silently:

```sh
python3 tools/check-strings.py   # also runs in CI
```

It checks that every key still exists in the sources (after normalising `\(..)` to `%@`), that `en`
and `zh-Hans` hold the same keys in the same order with matching placeholder counts, that
`InfoPlist.strings` only overrides keys the plist defines, and reports any source string that looks
like UI text but has no translation.

## Known limits

- **Apple updates these files as a silent `MobileAsset` update** — no iOS version change, no
  notification. When that happens your silence is overwritten and the sound comes back. Reopen the
  app and press **去除提示音**. It has happened once so far; it is not a boot-time check, so
  rebooting is safe.
- The periodic **"ding ding ding"** reminder during a long recording is
  `recurringDisclosureTwinkle.caf` inside `TelephonyUtilities.framework` on the sealed system volume.
  This exploit cannot replace a sealed-volume file, so that one stays. Only the start/stop
  announcements are silenceable from the app.
- A reboot does **not** undo it. Verified by byte-comparing both files before and after a restart.
- The announcement plays to **both parties** on the call. Removing it may be unlawful where
  recording requires all-party consent (Germany, several US states). Get consent before recording
  anyone — the law applies to you whatever your phone does or does not announce.

## Naming and artwork

The app calls itself **AirliftSilence** everywhere it is visible: the home screen, the navigation
title, the pairing host advertised to Settings, and the pairing file it leaves in Documents
(`airlift_pairing.plist`). Nothing user-facing carries the upstream AirCard name.

The icon is drawn from scratch by `tools/make-icon.py` (Pillow) rather than shipped as a binary
blob, so the repository contains no borrowed artwork and the design is editable as numbers:

```sh
python3 tools/make-icon.py
```

It renders a muted speaker — a "sound off" mark, which is what the app does — over a navy-to-blue
gradient, and writes all five sizes the asset catalog expects.

## Credits
- [airlift](https://github.com/0xjohnnydev/airlift) — Johnny Franks: the original PoC and the
  ATAirlock analysis
- [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS) — Mak5er: the loopback tunnel, the Rust FFI
  core, the pairing host and the Grappa tokens this is built on
- [idevice](https://github.com/jkcoxson/idevice) — the RSD/AFC/streaming_zip_conduit plumbing

MIT. See [LICENSE](LICENSE).
