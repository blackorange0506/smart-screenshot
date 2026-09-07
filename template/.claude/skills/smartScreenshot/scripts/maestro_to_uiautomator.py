#!/usr/bin/env python3
"""Convert `maestro hierarchy` JSON into the uiautomator XML /smartScreenshot produces on Android.

Why this exists at all: iOS has no uiautomator. `xcrun simctl` has no
accessibility or hierarchy command whatsoever -- `io` offers only enumerate,
poll, recordVideo and screenshot. Maestro's `hierarchy` command, which drives
the simulator through a bundled XCTest driver, is the route this skill takes to
an iOS view tree.

Why the *same* XML rather than a new format: everything downstream of a capture
keys off that shape. The annotator correlates a mark to a view by parsing
`bounds="[x1,y1][x2,y2]"` out of `<node>` elements, and /processSmartScreenshot
defines "a capture" as the existence of a `<stem>.xml`. Emitting uiautomator XML
means neither needs to know iOS exists.

The one thing that cannot be copied across is units. Every XCUIElement frame is
in *points* (iPhone 15: 393x852) while `simctl io screenshot` writes *pixels*
(1179x2556) -- a 3x mismatch. The annotator maps a raw click pixel straight onto
node bounds, so uncorrected bounds are wrong everywhere except the top-left
corner, and wrong in a way nothing downstream could detect. So the scale is
derived from the artifacts themselves (PNG width / root frame width),
cross-checked against the device profile, and the conversion *fails* rather than
falling back to 1.0.

Stdout is the XML only when --out is omitted; the resolved scale and every
warning go to stderr. Non-zero exit means no usable XML was produced, and the
caller is expected to delete a partial file, exactly as the Android path does
for a failed `uiautomator dump`.
"""

import argparse
import json
import re
import struct
import sys
import xml.etree.ElementTree as ET

# Maestro writes its JSON with println *after* other stdout chatter -- the CLI
# prints "Launching iOS simulator..." and may print coloured insight text to the
# same stream -- so the payload is located rather than assumed to start at byte 0.
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
BOUNDS_RE = re.compile(r"^\s*\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]\s*$")

# XML 1.0 forbids most C0 controls outright; an accessibility label carrying one
# would produce a file no parser downstream can read.
ILLEGAL_XML_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")

# Maestro drops XCUIElement.elementType before serializing, so the real class of
# a node is not recoverable from `maestro hierarchy` at any price. A constant is
# honest; a plausible-looking "XCUIElementTypeButton" would read as fact in a
# marks sidecar. The annotator only needs `class` to be a non-empty string
# (viewLabel does v.class.split('.').pop()), and never uses it for correlation.
DEFAULT_CLASS = "XCUIElement"
SWITCH_CLASS = "XCUIElementTypeSwitch"


def log(msg):
    print("[maestro-xml] %s" % msg, file=sys.stderr)


def fail(msg):
    print("[maestro-xml] ERROR: %s" % msg, file=sys.stderr)
    sys.exit(1)


def load_hierarchy(raw):
    """Parse the first JSON object in Maestro's output, ignoring any preamble."""
    text = ANSI_RE.sub("", raw)
    start = text.find("{")
    if start < 0:
        fail("no JSON object in Maestro's output (was the hierarchy dump empty?)")
    try:
        obj, _ = json.JSONDecoder().raw_decode(text[start:])
    except ValueError as exc:
        fail("could not parse Maestro's JSON: %s" % exc)
    if not isinstance(obj, dict):
        fail("Maestro's JSON root is %s, expected an object" % type(obj).__name__)
    return obj


def png_size(path):
    """(width, height) in pixels, read straight from the IHDR.

    Bytes 0-7 are the signature the shell already validates, 12-15 spell IHDR,
    and 16-23 are two big-endian uint32s. Reading them here keeps Pillow out of
    a skill whose only other Python dependency is the standard library.
    """
    try:
        with open(path, "rb") as fh:
            head = fh.read(24)
    except OSError as exc:
        log("cannot read PNG %s: %s" % (path, exc))
        return None
    if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        log("%s is not a PNG with a leading IHDR chunk" % path)
        return None
    return struct.unpack(">II", head[16:24])


def parse_bounds(value):
    m = BOUNDS_RE.match(value or "")
    if not m:
        return None
    return tuple(int(g) for g in m.groups())


def walk(node, out):
    """Depth-first list of every node, so bounds can be surveyed before scaling."""
    out.append(node)
    for child in node.get("children") or []:
        if isinstance(child, dict):
            walk(child, out)
    return out


def resolve_scale(root, all_nodes, png, fallback):
    """points -> pixels, in descending order of trustworthiness.

    When the XCUIApplication root carries a real frame it is the whole screen, so
    PNG width over root width is exact. In practice it usually does not -- a live
    capture reports [0,0][0,0] for the root -- so the simulator's own
    mainScreenScale comes next: also exact, just measured elsewhere.

    The union of every node's bounds is the last resort rather than the second
    choice, because it is the only estimate here that can be wrong. Any element
    scrolled partly off-screen widens the union past the screen and shrinks the
    derived scale with it; a real capture had a list row reaching 3px below the
    bottom edge, which is small but is the good case, not the bound.

    A hard failure is what follows -- see the module docstring for why silently
    assuming 1.0 is the worst option available.
    """
    if png is None:
        if fallback:
            log("no PNG to measure; using device scale %.4f" % fallback)
            return fallback
        fail("no PNG to derive the point->pixel scale from, and no --fallback-scale given")

    png_w, png_h = png

    def from_rect(rect, source):
        left, top, right, bottom = rect
        w, h = right - left, bottom - top
        if w <= 0 or h <= 0:
            return None
        sx, sy = png_w / float(w), png_h / float(h)
        # A disagreement between the axes means the rect is not the screen --
        # iPad Split View, Stage Manager, a stray non-app root. That is exactly
        # the case where scaling by one axis is silently wrong, so say so.
        if abs(sx - sy) / sx > 0.02:
            log("WARN: %s is not screen-shaped (x scale %.4f vs y scale %.4f); "
                "bounds may be off. Is the app full-screen?" % (source, sx, sy))
        log("scale %.4f from %s (%dx%d points -> %dx%d pixels)"
            % (sx, source, w, h, png_w, png_h))
        return sx

    scale = None
    root_bounds = parse_bounds((root.get("attributes") or {}).get("bounds", ""))
    if root_bounds:
        scale = from_rect(root_bounds, "root node bounds")

    if scale is None and fallback:
        # Reached on most live captures, not just broken ones: the real
        # XCUIApplication root reports [0,0][0,0].
        log("root frame is degenerate; using the simulator's own screen scale %.4f" % fallback)
        scale = fallback

    if scale is None:
        rects = [parse_bounds((n.get("attributes") or {}).get("bounds", "")) for n in all_nodes]
        rects = [r for r in rects if r]
        if rects:
            union = (min(r[0] for r in rects), min(r[1] for r in rects),
                     max(r[2] for r in rects), max(r[3] for r in rects))
            log("no root frame and no device scale; estimating from the union of all "
                "node bounds, which anything scrolled off-screen will skew")
            scale = from_rect(union, "union of all node bounds")

    if scale is None:
        fail("could not determine the point->pixel scale: the hierarchy has no usable "
             "bounds and no --fallback-scale was given. Refusing to guess 1.0 -- bounds "
             "that are silently 3x off are worse than no capture.")

    if fallback and abs(scale - fallback) > 0.01:
        log("WARN: derived scale %.4f disagrees with the device's own scale %.4f"
            % (scale, fallback))
    return scale


def clean(value):
    return ILLEGAL_XML_RE.sub("", value if isinstance(value, str) else str(value))


def convert_node(node, parent_el, index, scale, package, switch_class):
    attrs = node.get("attributes") or {}
    get = lambda k: clean(attrs.get(k, "") or "")

    text = get("text") or get("accessibilityText")
    # content-desc must not simply repeat what text already says, or every node
    # reads twice in a mark's view summary. hintText (the placeholder) is the
    # next most useful thing when the label has already been used as text.
    accessibility = get("accessibilityText")
    content_desc = accessibility if accessibility and accessibility != text else get("hintText")

    checkable = "checked" in attrs
    el = ET.SubElement(parent_el, "node")
    el.set("index", str(index))
    el.set("text", text)
    el.set("resource-id", get("resource-id"))
    el.set("class", SWITCH_CLASS if (switch_class and checkable) else DEFAULT_CLASS)
    el.set("package", package)
    el.set("content-desc", content_desc)
    el.set("checkable", "true" if checkable else "false")
    el.set("checked", get("checked") or "false")
    el.set("enabled", get("enabled") or "true")
    el.set("focused", get("focused") or "false")
    el.set("selected", get("selected") or "false")

    # clickable / focusable / scrollable / long-clickable / password are absent
    # by design: IOSDriver leaves TreeNode.clickable null and the rest would need
    # elementType, which Maestro discards. "false" would be a lie and "true" a
    # guess -- an omitted attribute is neither.

    rect = parse_bounds(attrs.get("bounds", ""))
    if rect:
        s = lambda v: int(round(v * scale))
        el.set("bounds", "[%d,%d][%d,%d]" % (s(rect[0]), s(rect[1]), s(rect[2]), s(rect[3])))
    # An unparsable bounds leaves the attribute off entirely: the annotator's
    # `if (!m) continue` then skips the node for correlation while it stays
    # readable in the file.

    for i, child in enumerate(node.get("children") or []):
        if isinstance(child, dict):
            convert_node(child, el, i, scale, package, switch_class)
    return el


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--json", required=True, help="maestro hierarchy output, or - for stdin")
    ap.add_argument("--png", help="the paired screenshot; its pixel size sets the scale")
    ap.add_argument("--fallback-scale", type=float, default=0.0,
                    help="the simulator's mainScreenScale, used as a cross-check and last resort")
    ap.add_argument("--package", default="", help="bundle id, recorded as each node's package")
    ap.add_argument("--device-name", default="")
    ap.add_argument("--device-udid", default="")
    ap.add_argument("--out", help="write here instead of stdout")
    ap.add_argument("--switch-class", action="store_true",
                    help='emit class="XCUIElementTypeSwitch" for nodes Maestro marked checkable')
    args = ap.parse_args()

    raw = sys.stdin.read() if args.json == "-" else open(args.json, encoding="utf-8",
                                                         errors="replace").read()
    root_node = load_hierarchy(raw)
    all_nodes = walk(root_node, [])
    scale = resolve_scale(root_node, all_nodes, png_size(args.png) if args.png else None,
                          args.fallback_scale or None)

    # uiautomator emits <hierarchy rotation="0">. The extra attributes are
    # ignored by the annotator's DOMParser, by xmllint --noout (no DTD) and by
    # the capture selector, while making the platform and the applied scale
    # auditable inside the artifact -- which is what you want the first time a
    # correlation looks off.
    root_el = ET.Element("hierarchy")
    root_el.set("rotation", "0")
    root_el.set("platform", "ios")
    root_el.set("scale", "%.4f" % scale)
    if args.package:
        root_el.set("bundle-id", args.package)
    if args.device_name:
        root_el.set("device-name", clean(args.device_name))
    if args.device_udid:
        root_el.set("device-udid", clean(args.device_udid))
    root_el.set("source", "maestro hierarchy")

    convert_node(root_node, root_el, 0, scale, clean(args.package), args.switch_class)
    log("converted %d nodes" % len(all_nodes))

    tree = ET.ElementTree(root_el)
    if args.out:
        tree.write(args.out, encoding="utf-8", xml_declaration=True)
    else:
        tree.write(sys.stdout.buffer, encoding="utf-8", xml_declaration=True)
        sys.stdout.buffer.write(b"\n")


if __name__ == "__main__":
    main()
