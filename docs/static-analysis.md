# What blocks this, and what can still be bypassed

Static analysis of iOS 27.0.1 (`iPhone18,3`, build `24A446`) with the aim of answering two
questions: which protections can this app still get around, and which ones stop it for good.

Sources: the extracted OS volume and dyld shared cache from the matched IPSW, `callservicesd` (the
daemon that owns the announcements), its embedded entitlements, launchd job definitions, the
TelephonyUtilities feature-flag domain, and syslog captured from the device during recorded calls.

Nothing below was tested on a device unless it says so. Items marked **experiment** are static
conclusions that need a test to become facts.

---

## 1. How the announcement is actually produced

This changes what "it came back" means, so it comes first.

The three files this app replaces are **generated on the device by Siri TTS**, not downloaded:

- `callservicesd` carries the log line
  `Generating disclosure for %s %s because disclosureUtteranceChecksum:%s fileExists:%s force: %s`.
- Its entitlements allow exactly two asset types —
  `com.apple.MobileAsset.phoneNumberResolver` and `com.apple.MobileAsset.UAF.Siri.TextToSpeech` — and
  the latter is a *voice*. The announcement itself is not an asset.
- The generation path is visible in the binary: `SiriTTSService.framework`,
  `callservicesd.SiriSpeechSynthesizer`, `AVSpeechSynthesizerDelegate`,
  `com.apple.private.speechtranslationclient`, `com.apple.sirittsd.can-dump-audio`, plus a
  `disclosureTable` / `disclosureUtilities` / `languageManager` / `ttsService` object graph.
- The device log during a recorded call shows the playback side:
  `startDisclosureFileExists <private>`, `Asked to begin playing call recording start disclosure`,
  `Beep finished playing! Notifying system that start disclosure is over`,
  `Scheduing recurring disclosure for <private> seconds from now with randomness <private>`.
- The three filenames appear in the binary as **bare names** — `StartDisclosure.caf`,
  `StartDisclosureWithTone.m4a`, `StopDisclosure.caf` — so the directory is assembled at runtime from
  the `CallServices` / `Greetings` / `default` components. That is precisely why replacing them works:
  the audio is expected to live in a writable user directory.

**Consequence.** The announcement coming back (issue #3) is not a "silent MobileAsset update" of the
audio. It is the TTS voice or the disclosure configuration changing, which changes
`disclosureUtteranceChecksum`, which makes the daemon regenerate the audio — overwriting what this app
wrote. It can therefore happen again on a system update, on a language change, or when Apple ships a
new voice. **Experiment:** switch the device language and see whether the announcement returns.

## 2. The privilege boundary, measured rather than guessed

Every process in the write path runs as **mobile**:

| Job | Program | UserName |
|---|---|---|
| `com.apple.atc` | `/usr/libexec/atc` | mobile |
| `com.apple.streaming_zip_conduit` | (XPC service) | mobile |
| `com.apple.afcd` | `/usr/libexec/afcd` | mobile |
| `com.apple.telephonyutilities.callservicesd` | `…/TelephonyUtilities.framework/callservicesd` | mobile |
| `com.apple.bookassetd` | `…/BookLibraryCore.framework/Support/bookassetd` | mobile, `RunAtLoad=false` |
| `com.apple.mobileassetd` | `/usr/libexec/mobileassetd` | *no UserName — runs as root* |

So the escape gives an **arbitrary file write with mobile's privileges**, anywhere reachable by a
relative symlink out of `Media`: all of `/var/mobile/**` is in play, and `/System/**`, `/var/root/**`,
`/var/db/**` and `/private/var/MobileAsset/**` are not. That single sentence explains both halves of
this document.

Two useful details fall out of it:

- `callservicesd` is `ProcessType=Adaptive` with `EnablePressuredExit=true`: it exits when idle and
  re-reads its preferences on the next invocation. A preference change therefore applies without
  needing root to restart anything.
- `bookassetd` / `bookdatastored` are on-demand XPC services, which is the static counterpart of the
  documented requirement that Apple Books be installed and opened once: the conduit works only after
  the Books data store has been initialised. The host cannot fake that — it is device-side state.

## 3. What is still bypassable

### 3.1 Pinning the regeneration trigger — the most promising lever

`callservicesd` runs as mobile, so its preference domain is

```
/var/mobile/Library/Preferences/com.apple.telephonyutilities.callservicesd.plist
```

and the binary contains a cluster of keys that look exactly like that store:

```
StartRecordingDisclosureUtterance   EndRecordingDisclosureUtterance   StartRecordingBeepChecksum
disclosureUtteranceChecksum         disclosureBeepChecksum            endDisclosureUtteranceChecksum
greetingBeepChecksums               lastSiriVoiceUsedForCallScreeningGreeting
CALL_RECORDING_START_DISCLOSURE     CALL_RECORDING_END_DISCLOSURE
```

The regeneration predicate is one of these values. If it tracks the *configuration* (voice id,
locale, utterance text) rather than the bytes on disk — which the long lifetime of the current silence
suggests — then writing back the value the daemon expects to see makes the predicate false and the
audio is never regenerated. The read primitive this project already has reaches that plist.

**Experiment, in this order:**

1. Read the plist (target dir `/var/mobile/Library/Preferences`, leaf
   `com.apple.telephonyutilities.callservicesd.plist`) and keep a copy.
2. Wait for the announcement to return — or force it with a language change — and read it again.
3. Diff. The key that moved is the trigger.
4. Write that key back to the "already generated" state together with the silent files, then repeat
   the trigger and see whether the silence holds.

Caveats: `cfprefsd` caches preferences, so a write behind its back may be overwritten; the daemon
exiting on idle (or a reboot) is what makes the change take effect.

### 3.2 Making the file impossible to overwrite

Rather than fighting the trigger, block the write. The play path and the generate path are the same
path, so replace each announcement with a **relative symlink to a read-only target** (the escape
already relies on relative symlinks to leave `Media`): playback follows the link and plays silence,
while regeneration writes through it into a read-only file and fails, leaving the silence in place.

**Experiment:** does the ATC install move a symlink as a symlink, or follow it? If it renames the
item, the link lands at the destination intact.

Weaker variant: the sync archive can carry Unix mode bits in its ZIP `external_attr`; whether the
installer honours them is unknown.

**Do not** simply delete or corrupt these files. `fileExists=false` sends the daemon down its
regeneration branch, and call recording is a legal-notice feature: a device that cannot play the
disclosure may refuse to record at all. "Valid silent audio" or "readable but unwritable" are the only
safe shapes.

### 3.3 Coverage that may still have a hole

- `DisclosureWithTone.m4a` appears in the binary as a bare filename, separate from
  `StartDisclosureWithTone.m4a` and sitting next to push-to-talk strings
  (`CSDPTTTransmissionReportKey`). It is probably the PTT or live-translation disclosure rather than
  the call-recording one, but it lives somewhere writable and is not covered here. **Experiment:**
  run a call with live translation (or PTT) and listen.

## 4. What is blocked for good

- **The recurring twinkle.** `recurringDisclosureTwinkle.caf` is referenced by a hardcoded absolute
  path — `/System/Library/PrivateFrameworks/TelephonyUtilities.framework/recurringDisclosureTwinkle.caf`
  — with no search order and no writable fallback. It sits on the sealed system volume, owned by root,
  and is verified at boot. A mobile-privileged file write cannot reach it; only a jailbreak, an SSV
  bypass or a root exploit changes that. `BEEP.caf` in the same framework is the answering-machine /
  call-screening beep, not a recording one.
- **The TTS voice store.** `/private/var/MobileAsset/` is managed by `mobileassetd` (root);
  `callservicesd` is granted *read-only* access to it by entitlement. Poisoning the voice to make the
  disclosure synthesise as silence is not available to us — and would be a device-wide side effect.
- **No kill switch exists to find.** `System/Library/FeatureFlags/Domain/TelephonyUtilities.plist`
  lists `CallRecording`, `iPadCallRecording`, `macCallRecording`, `visionCallRecording` and
  `SimultaneousTranslationDisclosure` with nothing but `DevelopmentPhase: FeatureComplete`. The
  `DisclosureRequired` values in that file are App Review UUIDs, not runtime switches. There is no
  supported flag that disables the recurring disclosure.
- **Apple's fix in iOS 27.2 beta 3.** Confirmed by its own release: the escape is patched there. What
  we cannot say from this side is *how much* was patched: without the beta 3 binaries there is no way
  to tell whether Apple tightened one path check or closed the whole class of operations. Pulling that
  cryptex (≈2.2 GB) and diffing `AirTrafficDevice` / `ATFoundation` is the next step if we want to
  know whether another unchecked operation survives.
- **Grappa.** The device requires the token; we generate it per session and fall back to ten
  pre-generated ones. If Apple ever makes tokens device-bound, the whole write path stops at once.
  That is the single largest long-term risk in this project.

## 5. Where to look next, in order

1. The preference diff in 3.1 — it is the only lever that addresses "the announcement came back".
2. Whether the installer preserves symlinks (3.2), which would make regeneration physically fail.
3. `DisclosureWithTone.m4a` (3.3) — cheap to test, and a miss here is a live disclosure we never
   silenced.
4. Beta 3 diff, only if support for 27.2 beta 3+ is wanted.

## 6. A note for field debugging

Everything interesting in the device log is redacted: `startDisclosureFileExists <private>`. A
logging configuration profile with `EnablePrivateData` turns those into real paths and values.
Installing one is the fastest way to get a usable log out of a reporter whose device we do not have.
