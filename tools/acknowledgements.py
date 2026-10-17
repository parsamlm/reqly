#!/usr/bin/env python3
"""Collect the licenses of the open-source code inside Reqly.app and Reqly for Windows.

On the Mac, Help ▸ Reqly Help ▸ Open Source Licenses shows them, and on Windows, Help › About
Reqly › Open-source licenses. The texts come from the packages SwiftPM has checked out for
ReqlyKit, from the ones Xcode has checked out for the Mac app alone, such as Sparkle, from the
copy of QuickJS-ng in core/Sources/CQuickJS, and for Windows, from the C code it alone carries:
zlib, Brotli's decoder, SQLite and BoringSSL's assembly for Windows, and from copies of the
licenses of the NuGet packages and runtimes that come with it. So build Reqly in Xcode once, and
resolve ReqlyKit's packages:

    swift package resolve --package-path core
    python3 tools/acknowledgements.py

Writes mac/Reqly/Resources/Acknowledgements.json and windows/Reqly/Assets/Acknowledgements.json;
`--app mac` or `--app windows` writes one. Run it again after adding, removing or updating a
dependency. It stops when it meets a package, a license or a ReqlyKit target with C code that it
doesn't know, so that a person checks what the new code asks for. `--check` only says whether the
files are up to date.

The Windows app's NuGet packages come from windows/Reqly/packages.lock.json. Microsoft's own, the
Windows App SDK with WinUI, carry Microsoft's license terms rather than an open-source license, so
the list leaves them out, and Reqly asks you to agree to those terms the first time it opens. Its
installer also puts Swift's runtime and .NET beside Reqly.exe: RUNTIMES says which versions, and
windows/scripts/package.ps1 checks that the installer carries those.

Some license texts aren't in the checkouts, so copies from their projects are kept in
tools/licenses. The licenses of the Rust libraries in Velopack's programs come from
tools/velopack_crates.py, which writes them there for the Velopack version Reqly uses. When one is missing, for example after a package moves to a newer copy of
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
WINDOWS_OUTPUT = os.path.join(ROOT, "windows", "Reqly", "Assets", "Acknowledgements.json")
# The Windows app's core resolves the same packages as ReqlyKit, at the same versions.
WINDOWS_RESOLVED = os.path.join(ROOT, "windows", "ReqlyCore", "Package.resolved")
NUGET_LOCK = os.path.join(ROOT, "windows", "Reqly", "packages.lock.json")
ZLIB = os.path.join(ROOT, "core", "Sources", "CZlibBundled")
BROTLI = os.path.join(ROOT, "core", "Sources", "CBrotliBundled")
SQLITE = os.path.join(ROOT, "windows", "third-party", "sqlite")
BORINGSSL_ASM = os.path.join(ROOT, "windows", "third-party", "boringssl-asm")
# The packages Reqly for Windows builds with changes, one folder of patches each.
PATCHES = os.path.join(ROOT, "windows", "patches")
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
    # Built only on Windows and Linux, so Reqly.app doesn't carry them.
    "CZlibBundled": "zlib's source, for Windows, which has no zlib of its own",
    "CBrotliBundled": "Brotli's decoder, for Windows and Linux; the Mac uses its Compression framework",
}
# License texts the checkouts don't carry. A copy saved here is added to its package.
EXTRA_TEXTS = os.path.join(ROOT, "tools", "licenses")
# The files in EXTRA_TEXTS that some package needs, so that left-over ones can be pointed out.
needed_texts = set()

APACHE = "Apache License 2.0"
APACHE_RLE = "Apache License 2.0 with Runtime Library Exception"
MIT = "MIT License"
BSD = "BSD 3-Clause License"
UNICODE_V3 = "Unicode License V3"

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

# The NuGet packages the Windows app builds with whose files go beside Reqly under an open-source
# license. Their license texts aren't in the repository's checkouts, so copies are kept in
# tools/licenses, named after the package and its version.
NUGET_LISTED = {
    # WinUI brings WebView2: Microsoft.Web.WebView2.Core.dll, its projection and WebView2Loader.dll.
    "Microsoft.Web.WebView2": {
        "name": "WebView2",
        "url": "https://aka.ms/webview",
        "license": BSD,
        "files": ["LICENSE.txt", "NOTICE.txt"],
    },
    # Velopack.dll, and the programs vpk puts beside Reqly to install it and its updates: Update.exe,
    # Setup.exe and the Reqly.exe that starts it, written in Rust, with the Rust libraries in them.
    "Velopack": {
        "name": "Velopack",
        "url": "https://velopack.io",
        "license": MIT,
        "files": ["LICENSE"],
        # The package carries no copy of its license, but the project's repository does.
        "source": "https://github.com/velopack/velopack/blob/{version}/LICENSE",
        "extra": [
            {
                "title": "The Rust libraries in its programs",
                "file": "velopack-{version}-rust.txt",
                "why": "Velopack's programs are built with Rust libraries, whose licenses that file has.",
                "source": "tools/velopack_crates.py --write, which writes it",
            }
        ],
    },
}
# The ones left out, and why.
NUGET_LEFT_OUT = {
    "Microsoft.WindowsAppSDK.Base": "used only to build",
    "Microsoft.WindowsAppSDK.Foundation": "Microsoft's license terms for the Windows App SDK",
    "Microsoft.WindowsAppSDK.InteractiveExperiences": "Microsoft's license terms for the Windows App SDK",
    "Microsoft.WindowsAppSDK.WinUI": "Microsoft's license terms for the Windows App SDK",
    "Microsoft.Windows.SDK.BuildTools": "used only to build",
    "Microsoft.Windows.SDK.BuildTools.MSIX": "used only to build",
}

# The runtimes that Reqly for Windows' installer puts beside Reqly.exe, at the versions that
# windows/scripts/package.ps1 checks it carries. Swift's Foundation carries ICU in _FoundationICU.dll,
# and libxml2 in FoundationXML.dll: at the Swift release's tag, swift-foundation-icu's
# icuSources/include/_foundation_unicode/uvernum.h and swift's utils/build.ps1 say which versions.
DOTNET = "10.0.12"
SWIFT = "6.4.0"
ICU = "76.1"
LIBXML2 = "2.11.5"
# Each runtime's license and notices, saved in tools/licenses, and where they come from.
RUNTIMES = [
    {
        "name": ".NET",
        "version": DOTNET,
        "url": "https://dot.net",
        "license": MIT,
        "texts": [
            {
                "title": title,
                "file": f"microsoft.netcore.app.runtime.win-x64-{DOTNET}-{title}",
                "source": f"%USERPROFILE%\\.nuget\\packages\\microsoft.netcore.app.runtime.win-x64\\{DOTNET}\\{title}"
                " on a PC that packaged Reqly",
            }
            for title in ("LICENSE.TXT", "THIRD-PARTY-NOTICES.TXT")
        ],
    },
    {
        "name": "Swift",
        "version": SWIFT,
        "url": "https://www.swift.org",
        "license": APACHE_RLE,
        "about": (
            "Swift's runtime",
            "Reqly for Windows carries Swift's runtime, from the Swift project: the standard library, from"
            " swift and swift-experimental-string-processing, Dispatch, from swift-corelibs-libdispatch, and"
            " Foundation, from swift-corelibs-foundation, swift-foundation and swift-foundation-icu. Each is"
            " under the license in LICENSE.txt. Foundation also carries ICU and libxml2, which this list has"
            " on their own.",
        ),
        "texts": [
            {
                "title": "LICENSE.txt",
                "file": f"swift-{SWIFT}-LICENSE.txt",
                "source": f"https://github.com/swiftlang/swift/blob/swift-{SWIFT}-RELEASE/LICENSE.txt",
            },
            {
                "title": "swift-foundation's NOTICE.txt",
                "file": f"swift-foundation-{SWIFT}-NOTICE.txt",
                "source": f"https://github.com/swiftlang/swift-foundation/blob/swift-{SWIFT}-RELEASE/NOTICE.txt",
            },
        ],
    },
    {
        "name": "ICU",
        "version": ICU,
        "url": "https://icu.unicode.org",
        "license": UNICODE_V3,
        "texts": [
            {
                "title": "LICENSE",
                "file": f"icu-{ICU}-LICENSE.txt",
                "source": f"https://github.com/unicode-org/icu/blob/release-{ICU.replace('.', '-')}/LICENSE",
            }
        ],
    },
    {
        "name": "libxml2",
        "version": LIBXML2,
        "url": "https://gitlab.gnome.org/GNOME/libxml2",
        "license": MIT,
        # Copyright names hash.c and list.c, which have notices of their own. Its trio files aren't built.
        "texts": [
            {
                "title": "Copyright",
                "file": f"libxml2-{LIBXML2}-Copyright.txt",
                "source": f"https://gitlab.gnome.org/GNOME/libxml2/-/blob/v{LIBXML2}/Copyright",
            }
        ]
        + [
            {
                "title": name,
                "file": f"libxml2-{LIBXML2}-{name}.txt",
                "source": f"the comment at the top of https://gitlab.gnome.org/GNOME/libxml2/-/blob/v{LIBXML2}/{name}",
            }
            for name in ("hash.c", "list.c")
        ],
    },
]

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
    # Some copies space their words differently.
    flat = " ".join(text.split())
    apache = "Apache License" in text and "Version 2.0, January 2004" in text
    exception = "Runtime Library Exception" in text
    mit = "Permission is hereby granted, free of charge" in flat
    bsd = "Redistribution and use in source and binary forms, with or without modification" in flat and (
        "endorse or promote products derived from this software" in flat
    )
    unicode = "UNICODE LICENSE V3" in text
    expected = {
        APACHE: apache and not exception,
        APACHE_RLE: apache and exception,
        MIT: mit,
        BSD: bsd,
        UNICODE_V3: unicode,
    }
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


def zlib():
    """zlib, which the core carries in CZlibBundled for Windows, the one system without its own."""
    match = re.search(r'#define ZLIB_VERSION "([^"]+)"', read(os.path.join(ZLIB, "include", "zlib.h")))
    if not match:
        raise Problem("CZlibBundled/include/zlib.h doesn't say which version it is")
    license = tidy(read(os.path.join(ZLIB, "LICENSE")))
    if "Permission is granted to anyone to use this software for any purpose" not in license:
        raise Problem("zlib's license is no longer the zlib License. Check it, then update zlib().")
    return {
        "name": "zlib",
        "version": match.group(1),
        "url": "https://zlib.net",
        "license": "zlib License",
        "notices": [{"title": "LICENSE", "text": license}],
    }


def brotli():
    """Brotli's decoder, which the core carries in CBrotliBundled for Windows and Linux."""
    header = read(os.path.join(BROTLI, "common", "version.h"))
    parts = [re.search(rf"#define BROTLI_VERSION_{part} (\d+)", header) for part in ("MAJOR", "MINOR", "PATCH")]
    if not all(parts):
        raise Problem("CBrotliBundled/common/version.h doesn't say which version it is")
    license = tidy(read(os.path.join(BROTLI, "LICENSE")))
    check_license("Brotli", MIT, license)
    return {
        "name": "Brotli",
        "version": ".".join(part.group(1) for part in parts),
        "url": "https://github.com/google/brotli",
        "license": MIT,
        "notices": [{"title": "LICENSE", "text": license}],
    }


def sqlite():
    """SQLite, which Reqly for Windows carries, since Windows has none to build against."""
    header = read(os.path.join(SQLITE, "sqlite3.h"))
    match = re.search(r'#define SQLITE_VERSION\s+"([^"]+)"', header)
    if not match:
        raise Problem("windows/third-party/sqlite/sqlite3.h doesn't say which version it is")
    # In place of a license, SQLite's files carry a blessing, in comments that start with **.
    lines = [re.sub(r"^\*\*\s?", "", line).rstrip() for line in header.split("\n")]
    first = next((i for i, line in enumerate(lines) if line.startswith("The author disclaims copyright")), None)
    last = next((i for i, line in enumerate(lines) if "never taking more than you give." in line), None)
    if first is None or last is None or last < first:
        raise Problem("windows/third-party/sqlite/sqlite3.h no longer puts SQLite in the public domain. Check it.")
    return {
        "name": "SQLite",
        "version": match.group(1),
        "url": "https://sqlite.org",
        "license": "Public domain",
        "notices": [{"title": "sqlite3.h", "text": tidy("\n".join(lines[first : last + 1]))}],
    }


def windows_boringssl(nio_ssl):
    """Says that on Windows, BoringSSL's assembly comes from windows/third-party, at NIOSSL's revision."""
    revision = read(os.path.join(BORINGSSL_ASM, "REVISION")).strip()
    notice = next(notice for notice in nio_ssl["notices"] if notice["title"] == "BoringSSL")
    if f"at revision {revision}." not in notice["text"]:
        raise Problem(
            f"windows/third-party/boringssl-asm is BoringSSL at {revision}, but NIOSSL's copy isn't. Update"
            " the assembly to NIOSSL's revision, as its README says."
        )
    notice["text"] += (
        "\n\nOn Windows, Reqly also builds BoringSSL's x86-64 assembly for Windows, from the same revision,"
        " which it keeps in windows/third-party/boringssl-asm."
    )


def windows_patches(packages):
    """Says which packages Reqly for Windows builds with changes, as their license asks: windows/patches has them."""
    resolved = pins(RESOLVED)
    for name in sorted(os.listdir(PATCHES)):
        if not os.path.isdir(os.path.join(PATCHES, name)):
            continue
        package = next((package for package in packages if package["name"] == name), None)
        if package is None:
            raise Problem(f"windows/patches/{name} changes a package that Reqly for Windows doesn't have.")
        # The patches are for one version: the one ReqlyKit pins, so that Windows builds it too.
        version, revision, _ = read(os.path.join(PATCHES, name, "VERSION")).split()
        if resolved[name]["state"]["revision"] != revision:
            raise Problem(
                f"windows/patches/{name} is for {name} {version}, but ReqlyKit pins"
                f" {resolved[name]['state'].get('version')}. Update the patches, as windows/patches/README.md says."
            )
        package["notices"].append(
            {
                "title": "Changes for Windows",
                "text": f"On Windows, Reqly builds {name} with changes for Windows that its releases don't have"
                " yet: fixes from open pull requests, and Reqly's own. They're in Reqly's repository, in"
                f" windows/patches/{name}, each saying where it comes from.",
            }
        )


def nuget_packages(warnings):
    """The Windows app's NuGet packages whose files go beside Reqly under an open-source license."""
    with open(NUGET_LOCK, encoding="utf-8") as f:
        lock = json.load(f)
    versions = {}
    for packages in lock["dependencies"].values():
        for identity, info in packages.items():
            if info.get("type") != "Project":
                versions[identity] = info["resolved"]
    listed = []
    for identity, version in sorted(versions.items()):
        if identity in NUGET_LEFT_OUT:
            continue
        if identity not in NUGET_LISTED:
            raise Problem(
                f"windows/Reqly/packages.lock.json has {identity}, which this script doesn't know. Check its"
                " license and which of its files go beside Reqly, then add it to NUGET_LISTED or NUGET_LEFT_OUT."
            )
        spec = NUGET_LISTED[identity]
        notices = []
        for filename in spec["files"]:
            text = extra_text(
                identity,
                {
                    "title": filename,
                    "why": f"The repository has no copy of {filename} from the {identity} {version} package.",
                    "file": f"{identity.lower()}-{version}-{filename}",
                    "source": spec["source"].format(version=version)
                    if "source" in spec
                    else f"%USERPROFILE%\\.nuget\\packages\\{identity.lower()}\\{version}\\{filename} on a PC that"
                    f" built Reqly, or the package at https://www.nuget.org/packages/{identity}/{version}",
                },
                warnings,
            )
            if text:
                notices.append(text)
        for extra in spec.get("extra", []):
            text = extra_text(identity, {**extra, "file": extra["file"].format(version=version)}, warnings)
            if text:
                notices.append(text)
        if notices and notices[0]["title"] == spec["files"][0]:
            check_license(spec["name"], spec["license"], notices[0]["text"])
        listed.append(
            {"name": spec["name"], "version": version, "url": spec["url"], "license": spec["license"], "notices": notices}
        )
    return listed


def runtimes(warnings):
    """The runtimes that Reqly for Windows' installer puts beside it: .NET, and Swift's, with ICU and libxml2."""
    listed = []
    for spec in RUNTIMES:
        notices = [{"title": spec["about"][0], "text": spec["about"][1]}] if "about" in spec else []
        texts = [
            extra_text(
                spec["name"],
                {
                    "title": text["title"],
                    "why": f"The repository has no copy of {text['title']} from {spec['name']} {spec['version']}.",
                    "file": text["file"],
                    "source": text["source"],
                },
                warnings,
            )
            for text in spec["texts"]
        ]
        # The first text is the license.
        if texts[0]:
            check_license(spec["name"], spec["license"], texts[0]["text"])
        notices += [text for text in texts if text]
        listed.append(
            {
                "name": spec["name"],
                "version": spec["version"],
                "url": spec["url"],
                "license": spec["license"],
                "notices": notices,
            }
        )
    return listed


def mac_list(arguments, warnings):
    """The open-source code inside Reqly.app."""
    resolved = pins(RESOLVED)
    # The app resolves ReqlyKit's packages, at the same versions, and the ones it alone uses.
    app_resolved = pins(APP_RESOLVED)
    if any(app_resolved.get(key, {}).get("state") != pin["state"] for key, pin in resolved.items()):
        raise Problem("ReqlyKit and the Xcode project resolve different packages. Resolve both again.")
    packages = [
        package(identity, pin, arguments.checkouts if identity in resolved else arguments.app_checkouts, warnings)
        for identity, pin in app_resolved.items()
    ]
    packages.append(quickjs())
    return packages


def windows_list(arguments, warnings):
    """The open-source code inside Reqly for Windows: ReqlyKit's, the C code Windows alone needs, its NuGet
    packages', and the runtimes it carries."""
    resolved = pins(RESOLVED)
    windows_resolved = pins(WINDOWS_RESOLVED)
    if {key: pin["state"] for key, pin in windows_resolved.items()} != {key: pin["state"] for key, pin in resolved.items()}:
        raise Problem("ReqlyKit and windows/ReqlyCore resolve different packages. Resolve both again.")
    packages = [package(identity, pin, arguments.checkouts, warnings) for identity, pin in windows_resolved.items()]
    windows_boringssl(next(package for package in packages if package["name"] == "swift-nio-ssl"))
    windows_patches(packages)
    packages += [quickjs(), zlib(), brotli(), sqlite()]
    packages += nuget_packages(warnings)
    packages += runtimes(warnings)
    return packages


def write(path, packages, checking):
    """Writes the list, or with `checking`, says whether the file already has it. True if it's up to date."""
    packages.sort(key=lambda package: package["name"].lower())
    output = json.dumps({"packages": packages}, indent=2, ensure_ascii=False) + "\n"
    relative = os.path.relpath(path, ROOT)
    current = read(path) if os.path.exists(path) else None
    if checking:
        if current != output:
            print(f"error: {relative} is out of date. Run tools/acknowledgements.py.", file=sys.stderr)
            return False
        print(f"{relative} is up to date.")
    elif current != output:
        with open(path, "w", encoding="utf-8") as f:
            f.write(output)
        print(f"Wrote {relative}, with {len(packages)} packages.")
    else:
        print(f"{relative} was already up to date.")
    return True


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
    parser.add_argument(
        "--app", choices=["mac", "windows", "both"], default="both", help="which app's list to write (default: both)"
    )
    parser.add_argument("--check", action="store_true", help="only check that the files are up to date")
    arguments = parser.parse_args()

    warnings = []
    lists = []
    try:
        check_c_targets()
        if arguments.app in ("mac", "both"):
            lists.append((OUTPUT, mac_list(arguments, warnings)))
        if arguments.app in ("windows", "both"):
            lists.append((WINDOWS_OUTPUT, windows_list(arguments, warnings)))
    except (Problem, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: {error}")
    # Only with both lists is it clear that no package needs a text.
    if arguments.app == "both" and os.path.isdir(EXTRA_TEXTS):
        for filename in sorted(set(os.listdir(EXTRA_TEXTS)) - needed_texts):
            if not filename.startswith("."):
                warnings.append(f"No package needs tools/licenses/{filename} anymore, so it can go.")

    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    if not all([write(path, packages, arguments.check) for path, packages in lists]):
        sys.exit(1)


if __name__ == "__main__":
    main()
