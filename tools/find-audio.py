#!/usr/bin/env python3
"""Find out what audio the device played, from a captured syslog.

The greetings directory cannot be listed through the exploit, so the way to
learn which file produces a given sound is to watch the device load it. This
filters a `pymobiledevice3 syslog live` capture down to audio-related lines and
prints them in time order.

    python3 tools/find-audio.py /tmp/call.log

    # narrow to a window around the sound (seconds since the first log line)
    python3 tools/find-audio.py /tmp/call.log --around 240

Notes
-----
* A line only proves the device *mentioned* a path. Playback itself is usually
  logged by whichever daemon owns the sound, so the interesting lines are the
  ones naming a file under CallServices or an audio API call.
* System sounds come from /System/Library/Audio/UISounds, which lives on the
  sealed system volume — those cannot be replaced by this exploit.
"""

from __future__ import annotations

import argparse
import re
import sys
from datetime import datetime, timedelta

# Anything that suggests audio being loaded or played.
PATTERNS = [
    re.compile(r"[\w/.\-]+\.(?:caf|m4a|aiff?|wav|mp3|opus)\b", re.IGNORECASE),
    re.compile(r"AudioServicesPlay\w*", re.IGNORECASE),
    re.compile(r"AVAudioPlayer|AVAudioSession|AudioToolbox|AudioQueue", re.IGNORECASE),
    re.compile(r"CallServices|Greetings|UISounds", re.IGNORECASE),
    re.compile(r"\bplay\w*\s+(?:sound|tone|audio|greeting)", re.IGNORECASE),
]

TIMESTAMP = re.compile(
    r"^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)"
)

# Kick noise: these fire constantly and drown out the real hits.
IGNORE = re.compile(
    r"hotspot|wifi|awdl|bluetooth|apsd|wifid|nesessionmanager|"
    r"CoreAnalytics|Biome|DuetExpert|powerlog",
    re.IGNORECASE,
)


def parse_time(line: str) -> datetime | None:
    m = TIMESTAMP.match(line)
    if not m:
        return None
    raw = m.group(1).replace("T", " ")
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(raw, fmt)
        except ValueError:
            continue
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("logfile")
    ap.add_argument("--around", type=float, metavar="SECONDS",
                    help="only show lines within ±60s of this offset from the first line")
    ap.add_argument("--limit", type=int, default=400, help="max lines to print")
    ap.add_argument("--all", action="store_true", help="do not drop chatty subsystems")
    args = ap.parse_args()

    try:
        handle = open(args.logfile, encoding="utf-8", errors="replace")
    except OSError as exc:
        print(f"cannot read {args.logfile}: {exc}", file=sys.stderr)
        return 1

    start: datetime | None = None
    hits: list[tuple[datetime | None, str]] = []
    total = 0

    with handle:
        for line in handle:
            total += 1
            if not args.all and IGNORE.search(line):
                continue
            if not any(p.search(line) for p in PATTERNS):
                continue
            stamp = parse_time(line)
            if stamp and start is None:
                start = stamp
            if args.around is not None and stamp and start:
                delta = (stamp - start).total_seconds()
                if abs(delta - args.around) > 60:
                    continue
            hits.append((stamp, line.rstrip("\n")))

    print(f"# scanned {total} lines, {len(hits)} audio-related\n")
    if not hits:
        print("No audio mentions at all. Either the sound is generated without touching a")
        print("file the system logs, or the capture missed the moment — try --all.")
        return 0

    # Files are the actionable thing, so summarise them first.
    files: dict[str, int] = {}
    for _, line in hits:
        for path in PATTERNS[0].findall(line):
            files[path] = files.get(path, 0) + 1
    if files:
        print("## Audio files mentioned (most frequent first)")
        for path, count in sorted(files.items(), key=lambda kv: -kv[1])[:40]:
            tag = ""
            lower = path.lower()
            if "callservices" in lower or "greetings" in lower:
                tag = "  <- under CallServices, replaceable"
            elif "/system/library/audio/uisounds" in lower:
                tag = "  <- UISounds, NOT replaceable (sealed system volume)"
            print(f"  {count:>5}x  {path}{tag}")
        print()

    print("## Timeline")
    for stamp, line in hits[: args.limit]:
        if stamp and start:
            off = (stamp - start).total_seconds()
            print(f"  +{off:8.1f}s  {line}")
        else:
            print(f"  {'':>9}s  {line}")
    if len(hits) > args.limit:
        print(f"\n  … {len(hits) - args.limit} more (raise --limit)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
