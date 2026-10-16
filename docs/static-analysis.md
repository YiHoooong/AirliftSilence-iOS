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
audio. It is the daemon regenerating its own audio and overwriting what this app wrote.

Measured on the test device (27.0.1):

- **A language switch regenerates immediately and reliably.** Switching to English and back
  regenerated `StartDisclosureWithTone.m4a` twice, once per switch. This is now an on-demand trigger
  for every experiment below, instead of waiting for Apple to ship something.
- **The daemon also regenerates on its own, without any configuration change.** Overnight the three
  files went from the silent versions back to audible ones while nothing was touched. The tell is
  `StartDisclosureWithTone.m4a`: 18 bytes differ from the previous copy, all inside the MP4 `mvhd`
  atom's creation/modification timestamps, while the audio payload is byte-identical. Same inputs,
  new encode — so nothing about the voice or the wording changed. That points at a periodic integrity
  re-check (the plausible candidate is an iOS maintenance window), which also explains why a daytime
  reboot does *not* bring the sound back.

  The MP4 timestamp is useful on its own: it is a cheap "was this regenerated?" fingerprint. The two
  `.caf` files carry no timestamp, so a deterministic re-encode of them is byte-identical and cannot
  be told apart from a copy.

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

The regeneration predicate is one of these values. What the overnight regeneration says about it is
important: the audio came back *without any configuration change*, so the daemon was not reacting to a
new voice or new wording. The remaining explanations are a mismatch between the file on disk and the
value the daemon expects, or a periodic forced rebuild. Those two have very different consequences —
the first is pinnable, the second is not — and the plan below tells them apart.

If it is a mismatch check, the fix is to make the stored value agree with the silent file that is
actually there (rather than the other way round). The read primitive this project already has reaches
that plist; the language switch gives an on-demand trigger to diff it.

**Experiment, in this order:**

1. Read the plist (target dir `/var/mobile/Library/Preferences`, leaf
   `com.apple.telephonyutilities.callservicesd.plist`) and keep a copy.
2. Wait for the announcement to return — or force it with a language change — and read it again.
3. Diff. The key that moved is the trigger.
4. Write that key back to the "already generated" state together with the silent files, then repeat
   the trigger and see whether the silence holds.

Caveats: `cfprefsd` caches preferences, so a write behind its back may be overwritten; the daemon
exiting on idle (or a reboot) is what makes the change take effect.

### 3.2 Blocking the write physically — tested, rejected

The idea: leave something at the announcement path that the daemon cannot write through. An empty
directory is the strongest shape — it cannot be replaced by an atomic rename (renaming a file over a
directory fails) and cannot be opened for writing.

**Tested on the device, and it does not work.**

- The primitive itself is sound. `airlift.py plant --kind dir` installs an empty directory at the
  path, confirmed two independent ways: a second plant reported `previousSize: null` (the entry could
  not be read as a file, because it was a directory), and the copy that the second plant moved aside
  reported `st_ifmt=S_IFDIR` over AFC. That same move-out also proves the tool can **undo** the whole
  thing, which is what makes this reversible.
- The daemon then removed it and wrote a real file back. `StopDisclosure.caf` ended up byte-identical
  to the original, and `StartDisclosureWithTone.m4a` was regenerated twice across the two language
  switches. The write path is therefore **remove-then-write**, not an atomic replace, and a directory
  only defeats the latter.
- The real cost is the side effect: **while the directory was in place, recording was unusable.** The
  first attempts in both languages failed to start a recording; it worked again — announcement and all
  — once the daemon had repaired the file. That is the legal-notice gate, and it means blocking this
  write costs *recording*, not just the announcement.

So this route needs the containing directory itself to be unwritable, which is a `chmod` — root, not a
file-level trick. Meanwhile "valid silent audio" stays the only shape that keeps recording working.

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
   With the language switch as a trigger, the loop is: silence, read the plist, switch language and
   switch back, read again, diff. The key that moved is the predicate.
2. Whether pinning holds across a *spontaneous* regeneration. Put the silent files back, patch the key
   from step 1 if it exists, then leave the device alone for a night: the MP4 timestamp in
   `StartDisclosureWithTone.m4a` says whether it was rebuilt. A pinned device that survives the night
   is the only version of "permanent" that is actually reachable.
3. `DisclosureWithTone.m4a` (3.3) — cheap to test, and a miss here is a live disclosure we never
   silenced.
4. Beta 3 diff, only if support for 27.2 beta 3+ is wanted.

Note what is *not* on this list any more: the physical write block (3.2) is closed, and so is the idea
of pointing the path at a read-only target, for the same reason.

## 6. A note for field debugging

Everything interesting in the device log is redacted: `startDisclosureFileExists <private>`. A
logging configuration profile with `EnablePrivateData` turns those into real paths and values.
Installing one is the fastest way to get a usable log out of a reporter whose device we do not have.
