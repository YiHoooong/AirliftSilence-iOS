#!/usr/bin/env python3
"""Check the app's localisation files against the Swift sources.

There is no String Catalog here: the `.strings` files are hand-written and the
keys are the English strings as they appear in the code. That is easy to get
wrong the moment a literal is edited, so this script verifies:

  1. every `.strings` file parses (comments terminated, `"key" = "value";` only);
  2. every key really exists in the sources, once `\\(..)` interpolations are
     normalised to `%@`;
  3. en.lproj and zh-Hans.lproj carry the same keys, in the same order;
  4. InfoPlist.strings only overrides keys that exist in Info.plist;
  5. reports source strings that look like UI text but have no translation.

Run it from the repository root:  python3 tools/check-strings.py
Exit status is 1 when a check fails; the report in (5) is informational.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IOS = os.path.join(ROOT, "ios-app")
LANGS = ["en", "zh-Hans"]

# Strings that are deliberately not localised: identifiers, SF Symbols, file
# names, service types, and App Shortcut phrases (Siri matches those literally
# so both languages need their own phrase in the source).
IGNORED = {
    "silenceDeviceIP", "airliftsilence", "airlift_pairing.plist", "iPhone",
    "Mac17,7", "mobiledevicepairing", "mobilepairing", "plist",
    "_airliftsilence._tcp", "_remotepairing-pairable-host._tcp.",
    "%02x", "silence_", "10.7.0.1", "12.0", "8.0", "3.0", "5.0",
    "\u2717 ", "\u2705 ",  # log-line prefixes; the text after them is localised
    "checkmark.circle.fill", "checkmark.seal.fill", "exclamationmark.triangle",
    "exclamationmark.triangle.fill", "questionmark.circle", "person.badge.key",
    "magnifyingglass", "speaker.slash.fill", "arrow.uturn.backward",
    "square.and.arrow.down", "square.and.arrow.up", "text.alignleft",
    "waveform.badge.magnifyingglass", "title3.weight", "B",
    # App Shortcut phrases.
    "%@ 检查通话录音提示音", "%@ 去掉通话录音提示音", "%@ 恢复通话录音提示音",
    "Check the call-recording announcement in %@",
    "Silence the call-recording announcement with %@",
    "Restore the call-recording announcement with %@",
}


def strip_comments(src):
    """Remove // and /* */ comments, leaving string literals alone."""
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == '"':
            out.append(c)
            i += 1
            while i < n:
                out.append(src[i])
                if src[i] == "\\":
                    if i + 1 < n:
                        out.append(src[i + 1])
                        i += 2
                        continue
                elif src[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def normalise(literal):
    """Turn `a \\(x) b` into `a %@ b`, matching what the compiler keys on."""
    out = []
    i = 0
    while i < len(literal):
        if literal.startswith("\\(", i):
            depth = 0
            j = i + 1
            while j < len(literal):
                if literal[j] == "(":
                    depth += 1
                elif literal[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            out.append("%@")
            i = j + 1
        else:
            out.append(literal[i])
            i += 1
    return "".join(out)


def source_keys():
    keys = set()
    for name in sorted(os.listdir(IOS)):
        if not name.endswith(".swift"):
            continue
        with open(os.path.join(IOS, name), encoding="utf-8") as handle:
            src = strip_comments(handle.read())
        for match in re.finditer(r'"((?:[^"\\]|\\.)*)"', src):
            if match.start() > 0 and src[match.start() - 1] == "\\":
                continue
            keys.add(normalise(match.group(1)))
    return keys


def parse_strings(path):
    """Return [(key, value)] and raise on anything that is not valid syntax."""
    if not os.path.exists(path):
        raise SystemExit("missing %s" % path)
    entries = []
    in_comment = False
    with open(path, encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            stripped = line.strip()
            if in_comment:
                if "*/" in stripped:
                    in_comment = False
                continue
            if not stripped:
                continue
            if stripped.startswith("//"):
                continue
            if stripped.startswith("/*"):
                if "*/" not in stripped:
                    in_comment = True
                continue
            match = re.match(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";$', stripped)
            if not match:
                raise SystemExit("%s:%d: not a `\"key\" = \"value\";` line: %s"
                                 % (path, lineno, stripped))
            entries.append((match.group(1), match.group(2)))
    if in_comment:
        raise SystemExit("%s: unterminated /* comment" % path)
    return entries


def main():
    problems = []
    keys = source_keys()

    tables = {}
    for lang in LANGS:
        path = os.path.join(IOS, "%s.lproj" % lang, "Localizable.strings")
        tables[lang] = parse_strings(path)

    reference = None
    for lang, entries in tables.items():
        seen = [key for key, _ in entries]
        duplicates = {k for k in seen if seen.count(k) > 1}
        if duplicates:
            problems.append("%s: duplicate keys %s" % (lang, sorted(duplicates)))
        missing = [k for k in seen if k not in keys]
        if missing:
            problems.append("%s: keys that are not in the sources:\n    %s"
                            % (lang, "\n    ".join(missing)))
        if len(seen) != len(keys) - len(IGNORED):
            pass  # informational only, see the report below
        for key, value in entries:
            specifiers = len(re.findall(r"%@", key))
            if len(re.findall(r"%@", value)) != specifiers:
                problems.append('%s: "%s" has %d placeholders but the translation has %d'
                                % (lang, key, specifiers, len(re.findall(r"%@", value))))
        if reference is None:
            reference = seen
        elif seen != reference:
            problems.append("%s: key set or order differs from en.lproj" % lang)

    for lang in LANGS:
        path = os.path.join(IOS, "%s.lproj" % lang, "InfoPlist.strings")
        plist = open(os.path.join(IOS, "Info.plist"), encoding="utf-8").read()
        for key, _ in parse_strings(path):
            if "<key>%s</key>" % key not in plist:
                problems.append("%s: InfoPlist.strings overrides %s, which Info.plist does not define"
                                % (lang, key))

    translated = {key for entries in tables.values() for key, _ in entries}
    untranslated = sorted(
        key for key in keys - translated - IGNORED
        if " " in key and re.match(r"^[A-Za-z\u2600-\u27bf]", key)
    )

    if problems:
        print("FAIL")
        for problem in problems:
            print("  - %s" % problem)
        return 1

    print("OK  %d keys, %s" % (len(reference), ", ".join(
        "%s=%d" % (lang, len(tables[lang])) for lang in LANGS)))
    print("    sources: %d string literals" % len(keys))
    if untranslated:
        print("    %d source string(s) look like UI text but have no entry:" % len(untranslated))
        for key in untranslated:
            print("      %s" % key)
    return 0


if __name__ == "__main__":
    sys.exit(main())
