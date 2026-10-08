#!/usr/bin/env python3
"""Collect the licenses of the open-source code inside Reqly.app.

Help ▸ Reqly Help ▸ Open Source Licenses shows them. The texts come from the packages SwiftPM
has checked out for ReqlyKit, from the ones Xcode has checked out for the app alone, such as
Sparkle, and from the copy of QuickJS-ng in core/Sources/CQuickJS. So build Reqly in Xcode once,
and resolve ReqlyKit's packages:

    swift package resolve --package-path core
    python3 tools/acknowledgements.py

Writes mac/Reqly/Resources/Acknowledgements.json. Run it again after adding, removing or updating a
dependency. It stops when it meets a package, a license or a ReqlyKit target with C code that it
doesn't know, so that a person checks what the new code asks for. `--check` only says whether the
file is up to date.

Some license texts aren't in the checkouts, so copies from their projects are kept in
tools/licenses. When one is missing, for example after a package moves to a newer copy of
BoringSSL, the script says where to get it.
"""
import argparse
import glob
import collections
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT = os.path.join(ROOT, "mac", "Reqly", "Resources", "Acknowledgements.json")
RESOLVED = os.path.join(ROOT, "core", "Package.resolved")
APP_RESOLVED = os.path.join(
    ROOT, "mac", "Reqly.xcodeproj", "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved"
)
QUICKJS = os.path.join(ROOT, "core", "Sources", "CQuickJS")
# ReqlyKit's targets with C code. Code copied from another project usually comes as C, so a target
# that isn't listed here stops the script until someone checks where its code comes from.
C_TARGETS = {
    "CQuickJS": "QuickJS-ng, which quickjs() covers",
    "CZlib": "only a module map for the zlib the system provides",
}
# License texts the checkouts don't carry. A copy saved here is added to its package.
EXTRA_TEXTS = os.path.join(ROOT, "tools", "licenses")
# The files in EXTRA_TEXTS that some package needs, so that left-over ones can be pointed out.
needed_texts = set()

APACHE = "Apache License 2.0"
APACHE_RLE = "Apache License 2.0 with Runtime Library Exception"
MIT = "MIT License"

# Code that a package copied from another project, under that project's license. The notice is
# the whole file, or the lines from the one matching `start` to the next one matching `end`.
LLHTTP = {"title": "llhttp", "file": "Sources/CNIOLLHTTP/LICENSE"}
MUSL = {
    "title": "Time calculations from musl",
    "file": "Sources/X509/X509BaseTypes/TimeCalculations.swift",
    "start": r"Rich Felker",
    "end": r"OTHER DEALINGS IN THE SOFTWARE\.$",
}
RAILS = {
    "title": "Inflection rules from Ruby on Rails",
    "file": "GRDB/Utils/Inflections+English.swift",
    "start": r"David Heinemeier Hansson",
    "end": r"OTHER DEALINGS IN THE SOFTWARE\.$",
}
UNICODE = {
    "title": "Unicode data",
    "file": "quickjs-amalgam.c",
    "start": r"^UNICODE LICENSE V3$",
    "end": r"authorization of the copyright holder\.$",
}
ATOMICS = {
    "title": "QuickJS C atomics definitions",
    "file": "quickjs-amalgam.c",
    "start": r"^Copyright \(c\) \d{4} Marcin Kolny$",
    "end": r"^THE SOFTWARE\.$",
}

# Every package in Package.resolved: its license, the files that hold its license and notices,
# and the code it copied from elsewhere. Swift System is resolved for SwiftNIO but not linked;
# it's listed anyway.
PACKAGES = {
    "grdb.swift": {"license": MIT, "files": ["LICENSE"], "copied": [RAILS]},
    "swift-asn1": {"license": APACHE, "files": ["LICENSE.txt", "NOTICE.txt"]},
    "swift-atomics": {"license": APACHE_RLE, "files": ["LICENSE.txt"]},
    "swift-certificates": {"license": APACHE, "files": ["LICENSE.txt", "NOTICE.txt"], "copied": [MUSL]},
    "swift-collections": {"license": APACHE_RLE, "files": ["LICENSE.txt"]},
    "swift-crypto": {
        "license": APACHE,
        "files": ["LICENSE.txt", "NOTICE.txt"],
        "boringssl": "Sources/CCryptoBoringSSL",
    },
    "swift-nio": {
        "license": APACHE,
        "files": ["LICENSE.txt", "NOTICE.txt"],
        "copied": [LLHTTP],
        "missing": [
            {
                "title": "cpp_magic.h from uSHET",
                "why": "NOTICE.txt credits cpp_magic.h, in CNIOAtomics, to uSHET under the MIT License, but"
                " neither the checkout nor cpp_magic.h has that license's text.",
                "file": "uSHET-cpp_magic.txt",
                "source": "the uSHET Library part of"
                " https://github.com/18sg/uSHET/blob/c09e0acafd86720efe42dc15c63e0cc228244c32/LICENSE",
            }
        ],
    },
    "swift-nio-http2": {"license": APACHE, "files": ["LICENSE.txt", "NOTICE.txt"]},
    "swift-nio-ssl": {
        "license": APACHE,
        "files": ["LICENSE.txt", "NOTICE.txt"],
        "boringssl": "Sources/CNIOBoringSSL",
    },
    "swift-system": {"license": APACHE_RLE, "files": ["LICENSE.txt"]},
    # Only the app uses Sparkle. Its LICENSE also holds the licenses of the code it includes from
    # other projects, such as bsdiff and sais-lite.
    "sparkle": {"license": MIT, "files": ["LICENSE"]},
}

# The licenses BoringSSL's files carry: how each one's notice starts and ends.
BORINGSSL_LICENSES = {
    "isc": (r"Permission to use, copy, modify, and/or distribute", r"PERFORMANCE OF THIS SOFTWARE\."),
    "openssl": (r"Licensed under the OpenSSL license", r"license\.html"),
    "apache": (r"Licensed under the Apache License, Version 2\.0", r"limitations under the License\."),
}
BORINGSSL_INTRODUCTIONS = {
    "isc": "Files written for BoringSSL have these copyright notices and the ISC license:",
    "openssl": "Files that come from OpenSSL have these copyright notices and the OpenSSL license:",
    "apache": "Its files have these copyright notices, under the Apache License 2.0 in LICENSE.txt:",
}
SOURCE_EXTENSIONS = (".c", ".cc", ".cpp", ".h", ".inc", ".S")


class Problem(Exception):
    pass


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def tidy(text):
    """The text without trailing spaces, or blank lines at either end."""
    lines = [line.rstrip() for line in text.replace("\r\n", "\n").split("\n")]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines)


def uncomment(line):
    """A line of source code without its comment markers."""
    line = re.sub(r"^\s*(/\*+|\*/|\*|//+|#|;|@)? ?", "", line)
    return re.sub(r"\s*\*/\s*$", "", line).rstrip()


def cut(text, start, end, origin):
    """The lines of `text` from the one matching `start` to the next one matching `end`, uncommented."""
    lines = [uncomment(line) for line in text.split("\n")]
    first = next((i for i, line in enumerate(lines) if re.search(start, line)), None)
    if first is None:
        raise Problem(f"{origin} has no line matching {start!r}. Check what it copies now.")
    last = next((i for i in range(first, len(lines)) if re.search(end, lines[i])), None)
    if last is None:
        raise Problem(f"{origin} has no line matching {end!r} after {start!r}. Check what it copies now.")
    return tidy("\n".join(lines[first : last + 1]))


def copied(folder, part):
    path = os.path.join(folder, part["file"])
    if "start" not in part:
        return {"title": part["title"], "text": tidy(read(path))}
    return {"title": part["title"], "text": cut(read(path), part["start"], part["end"], path)}


def check_license(name, license, text):
    apache = "Apache License" in text and "Version 2.0, January 2004" in text
    exception = "Runtime Library Exception" in text
    mit = "Permission is hereby granted, free of charge" in text
    expected = {APACHE: apache and not exception, APACHE_RLE: apache and exception, MIT: mit}
    if not expected[license]:
        raise Problem(f"{name}'s license is no longer the {license}. Check it, then update PACKAGES.")


def extra_text(name, missing, warnings):
    """A license text the checkouts don't carry, if someone saved a copy in tools/licenses."""
    needed_texts.add(missing["file"])
    path = os.path.join(EXTRA_TEXTS, missing["file"])
    if os.path.exists(path):
        return {"title": missing["title"], "text": tidy(read(path))}
    warnings.append(
        f"{name}: {missing['why']} To add it, save it as {os.path.relpath(path, ROOT)}, from {missing['source']}"
    )
    return None


def boringssl(name, folder, warnings):
    """What a package's copy of BoringSSL needs: who holds its files, and the licenses they gave."""
    match = re.search(r"at revision ([0-9a-f]{40})", read(os.path.join(folder, "hash.txt")))
    if not match:
        raise Problem(f"{folder}/hash.txt doesn't say which BoringSSL revision it holds")
    revision = match.group(1)

    holders = {kind: collections.Counter() for kind in BORINGSSL_LICENSES}
    notices = {kind: {} for kind in BORINGSSL_LICENSES}
    for directory, subdirectories, files in os.walk(folder):
        subdirectories.sort()
        for filename in sorted(files):
            if not filename.endswith(SOURCE_EXTENSIONS):
                continue
            path = os.path.join(directory, filename)
            with open(path, encoding="utf-8", errors="replace") as f:
                head = f.read(6000)
            if re.search(r"(SwiftNIO|SwiftCrypto) project authors", head):
                continue  # The package's own files.
            lines = [uncomment(line) for line in head.split("\n")]
            flat = " ".join(" ".join(lines).split())
            kinds = [kind for kind, (start, _) in BORINGSSL_LICENSES.items() if re.search(start, flat)]
            copyrights = [line for line in lines if line.startswith("Copyright")]
            if len(kinds) != 1:
                if kinds or copyrights:
                    raise Problem(f"{path} has a license this script doesn't know. Check it.")
                continue  # Generated, or in the public domain.
            kind = kinds[0]
            holders[kind].update(copyrights)
            notice = cut(head, *BORINGSSL_LICENSES[kind], path)
            # Assembly files wrap the same words differently, so compare the words alone.
            notices[kind].setdefault(" ".join(notice.split()), notice)

    sections = [f"{name} includes BoringSSL (https://boringssl.googlesource.com/boringssl) at revision {revision}."]
    for kind, introduction in BORINGSSL_INTRODUCTIONS.items():
        if not holders[kind]:
            continue
        if len(notices[kind]) != 1:
            raise Problem(f"{folder}: the files under the {kind} license word it differently. Check them.")
        sections.append(introduction)
        sections.append("\n".join(by_holder(holders[kind])))
        if kind != "apache":
            sections.append(next(iter(notices[kind].values())))
    has_fiat = os.path.isdir(os.path.join(folder, "third_party", "fiat"))
    if has_fiat:
        sections.append(
            "It also includes code from the fiat-crypto project (https://github.com/mit-plv/fiat-crypto),"
            " in third_party/fiat."
        )

    result = [{"title": "BoringSSL", "text": "\n\n".join(sections)}]
    missing = []
    if holders["openssl"]:
        missing.append(
            {
                "title": "BoringSSL's LICENSE",
                "why": "The BoringSSL files that come from OpenSSL point to BoringSSL's LICENSE for the OpenSSL"
                " license, and the checkout has no copy of it.",
                "file": f"boringssl-{revision}-LICENSE.txt",
                "source": f"https://boringssl.googlesource.com/boringssl/+/{revision}/LICENSE",
            }
        )
    if has_fiat:
        missing.append(
            {
                "title": "fiat-crypto's LICENSE",
                "why": "BoringSSL's fiat-crypto code has no license text in the checkout.",
                "file": f"boringssl-{revision}-fiat-LICENSE.txt",
                "source": f"https://boringssl.googlesource.com/boringssl/+/{revision}/third_party/fiat/LICENSE",
            }
        )
    for part in missing:
        text = extra_text(name, part, warnings)
        if text:
            result.append(text)
    return result


def by_holder(copyrights):
    """Copyright lines, the holder with the most files first, and each holder's years in order."""
    files = collections.Counter()
    for line, count in copyrights.items():
        files[holder(line)] += count
    return sorted(copyrights, key=lambda line: (-files[holder(line)], holder(line), line))


def holder(line):
    return " ".join(re.sub(r"[\d,-]+", " ", line).split()).lower()


def pins(path):
    with open(path, encoding="utf-8") as f:
        return {pin["identity"]: pin for pin in json.load(f)["pins"]}


def package(identity, pin, checkouts, warnings):
    if identity not in PACKAGES:
        raise Problem(
            f"Package.resolved has {identity}, which this script doesn't know. Check its license and"
            " the code it copies from other projects, then add it to PACKAGES."
        )
    spec = PACKAGES[identity]
    url = re.sub(r"\.git$", "", pin["location"])
    name = url.rstrip("/").split("/")[-1]
    folder = os.path.join(checkouts, name)
    if not os.path.isdir(folder):
        raise Problem(f"There's no checkout of {name} in {checkouts}. Resolve the packages first.")
    head = subprocess.run(
        ["git", "-C", folder, "rev-parse", "HEAD"], capture_output=True, text=True, check=True
    ).stdout.strip()
    if head != pin["state"]["revision"]:
        raise Problem(f"The checkout of {name} isn't the revision Package.resolved pins. Resolve the packages again.")

    notices = [{"title": filename, "text": tidy(read(os.path.join(folder, filename)))} for filename in spec["files"]]
    check_license(name, spec["license"], notices[0]["text"])
    notices += [copied(folder, part) for part in spec.get("copied", [])]
    if "boringssl" in spec:
        notices += boringssl(name, os.path.join(folder, spec["boringssl"]), warnings)
    for part in spec.get("missing", []):
        text = extra_text(name, part, warnings)
        if text:
            notices.append(text)
    version = pin["state"].get("version") or pin["state"]["revision"][:12]
    return {"name": name, "version": version, "url": url, "license": spec["license"], "notices": notices}


def newest_xcode_checkouts():
    """The newest checkouts Xcode made for Reqly, which hold the packages only the app uses."""
    folders = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/Reqly-*/SourcePackages/checkouts"))
    return max(folders, key=os.path.getmtime) if folders else ""


def check_c_targets():
    """Stops at a ReqlyKit target that has C code or a license file but isn't in C_TARGETS."""
    sources = os.path.dirname(QUICKJS)
    for target in sorted(os.listdir(sources)):
        if target in C_TARGETS or not os.path.isdir(os.path.join(sources, target)):
            continue
        for _, _, files in os.walk(os.path.join(sources, target)):
            for filename in files:
                if filename.endswith((".c", ".cc", ".cpp", ".h", ".m", ".mm", ".S")) or re.match(
                    r"(LICENSE|COPYING|NOTICE)", filename, re.I
                ):
                    raise Problem(
                        f"core/Sources/{target} has {filename}, which may come from another project. Check"
                        " its license, then add the target to C_TARGETS."
                    )


def quickjs():
    """QuickJS-ng, which ReqlyKit carries in CQuickJS rather than as a package."""
    header = read(os.path.join(QUICKJS, "include", "quickjs.h"))
    parts = [re.search(rf"#define QJS_VERSION_{part} (\d+)", header) for part in ("MAJOR", "MINOR", "PATCH")]
    if not all(parts):
        raise Problem("CQuickJS/include/quickjs.h doesn't say which version it is")
    license = tidy(read(os.path.join(QUICKJS, "LICENSE")))
    check_license("QuickJS-ng", MIT, license)
    return {
        "name": "QuickJS-ng",
        "version": ".".join(part.group(1) for part in parts),
        "url": "https://github.com/quickjs-ng/quickjs",
        "license": MIT,
        "notices": [{"title": "LICENSE", "text": license}] + [copied(QUICKJS, part) for part in (UNICODE, ATOMICS)],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument(
        "--checkouts",
        default=os.path.join(ROOT, "core", ".build", "checkouts"),
        help="where SwiftPM checked the packages out (default: core/.build/checkouts)",
    )
    parser.add_argument(
        "--app-checkouts",
        default=newest_xcode_checkouts(),
        help="where Xcode checked out the packages only the app uses, such as Sparkle"
        " (default: the newest Reqly folder in Xcode's DerivedData)",
    )
    parser.add_argument("--check", action="store_true", help="only check that the file is up to date")
    arguments = parser.parse_args()

    warnings = []
    try:
        resolved = pins(RESOLVED)
        # The app resolves ReqlyKit's packages, at the same versions, and the ones it alone uses.
        app_resolved = pins(APP_RESOLVED)
        if any(app_resolved.get(key, {}).get("state") != pin["state"] for key, pin in resolved.items()):
            raise Problem("ReqlyKit and the Xcode project resolve different packages. Resolve both again.")
        check_c_targets()
        packages = [
            package(identity, pin, arguments.checkouts if identity in resolved else arguments.app_checkouts, warnings)
            for identity, pin in app_resolved.items()
        ]
        packages.append(quickjs())
    except (Problem, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: {error}")
    packages.sort(key=lambda package: package["name"].lower())
    output = json.dumps({"packages": packages}, indent=2, ensure_ascii=False) + "\n"
    if os.path.isdir(EXTRA_TEXTS):
        for filename in sorted(set(os.listdir(EXTRA_TEXTS)) - needed_texts):
            if not filename.startswith("."):
                warnings.append(f"No package needs tools/licenses/{filename} anymore, so it can go.")

    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    relative = os.path.relpath(OUTPUT, ROOT)
    current = read(OUTPUT) if os.path.exists(OUTPUT) else None
    if arguments.check:
        if current != output:
            sys.exit(f"error: {relative} is out of date. Run tools/acknowledgements.py.")
        print(f"{relative} is up to date.")
    elif current != output:
        with open(OUTPUT, "w", encoding="utf-8") as f:
            f.write(output)
        print(f"Wrote {relative}, with {len(packages)} packages.")
    else:
        print(f"{relative} was already up to date.")


if __name__ == "__main__":
    main()
