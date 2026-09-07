#!/usr/bin/env python3
"""Detect what smart-screenshot's config.json can be pre-filled with, from the project itself.

Usage:
  detect_project.py [--root DIR] [--json]            # print what was found (human or JSON)
  detect_project.py [--root DIR] --write CONFIG      # fill the EMPTY values of CONFIG in place
  detect_project.py [--root DIR] --write CONFIG --force   # overwrite even non-empty values

What it looks for (build directories, node_modules, .git, DerivedData are skipped):
  android.package / android.packages
      `applicationId "…"` in build.gradle / build.gradle.kts, combined with every
      `applicationIdSuffix` found in the same file (flavour x build type, debug first). One id
      with no suffixes becomes `package`; anything else becomes the `packages` priority list.
      Falls back to `package="…"` in an AndroidManifest.xml.
  ios.bundleId
      `PRODUCT_BUNDLE_IDENTIFIER = …;` in *.pbxproj / *.xcconfig, ignoring test targets and
      unresolved `$(…)` values; the most frequent value wins.
  version.file / version.regex
      the first of: a `versionCode = 42` literal (gradle), a
      `versionCode = providers.gradleProperty("k")` -> gradle.properties + `^k=(.*)$`,
      pubspec.yaml's `version: 1.2.3+45` -> the +build, `CURRENT_PROJECT_VERSION = 12;` (pbxproj).
  testTagsFile
      a file named TestTags.kt / TestTags.swift / TestTags.ts / test_tags.dart.

Paths are printed repo-relative with forward slashes on every OS. Nothing here needs a device.
"""
import argparse
import collections
import json
import os
import re
import sys

SKIP_DIRS = {".git", ".gradle", ".idea", "build", "node_modules", "DerivedData", ".kotlin",
             "Pods", ".dart_tool", "out", "target", ".venv", "venv", "__pycache__"}
TAG_FILES = {"TestTags.kt", "TestTags.swift", "TestTags.ts", "TestTags.tsx", "test_tags.dart"}

RE_APP_ID = re.compile(r'\bapplicationId\s*=?\s*["\']([A-Za-z0-9_.]+)["\']')
RE_SUFFIX = re.compile(r'\bapplicationIdSuffix\s*=?\s*["\']([A-Za-z0-9_.]+)["\']')
RE_MANIFEST_PKG = re.compile(r'<manifest[^>]*\bpackage\s*=\s*["\']([A-Za-z0-9_.]+)["\']')
RE_BUNDLE = re.compile(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?([A-Za-z0-9_.$(){}-]+)"?\s*;?')
RE_VC_LITERAL = re.compile(r'\bversionCode\s*=?\s*(\d+)\b')
RE_VC_PROPERTY = re.compile(r'\bversionCode\s*=?\s*[^\n]*gradleProperty\(\s*["\']([^"\']+)["\']')
RE_PUBSPEC = re.compile(r'^version:\s*[^+\s]+\+(\d+)', re.MULTILINE)
RE_PBX_VERSION = re.compile(r'CURRENT_PROJECT_VERSION\s*=\s*([0-9.]+)\s*;')


def rel(root, path):
    return os.path.relpath(path, root).replace(os.sep, "/")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def uniq(items):
    out = []
    for x in items:
        if x not in out:
            out.append(x)
    return out


def block(text, name):
    """(start, end) offsets of the `name { … }` block, brace-matched; (-1, -1) when absent."""
    m = re.search(r"\b%s\s*\{" % re.escape(name), text)
    if not m:
        return (-1, -1)
    depth, i = 1, m.end()
    while i < len(text) and depth:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    return (m.end(), i)


def walk(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS and not d.startswith("."))
        for name in sorted(filenames):
            yield os.path.join(dirpath, name), name


def detect(root):
    found = {"android": {}, "ios": {}, "version": {}, "testTagsFile": "", "evidence": []}
    app_ids, build_suffixes, flavor_suffixes, manifest_pkgs = [], [], [], []
    bundle_ids = collections.Counter()
    tag_file = None
    # Version sources compete by priority (gradle 0, pubspec 1, pbxproj 2), not by walk order:
    # a Flutter repo has both a pubspec and an android/app/build.gradle, and the gradle one wins.
    version, version_rank, version_note = None, 99, ""

    def offer(rank, candidate, note):
        nonlocal version, version_rank, version_note
        if rank < version_rank:
            version, version_rank, version_note = candidate, rank, note

    for path, name in walk(root):
        low = name.lower()
        if name in ("build.gradle", "build.gradle.kts"):
            text = read(path)
            for m in RE_APP_ID.finditer(text):
                app_ids.append(m.group(1))
                found["evidence"].append("%s: applicationId %s" % (rel(root, path), m.group(1)))
            bt = block(text, "buildTypes")
            for m in RE_SUFFIX.finditer(text):
                if bt[0] <= m.start() < bt[1]:
                    build_suffixes.append(m.group(1))
                else:
                    flavor_suffixes.append(m.group(1))   # productFlavors, or declared elsewhere
            m = RE_VC_LITERAL.search(text)
            if m:
                offer(0, {"file": rel(root, path), "regex": r"\bversionCode\s*=?\s*(\d+)"},
                      "%s: versionCode %s" % (rel(root, path), m.group(1)))
            else:
                m = RE_VC_PROPERTY.search(text)
                if m and os.path.isfile(os.path.join(root, "gradle.properties")):
                    offer(0, {"file": "gradle.properties", "regex": "^%s=(.*)$" % re.escape(m.group(1))},
                          "%s: versionCode from gradle.properties %s" % (rel(root, path), m.group(1)))
        elif name == "AndroidManifest.xml":
            m = RE_MANIFEST_PKG.search(read(path))
            if m:
                manifest_pkgs.append(m.group(1))
        elif low.endswith((".pbxproj", ".xcconfig")):
            text = read(path)
            for m in RE_BUNDLE.finditer(text):
                value = m.group(1)
                if "$" in value or "Tests" in value or "UITests" in value:
                    continue
                bundle_ids[value] += 1
            m = RE_PBX_VERSION.search(text)
            if m and low.endswith(".pbxproj"):
                offer(2, {"file": rel(root, path), "regex": r"CURRENT_PROJECT_VERSION\s*=\s*([0-9.]+)\s*;"},
                      "%s: CURRENT_PROJECT_VERSION %s" % (rel(root, path), m.group(1)))
        elif name == "pubspec.yaml":
            m = RE_PUBSPEC.search(read(path))
            if m:
                offer(1, {"file": rel(root, path), "regex": r"^version:\s*[^+\s]+\+(\d+)"},
                      "%s: build number %s" % (rel(root, path), m.group(1)))
        if name in TAG_FILES and tag_file is None:
            tag_file = rel(root, path)

    # Android: applicationId + flavour suffix + build-type suffix, in that order, every
    # combination — the ones ending in .debug first, since the first *installed* entry wins at
    # capture time and an unused combination costs nothing.
    base_ids = uniq(app_ids + manifest_pkgs)
    flavors = uniq(flavor_suffixes)
    builds = uniq(build_suffixes)
    if base_ids:
        if len(base_ids) == 1 and not flavors and not builds:
            found["android"]["package"] = base_ids[0]
        else:
            combos = []
            for base in base_ids:
                for f in flavors + [""]:
                    for b in builds + [""]:
                        candidate = base + f + b
                        if candidate not in combos:
                            combos.append(candidate)
            combos.sort(key=lambda c: (0 if c.endswith(".debug") else 1, -c.count("."), c))
            found["android"]["packages"] = combos
    if bundle_ids:
        found["ios"]["bundleId"] = bundle_ids.most_common(1)[0][0]
        found["evidence"].append("iOS bundle id %s" % found["ios"]["bundleId"])
    if version:
        found["version"] = version
        found["evidence"].append(version_note)
    if tag_file:
        found["testTagsFile"] = tag_file
        found["evidence"].append("test tags: %s" % tag_file)
    return found


def load_config(path):
    if not os.path.exists(path):
        return {}
    text = read(path)
    if not text.strip():
        return {}
    return json.loads(text)


def empty(value):
    return value in (None, "", [], {})


def merge(config, found, force):
    """Fill config with what was found; only empty values unless force. Returns what changed."""
    changed = []
    def put(section, key, value):
        if empty(value):
            return
        target = config if section is None else config.setdefault(section, {})
        if force or empty(target.get(key)):
            if target.get(key) != value:
                target[key] = value
                changed.append("%s%s = %s" % (section + "." if section else "", key, json.dumps(value)))
    put("android", "package", found["android"].get("package"))
    put("android", "packages", found["android"].get("packages"))
    # Detection found a flavour list: under --force a single pinned package would shadow it.
    if force and found["android"].get("packages") and not empty(config.get("android", {}).get("package")):
        config["android"]["package"] = ""
        changed.append("android.package = \"\" (superseded by android.packages)")
    put("ios", "bundleId", found["ios"].get("bundleId"))
    if found["version"]:
        vsec = config.setdefault("version", {})
        if force or (empty(vsec.get("file")) and empty(vsec.get("regex"))):
            if vsec.get("file") != found["version"]["file"] or vsec.get("regex") != found["version"]["regex"]:
                vsec["file"] = found["version"]["file"]
                vsec["regex"] = found["version"]["regex"]
                changed.append("version = %s" % json.dumps(found["version"]))
    put(None, "testTagsFile", found["testTagsFile"])
    return changed


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=os.getcwd())
    ap.add_argument("--json", action="store_true", help="print the findings as JSON")
    ap.add_argument("--write", metavar="CONFIG", help="fill the empty values of this config.json")
    ap.add_argument("--force", action="store_true", help="with --write: overwrite non-empty values too")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    found = detect(root)

    if args.write:
        config = load_config(args.write)
        changed = merge(config, found, args.force)
        # LF on Windows too; a CRLF config is fine for jq but a diff nuisance in git.
        with open(args.write, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(config, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        for line in changed:
            print("detected %s" % line)
        if not changed:
            print("nothing new detected; config unchanged")
        return 0

    if args.json:
        print(json.dumps(found, indent=2, ensure_ascii=False))
        return 0

    print("android.package:  %s" % (found["android"].get("package") or "-"))
    print("android.packages: %s" % (", ".join(found["android"].get("packages", [])) or "-"))
    print("ios.bundleId:     %s" % (found["ios"].get("bundleId") or "-"))
    if found["version"]:
        print("version:          %s  /%s/" % (found["version"]["file"], found["version"]["regex"]))
    else:
        print("version:          -")
    print("testTagsFile:     %s" % (found["testTagsFile"] or "-"))
    for e in found["evidence"]:
        print("  - %s" % e)
    return 0


if __name__ == "__main__":
    sys.exit(main())
