#!/usr/bin/env python3
"""List the Rust libraries inside Velopack's programs, and write their licenses.

Velopack, which installs and updates Reqly for Windows, puts programs of its own beside Reqly:
Update.exe, the small Reqly.exe that starts the installed one, and Setup.exe. They're written in
Rust, so the Rust libraries they're built from, its crates, are inside them, each under its own
license. This finds which ones, from Velopack's Cargo.lock at the version Reqly uses, following only
what a Windows build of its programs uses, and writes their licenses to
tools/licenses/velopack-<version>-rust.txt, which tools/acknowledgements.py adds to Velopack's entry
in the app's list.

    python3 tools/velopack_crates.py           # lists the crates and their licenses
    python3 tools/velopack_crates.py --write   # also downloads the crates, for their license
                                               # texts, and writes the file

Run it again after updating Velopack. It reads Velopack's repository on GitHub and crates.io's API,
a request a second, as crates.io asks, and keeps what it read in --cache, so a second run is quick.
"""
import argparse
import io
import json
import os
import re
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NUGET_LOCK = os.path.join(ROOT, "windows", "Reqly", "packages.lock.json")
LICENSES = os.path.join(ROOT, "tools", "licenses")
AGENT = "Reqly acknowledgements (https://github.com/parsamlm/reqly)"
# Velopack's own crates, which its LICENSE covers, and the programs among them.
PROGRAMS = "velopack_bins"
# What a Windows build of Velopack's programs is, for its crates' cfg(...) conditions.
TARGET = {
    "target_os": "windows",
    "target_family": "windows",
    "target_env": "msvc",
    "target_arch": "x86_64",
    "target_vendor": "pc",
    "target_pointer_width": "64",
    "target_endian": "little",
    "panic": "unwind",
}
TARGET_NAMES = {"windows"}
TRIPLE = "x86_64-pc-windows-msvc"
LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE|UNLICENSE)([-_.].*)?$", re.IGNORECASE)


class Problem(Exception):
    pass


def velopack_version():
    with open(NUGET_LOCK, encoding="utf-8") as f:
        lock = json.load(f)
    for packages in lock["dependencies"].values():
        if "Velopack" in packages:
            return packages["Velopack"]["resolved"]
    raise Problem("windows/Reqly/packages.lock.json has no Velopack")


class Fetcher:
    """Reads URLs, a request a second for crates.io, keeping what it read in a folder."""

    def __init__(self, cache):
        self.cache = cache
        self.last = 0.0
        os.makedirs(cache, exist_ok=True)

    def get(self, url, binary=False):
        name = re.sub(r"[^A-Za-z0-9._-]+", "_", url)[-180:]
        path = os.path.join(self.cache, name)
        if os.path.exists(path):
            with open(path, "rb") as f:
                data = f.read()
        else:
            if "crates.io" in url:
                wait = 1.0 - (time.monotonic() - self.last)
                if wait > 0:
                    time.sleep(wait)
                self.last = time.monotonic()
            request = urllib.request.Request(url, headers={"User-Agent": AGENT})
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    data = response.read()
            except urllib.error.HTTPError as error:
                raise Problem(f"{url}: {error.code} {error.reason}")
            with open(path, "wb") as f:
                f.write(data)
        return data if binary else data.decode("utf-8")


# MARK: Velopack's crates and their dependencies


def lock_packages(text):
    """Cargo.lock's packages: (name, version) to their dependencies, as Cargo.lock writes them."""
    packages = {}
    for block in text.split("[[package]]")[1:]:
        name = re.search(r'^name = "([^"]+)"', block, re.M).group(1)
        version = re.search(r'^version = "([^"]+)"', block, re.M).group(1)
        source = re.search(r'^source = "([^"]+)"', block, re.M)
        dependencies = []
        listed = re.search(r"^dependencies = \[(.*?)\]", block, re.M | re.S)
        if listed:
            dependencies = re.findall(r'"([^"]+)"', listed.group(1))
        packages[(name, version)] = {"source": source.group(1) if source else None, "dependencies": dependencies}
    return packages


def member_dependencies(text):
    """A workspace crate's Cargo.toml dependencies: name, kind and target, the way crates.io lists them."""
    declared = []
    kind = None
    target = None
    for line in text.split("\n"):
        section = re.match(r"^\s*\[(.+)\]\s*$", line)
        if section:
            header = section.group(1).strip()
            found = re.match(r"^target\.(?:'([^']+)'|\"([^\"]+)\"|([^.]+))\.(dependencies|build-dependencies|dev-dependencies)$", header)
            if found:
                target = found.group(1) or found.group(2) or found.group(3)
                kind = found.group(4)
            elif header in ("dependencies", "build-dependencies", "dev-dependencies"):
                target = None
                kind = header
            else:
                kind = None
            continue
        if kind is None:
            continue
        name = re.match(r"^([A-Za-z0-9_\-]+)\s*(?:\.workspace\s*=|=)", line)
        if name:
            declared.append(
                {
                    "crate_id": name.group(1),
                    "kind": {"dependencies": "normal", "build-dependencies": "build", "dev-dependencies": "dev"}[kind],
                    "target": target,
                }
            )
    return declared


def applies(target):
    """Whether a dependency's target, such as cfg(windows) or a triple, is a Windows x64 build's."""
    if target is None:
        return True
    target = target.strip()
    if not target.startswith("cfg("):
        return target == TRIPLE
    return evaluate(target[4:-1].strip())


def evaluate(expression):
    expression = expression.strip()
    for operator in ("all", "any", "not"):
        if expression.startswith(operator + "(") and expression.endswith(")"):
            parts = split_arguments(expression[len(operator) + 1 : -1])
            values = [evaluate(part) for part in parts if part.strip()]
            if operator == "all":
                return all(values)
            if operator == "any":
                return any(values)
            return not values[0]
    pair = re.match(r'^([A-Za-z_]+)\s*=\s*"([^"]*)"$', expression)
    if pair:
        key, value = pair.groups()
        if key == "target_feature":
            return value in ("sse", "sse2", "fxsr")
        if key == "target_has_atomic":
            return value in ("8", "16", "32", "64", "ptr")
        return TARGET.get(key) == value
    return expression in TARGET_NAMES


def split_arguments(text):
    parts, depth, current = [], 0, ""
    for character in text:
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
        if character == "," and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += character
    parts.append(current)
    return parts


def is_macro(fetch, name, crate_version):
    """Whether a crate is a procedural macro, which runs as code is compiled and isn't inside a program."""
    data = fetch.get(f"https://static.crates.io/crates/{name}/{name}-{crate_version}.crate", binary=True)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        manifest = archive.extractfile(f"{name}-{crate_version}/Cargo.toml").read().decode("utf-8", "replace")
    library = re.search(r"^\[lib\]\s*$(.*?)(?=^\[|\Z)", manifest, re.M | re.S)
    return bool(library and re.search(r"^proc-macro\s*=\s*true\s*$", library.group(1), re.M))


def crates(fetch, version, leave_out_macros):
    """
    The crates a Windows build of Velopack's programs is made from, other than Velopack's own. With
    `leave_out_macros`, which needs the crates themselves, procedural macros, which run as code is
    compiled, and the crates only they use, are left out.
    """
    base = f"https://raw.githubusercontent.com/velopack/velopack/{version}"
    lock = lock_packages(fetch.get(f"{base}/Cargo.lock"))
    by_name = {}
    for name, crate_version in lock:
        by_name.setdefault(name, []).append(crate_version)
    members = {key: value for key, value in lock.items() if value["source"] is None}
    member_paths = {"velopack_bins": "src/bins", "velopack": "src/lib-rust", "velopack_l18n": "src/l18n"}

    def declarations(name, crate_version):
        if (name, crate_version) in members:
            if name not in member_paths:
                raise Problem(f"Velopack's {name} is a workspace crate this script doesn't know the folder of")
            return member_dependencies(fetch.get(f"{base}/{member_paths[name]}/Cargo.toml"))
        found = json.loads(fetch.get(f"https://crates.io/api/v1/crates/{name}/{crate_version}/dependencies"))
        return found["dependencies"]

    start = next(key for key in members if key[0] == PROGRAMS)
    seen = {start}
    waiting = [start]
    while waiting:
        name, crate_version = waiting.pop()
        declared = declarations(name, crate_version)
        for dependency in lock[(name, crate_version)]["dependencies"]:
            parts = dependency.split(" ")
            child = parts[0]
            child_version = parts[1] if len(parts) > 1 else by_name[child][0]
            uses = [d for d in declared if d["crate_id"] == child]
            # Normal dependencies for Windows only: build scripts' and tests' don't end up inside.
            if uses and not any(d["kind"] in (None, "normal") and applies(d.get("target")) for d in uses):
                continue
            key = (child, child_version)
            if key in seen or (leave_out_macros and key not in members and is_macro(fetch, *key)):
                continue
            seen.add(key)
            waiting.append(key)
    return sorted((key for key in seen if key not in members), key=lambda key: (key[0].lower(), key[1]))


# MARK: Their licenses


def details(fetch, name, crate_version):
    found = json.loads(fetch.get(f"https://crates.io/api/v1/crates/{name}/{crate_version}"))["version"]
    return {"license": (found.get("license") or "").strip(), "size": found.get("crate_size") or 0}


# Licenses that ask nothing of a program built with the code, so no text needs to go with it.
ASKS_NOTHING = ("0BSD", "Unlicense", "CC0-1.0", "MIT-0")


def chosen_license(expression):
    """
    The license to use a crate under, of those it offers: one that asks nothing, then Apache-2.0,
    whose text is the same for every crate, then MIT. With AND, every part applies.
    """
    if " AND " in expression:
        return expression
    alternatives = [part.strip().strip("()") for part in re.split(r"\s+OR\s+|/", expression)]
    for license in ASKS_NOTHING + ("Apache-2.0", "MIT"):
        if license in alternatives:
            return license
    return expression


def tidy(text):
    return "\n".join(line.rstrip() for line in text.replace("\r\n", "\n").strip("\n").split("\n"))


def license_files(fetch, name, crate_version):
    """
    The license and notice files in a crate as it was published, by name. A crate published without
    one gets its repository's, at the commit it was published from, which the crate records.
    """
    data = fetch.get(f"https://static.crates.io/crates/{name}/{name}-{crate_version}.crate", binary=True)
    files = {}
    vcs = None
    manifest = ""
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive.getmembers():
            parts = member.name.split("/")
            # Only at the crate's top level.
            if not member.isfile() or len(parts) != 2:
                continue
            if LICENSE_FILE.match(parts[1]):
                files[parts[1]] = tidy(archive.extractfile(member).read().decode("utf-8", "replace"))
            elif parts[1] == ".cargo_vcs_info.json":
                vcs = json.loads(archive.extractfile(member).read().decode("utf-8"))
            elif parts[1] == "Cargo.toml":
                manifest = archive.extractfile(member).read().decode("utf-8", "replace")
    if files or not vcs:
        return files
    repository = re.search(r'^repository = "https://github\.com/([^/"]+/[^/"]+?)/?"', manifest, re.M)
    commit = vcs.get("git", {}).get("sha1")
    if not repository or not commit:
        return files
    folder = vcs.get("path_in_vcs", "").strip("/")
    for place in ([folder] if folder else []) + [""]:
        for candidate in ("LICENSE-MIT", "LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING"):
            path = f"{place}/{candidate}" if place else candidate
            try:
                text = fetch.get(f"https://raw.githubusercontent.com/{repository.group(1)}/{commit}/{path}")
            except Problem:
                continue
            files[f"{candidate} (from {repository.group(1)} at {commit[:12]}, as the crate has none)"] = tidy(text)
            return files
    return files


def pick_texts(files, chosen):
    """
    The files that hold the chosen license, such as LICENSE-MIT; for AND, or when it can't tell,
    all the crate's license files but Apache's, which the one shared copy covers.
    """
    plain = [key for key in sorted(files) if not key.upper().startswith("NOTICE")]
    if " AND " not in chosen:
        wanted = {"Apache-2.0": "APACHE", "MIT": "MIT"}.get(chosen)
        if wanted:
            matching = [key for key in plain if wanted in key.upper()]
            if matching:
                return matching[:1]
        if len(plain) == 1:
            return plain
    return [key for key in plain if "APACHE" not in key.upper()] or plain


def write(fetch, version, found, path):
    by_license = {}
    texts = {}
    notices = []
    missing = []
    apache = None
    for name, crate_version, expression in found:
        chosen = chosen_license(expression)
        by_license.setdefault(chosen, []).append(f"{name} {crate_version}")
        files = license_files(fetch, name, crate_version)
        for notice in (key for key in files if key.upper().startswith("NOTICE")):
            notices.append((f"{name} {crate_version}", files[notice]))
        if apache is None:
            apache = next((files[key] for key in sorted(files) if "Version 2.0, January 2004" in files[key]
                           and "APACHE" in key.upper()), None)
        if chosen == "Apache-2.0" or chosen in ASKS_NOTHING:
            # Apache's text is the same for every crate, so one copy does for all.
            continue
        keys = pick_texts(files, chosen)
        if not keys:
            missing.append(f"{name} {crate_version} ({expression})")
            continue
        for key in keys:
            texts.setdefault(files[key], []).append(f"{name} {crate_version}")
    if missing:
        raise Problem("These crates have no license file to copy; check them by hand: " + ", ".join(missing))
    out = [
        "Velopack's programs beside Reqly, Update.exe, Setup.exe and the Reqly.exe that starts it, are",
        f"built with these Rust libraries, from Velopack {version}'s Cargo.lock, as a Windows build can",
        "use them, leaving out macros, which run as the programs are compiled; and with Rust's standard",
        "library, under the MIT License or the Apache License 2.0, as is rustc-demangle, which it brings.",
        "The list keeps libraries that Velopack's optional features would bring, so a few of them may not",
        "be inside. Each crate is listed under the license it's used under, of those it offers.",
        "",
    ]
    for chosen in sorted(by_license, key=lambda key: (key != "Apache-2.0", key)):
        names = by_license[chosen]
        under = "the Apache License 2.0" if chosen == "Apache-2.0" else chosen
        out += [f"Under {under}:", "  " + ", ".join(names), ""]
    for text, names in texts.items():
        out += ["-" * 72, f"{', '.join(names)}:", "", text, ""]
    for crate, text in notices:
        out += ["-" * 72, f"{crate}'s NOTICE:", "", text, ""]
    if apache:
        out += ["-" * 72, "The Apache License 2.0:", "", apache, ""]
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out).rstrip("\n") + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--write", action="store_true", help="download the crates and write the licenses file")
    parser.add_argument("--cache", default=os.path.join(tempfile.gettempdir(), "reqly-velopack-crates"),
                        help="where to keep what it reads (default: a folder in the system's temporary folder)")
    arguments = parser.parse_args()
    fetch = Fetcher(arguments.cache)
    try:
        version = velopack_version()
        found = []
        size = 0
        for name, crate_version in crates(fetch, version, leave_out_macros=arguments.write):
            info = details(fetch, name, crate_version)
            found.append((name, crate_version, info["license"]))
            size += info["size"]
        for name, crate_version, expression in found:
            print(f"{name:32} {crate_version:12} {expression}")
        print(f"\n{len(found)} crates in Velopack {version}'s programs for Windows; the crates come to {size / 1e6:.1f} MB.")
        if arguments.write:
            path = os.path.join(LICENSES, f"velopack-{version}-rust.txt")
            write(fetch, version, found, path)
            print(f"Wrote {os.path.relpath(path, ROOT)}.")
    except (Problem, OSError, KeyError) as error:
        sys.exit(f"error: {error}")


if __name__ == "__main__":
    main()
