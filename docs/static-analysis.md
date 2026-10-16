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

Measured on the test device (27.0.1), and the first thing to get straight is what *does* trigger it:

There are two ways it has been undone, and one of them needs no action from the user at all:

1. **Apple replaces the announcement.** The first time the test device lost its silence, the device
   owner had not touched anything: he checked after someone reported the same thing, and found the
   sound back. The file evidence matches — around that date the shipped audio changed shape
   (51326 → 46505 bytes for the m4a, PCM → Opus for the `.caf`) and the silence was overwritten by the
   new version. That is a TTS voice or content push, the same class of event as an iOS update, and it
   is why a revert can arrive with no warning.
2. **The user switches the system language.** Confirmed twice in a row on Oct 15: switching to English
   and back regenerated `StartDisclosureWithTone.m4a` once per switch. This is also what produced the
   revert the owner first blamed on the daemon rebuilding itself.

Timeline on the test device, from the copies kept during the work:

| when | what |
|---|---|
| Oct 4 | announcements silenced; originals backed up (51326 B m4a, PCM caf) |
| ~Oct 6 | **Apple's audio replaced the silent files** — silence gone without any user action |
| Oct 6 | re-silenced against the new originals (46505 B m4a, Opus caf), verified across a reboot |
| Oct 6 → 15 | silence held ~9 days, including test calls in which the daemon set up its players and played the silent files without rebuilding them |
| Oct 15 | language switched to check the English UI → regenerated → silence gone |
| Oct 16 | write-block experiment (failed, §3.2); silence restored and byte-verified |

Two things this rules out, both of which would have made the situation worse: there is **no periodic
rebuild** (nine days of calls and reboots would have caught it) and **no check on the file's contents**
(the daemon played files it had not produced, on call after call, and left them alone).

The MP4 timestamp inside `StartDisclosureWithTone.m4a` is a cheap "was this rebuilt?" fingerprint: a
rebuild produces the same audio with 18 differing bytes, all in the `mvhd` creation/modification
times. The two `.caf` files carry no timestamp, so a deterministic re-encode of them is byte-identical
and cannot be told apart from a copy.

Two more facts about the gate, both from testing it:

- **The gate is on generation, not playback.** With a perfectly valid silent file at the path, the
  daemon still refused to record when its own generation of the disclosure had failed. So anything that
  makes the *write* fail costs recording, even though a usable audio file is sitting right there.
- **A failed generation is queued and retried.** After the read-only test, `StartDisclosureWithTone.m4a`
  was rewritten within a minute of the path becoming writable again, while the two `.caf` files were
  left alone — the retry covers the file the current configuration actually plays. Blocking a write does
  not prevent the replacement; it postpones it.

The practical consequence is not "patch the daemon" but "notice and re-apply": the change is rare,
announced by the audio itself, and re-applying takes one tap (or one Shortcut).

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

### 3.1 Pinning the regeneration trigger — worth knowing, limited value

This was written when the silence looked like it was being undone by the daemon on its own. It is not:
the only confirmed trigger is a configuration change (see §1). That matters, because pinning can only
protect against a decision we can influence:

- A **language switch** changes the utterance the daemon wants, so it must regenerate the audio; there
  is no stored value that could talk it out of that. Pinning cannot help.
- An **Apple-side audio or voice push**, and an **iOS update**, are the same story — and this is the
  case that actually bit the test device (§1), with no user action involved. The expected disclosure
  legitimately becomes something else, so no stored value can keep the old silence in place.
- The one thing pinning *would* fix — a daemon that rebuilt the audio on its own with unchanged inputs
  — does not appear to exist.

The preference domain is still worth reading, because it is the only place the daemon's expectations
are visible at all:

```
/var/mobile/Library/Preferences/com.apple.telephonyutilities.callservicesd.plist
```

with keys such as `disclosureUtteranceChecksum`, `StartRecordingDisclosureUtterance`,
`StartRecordingBeepChecksum`, `greetingBeepChecksums` and `lastSiriVoiceUsedForCallScreeningGreeting`.
Diffing it across a language switch would show exactly what the daemon stores and what it compares —
useful if any future iOS version makes regeneration suppressible, and useful context for the issue
reports. It will not make the silence permanent.

### 3.2 Blocking the write physically — all three variants tested, all rejected

The idea: leave something at the announcement path that the daemon cannot write through. This section
is the complete record, because it is the obvious idea and it fails in three different ways.

**Variant 1 — an empty directory at the file path.** A directory cannot be replaced by an atomic rename
and cannot be opened for writing.

- The primitive works. `plant --kind dir` installs an empty directory, confirmed twice over: a second
  plant reported `previousSize: null`, and the copy the second plant moved aside reported
  `st_ifmt=S_IFDIR` over AFC. That same move-out also proves the tool can undo it.
- The daemon removed it and wrote a real file back. `StopDisclosure.caf` ended up byte-identical to the
  original, and `StartDisclosureWithTone.m4a` was regenerated twice across two language switches. The
  write path is **remove-then-write**, so an entry-level block only defeats in-place writes.
- Cost while blocked: **recording was unusable** in both languages until the daemon had repaired the
  file.

**Variant 2 — a read-only file (0444).** If the daemon overwrites in place, a read-only file should stop
it.

- The mode does reach the device: the archive's Unix mode field is honoured for files. Probed directly —
  writing to a 0444 file over AFC (as `afcd`, i.e. as mobile) is denied, while writing to a 0644 file in
  the same directory succeeds.
- It blocks the write, and that is all it blocks: the daemon **removes the entry and creates a new
  file**, which only needs write permission on the directory. Behaviour was identical to variant 1 —
  English call: no announcement and *no recording*; back in Chinese, recording worked again with the
  announcement, after the daemon had replaced the file.
- The retry queue from §1 then finished the job: the moment the path was writable again,
  `StartDisclosureWithTone.m4a` was rewritten within a minute while the two `.caf` files stayed silent.

**Variant 3 — a read-only *directory*, or an immutable file.** Both would be stronger than a file mode,
since unlinking needs write permission on the directory and `UF_IMMUTABLE` blocks unlink outright. Both
are unavailable through this channel, measured rather than assumed:

- Directory modes are **ignored** by the extractor: a file could still be created inside a directory the
  archive declared as 0555.
- Apple's `META-INF/com.apple.ZipMetadata.plist` does not carry them either: with `Records[]` entries
  asking for `Mode` (0555 on the directory) and `Flags` (`UF_IMMUTABLE` on a 0644 file), neither took —
  the directory stayed writable and the file stayed writable.
- The escape carries file modes, not directory modes or flags. That is the whole story of this section.

**So "block the write" is closed**, and it is worth being precise about why: it is not that the daemon
defends itself cleverly, it is that *any* failure to produce the disclosure disables recording
(§1) — so a block that holds is not a win either, it is a broken phone. "Valid silent audio" is the only
shape that keeps recording working, which is what this app does.

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

1. **Detect and re-apply, automatically.** This is now the headline answer rather than a fallback:
   one of the two known reverts needs no action from the user at all (§1), so waiting to notice it is
   the wrong model. The app's `Check` action already reports a reverted file on launch, and the
   Shortcuts actions added in v1.1.0 let a personal automation (daily, or on charge) re-apply the
   silence without anyone looking. Worth documenting as *the* supported answer, with the automation
   recipe written out.
2. `DisclosureWithTone.m4a` (3.3) — cheap to test, and a miss here is a live disclosure never silenced.
3. Does a TTS *voice* asset update really regenerate the announcements? Oct 6 says the shipped
   originals changed, but that was measured after the fact. A voice download in Settings would settle
   it with the timestamp fingerprint.
4. The preference diff in 3.1 and the beta 3 diff — both informational, neither changes what this app
   can do.

Closed, and not worth reopening:

- The physical write block (3.2) — all three variants tested and rejected, and every one of them breaks
  recording while it holds.
- Any hope of making the silence permanent against a configuration change. The daemon legitimately
  wants different audio after a language switch, a voice update or an iOS update, and it will get it:
  the file can be made read-only, but not the directory, and not unremovable.

That leaves "notice and re-apply" as the supported answer, which is what this app already does: `Check`
on launch reports a reverted file, and the Shortcut actions can re-apply it on a schedule.

## 6. A note for field debugging

Everything interesting in the device log is redacted: `startDisclosureFileExists <private>`. A
logging configuration profile with `EnablePrivateData` turns those into real paths and values.
Installing one is the fastest way to get a usable log out of a reporter whose device we do not have.
