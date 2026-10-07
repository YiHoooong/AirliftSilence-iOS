# AirliftSilence (iOS)

On-device switch for the iPhone call-recording announcement — no computer needed.

A minimal SwiftUI app built on the same AirTraffic sandbox escape as
[AirCard-iOS](https://github.com/Mak5er/AirCard-iOS). It talks to the phone's own internal
services over a `LocalDevVPN` loopback tunnel and swaps the two audio files iOS plays when call
recording starts and stops.

Three actions:

| Button | What it does |
|---|---|
| **去除提示音** | writes the bundled silent files over both announcement files |
| **检测** | reads both files back and reports 静音 / 原版 / 未知版本 |
| **恢复原版** | writes the bundled originals back |

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
- A pairing record. Either import one (AirDrop / Files → the app's Documents, named
  `airlift_pairing.plist`), or use the built-in on-device pairing:
  **开始配对** → note the PIN → Settings › Privacy & Security › Developer Mode › Pair with App.
- The official Apple Books app installed and opened at least once — `com.apple.atc` refuses the
  sync otherwise, which is the #1 cause of "ReadyForSync not observed".

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

Both files live in the same directory, so one write covers both:

```
/var/mobile/Library/CallServices/Greetings/default/StartDisclosureWithTone.m4a
/var/mobile/Library/CallServices/Greetings/default/StopDisclosure.caf
```

The bundled `Resources/silent` files are plain `ffmpeg anullsrc` silence, matched to the duration
and codec of the versions shipping today (AAC 1.672 s, Opus 1.920 s), so playback timing is
unchanged.

`Resources/original` holds Apple's current recordings so **恢复原版** has something to put back.
Those two files are Apple's audio, bundled for your own device only — don't redistribute this
repository with them if that matters to you.

## Known limits

- **Apple updates these files as a silent `MobileAsset` update** — no iOS version change, no
  notification. When that happens your silence is overwritten and the sound comes back. Reopen the
  app and press **去除提示音**. It has happened once so far; it is not a boot-time check, so
  rebooting is safe.
- A reboot does **not** undo it. Verified by byte-comparing both files before and after a restart.
- The announcement plays to **both parties** on the call. Removing it may be unlawful where
  recording requires all-party consent (Germany, several US states). Get consent before recording
  anyone — the law applies to you whatever your phone does or does not announce.

## Credits

- [airlift](https://github.com/0xjohnnydev/airlift) — Johnny Franks: the original PoC and the
  ATAirlock analysis
- [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS) — Mak5er: the loopback tunnel, the Rust FFI
  core, the pairing host and the Grappa tokens this is built on
- [idevice](https://github.com/jkcoxson/idevice) — the RSD/AFC/streaming_zip_conduit plumbing

MIT. See [LICENSE](LICENSE).
