#!/usr/bin/env python3
"""Prove the Maestro->uiautomator converter scales bounds correctly.

The converter is the one genuinely new piece of logic behind /smartScreenshot
--ios, and it is the only place a silent 3x coordinate error can enter: Maestro
reports XCUIElement frames in points, the screenshot is in pixels, and nothing
downstream can tell a correctly-scaled capture from a badly-scaled one. A mark
would simply land on the wrong view, plausibly, forever.

So: hand-written TreeNode-shaped fixtures, a hand-built 24-byte PNG header, and
an assertion for each way the conversion can go wrong -- including a negative
control that fails if the scale is quietly 1.0.

Needs no simulator, no Maestro, no network.

Run: python3 selftest_maestro_to_uiautomator.py
"""

from __future__ import annotations

import json
import shutil
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).parent
CONVERTER = HERE / "maestro_to_uiautomator.py"

# iPhone 15: 393x852 points, 1179x2556 pixels. Scale 3.
PNG_W, PNG_H = 1179, 2556


def write_png(path: Path, width: int = PNG_W, height: int = PNG_H) -> None:
    """The 24 bytes the converter actually reads: signature + IHDR length/type/size.

    Writing it by hand rather than with Pillow also exercises the header reader
    against a file that is nothing but a header.
    """
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", width, height)
    )


def node(bounds=None, children=None, **attrs):
    a = dict(attrs)
    if bounds is not None:
        a["bounds"] = bounds
    n = {"attributes": a}
    if children:
        n["children"] = children
    return n


# The fixture mirrors what IOSDriver.mapViewHierarchy really emits: a full-screen
# root, a tagged button carrying a Compose testTag as resource-id, a label whose
# only text is the accessibility label, a switch (the one case Maestro sets
# `checked` for), a node stripped down to bounds alone by removeEmptyValues, and
# one with unparsable bounds.
FIXTURE = node(
    bounds="[0,0][393,852]",
    children=[
        node(
            bounds="[10,20][110,70]",
            **{"resource-id": "login_submit", "title": "Sign in", "text": "Sign in",
               "accessibilityText": "Sign in", "enabled": "true"},
        ),
        node(bounds="[0,100][393,140]", accessibilityText='He said "hi" & <left>'),
        node(bounds="[300,200][380,240]", **{"resource-id": "sync_toggle", "checked": "true",
                                             "hintText": "Automatic sync"}),
        node(bounds="[0,300][393,340]"),
        node(bounds="not-a-rect", **{"resource-id": "weird"}),
    ],
)

PREAMBLE = "Launching iOS simulator...\n\x1b[33mSome yellow insight text\x1b[0m\n\n"


def run(json_text: str, png: Path | None, *extra) -> tuple[int, str, str]:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        fh.write(json_text)
        json_path = fh.name
    cmd = [sys.executable, str(CONVERTER), "--json", json_path, "--package", "com.example.app"]
    if png is not None:
        cmd += ["--png", str(png)]
    cmd += list(extra)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


def bounds_of(root: ET.Element, resource_id: str) -> str | None:
    for el in root.iter("node"):
        if el.get("resource-id") == resource_id:
            return el.get("bounds")
    return None


def deepest_at(root: ET.Element, x: int, y: int):
    """The annotator's rule, re-implemented: deepest containing node, smallest area wins."""
    best = None
    def visit(el, depth):
        nonlocal best
        b = el.get("bounds")
        if b:
            x1, y1 = (int(v) for v in b[1:b.index("]")].split(","))
            rest = b[b.index("][") + 2:-1]
            x2, y2 = (int(v) for v in rest.split(","))
            if x1 <= x < x2 and y1 <= y < y2:
                area = (x2 - x1) * (y2 - y1)
                if best is None or depth > best[0] or (depth == best[0] and area < best[1]):
                    best = (depth, area, el)
        for child in el:
            visit(child, depth + 1)
    for child in root:
        visit(child, 0)
    return best[2] if best else None


def main() -> int:
    ok = True

    def check(cond, good, bad):
        nonlocal ok
        print(("ok   " + good) if cond else ("FAIL " + bad))
        if not cond:
            ok = False

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        png = tmp / "shot.png"
        write_png(png)

        code, out, err = run(json.dumps(FIXTURE), png)
        if code != 0:
            print("FAIL converter exited %d\n%s" % (code, err))
            return 1
        root = ET.fromstring(out)
        root_node = root.find("node")

        # 1 + 2 + 3: the whole point of the exercise.
        check(root_node.get("bounds") == "[0,0][1179,2556]",
              "root bounds scaled to the PNG's exact pixel size",
              "root bounds %r, expected [0,0][1179,2556]" % root_node.get("bounds"))

        child = bounds_of(root, "login_submit")
        check(child == "[30,60][330,210]",
              "child bounds scaled right/bottom, not width/height",
              "child bounds %r, expected [30,60][330,210]" % child)

        check(child != "[10,20][110,70]",
              "scale is genuinely applied (not silently 1.0)",
              "child bounds came through unscaled -- the scale is 1.0")

        # 4: text precedence and the content-desc de-duplication rule.
        label = [el for el in root.iter("node") if el.get("text", "").startswith("He said")]
        check(len(label) == 1 and label[0].get("content-desc") == "",
              "accessibilityText fills text, and content-desc does not repeat it",
              "accessibilityText/content-desc rule broken: %s"
              % ([(e.get("text"), e.get("content-desc")) for e in label]))

        toggle = [el for el in root.iter("node") if el.get("resource-id") == "sync_toggle"][0]
        check(toggle.get("content-desc") == "Automatic sync",
              "hintText fills content-desc when there is no accessibility label",
              "content-desc %r, expected the hintText" % toggle.get("content-desc"))

        # 5
        check(bounds_of(root, "login_submit") is not None,
              "resource-id (the Compose testTag) survives verbatim",
              "resource-id was dropped")

        # 6: the annotator does v.class.split('.').pop() on every mark.
        classes = [el.get("class") for el in root.iter("node")]
        check(all(c for c in classes),
              "every node has a non-empty class",
              "%d node(s) have no class -- the annotator throws on every mark"
              % sum(1 for c in classes if not c))

        # checkable is derived from Maestro emitting `checked` at all.
        check(toggle.get("checkable") == "true" and root_node.get("checkable") == "false",
              "checkable is set only where Maestro reported a checked state",
              "checkable is wrong: toggle=%s root=%s"
              % (toggle.get("checkable"), root_node.get("checkable")))

        # 7: sibling ordinals and nesting, via the annotator's own correlation rule.
        kids = list(root_node)
        check([el.get("index") for el in kids] == [str(i) for i in range(len(kids))],
              "index is the 0-based sibling ordinal",
              "index sequence %r" % [el.get("index") for el in kids])

        hit = deepest_at(root, 100, 100)  # inside the scaled login_submit [30,60][330,210]
        check(hit is not None and hit.get("resource-id") == "login_submit",
              "deepest-node correlation resolves to the child, not the root",
              "correlation hit %r" % (hit.get("resource-id") if hit is not None else None))

        # 8: XML escaping round-trips.
        check(any(el.get("text") == 'He said "hi" & <left>' for el in root.iter("node")),
              'quotes, & and < round-trip through the XML',
              "escaping mangled the label")

        # 9: Maestro's own stdout chatter must not break the parse.
        code9, out9, _ = run(PREAMBLE + json.dumps(FIXTURE), png)
        check(code9 == 0 and ET.fromstring(out9).find("node") is not None,
              "a launch banner and ANSI colour before the JSON are tolerated",
              "preamble broke the parse (exit %d)" % code9)

        # 10: removeEmptyValues means almost every key can be missing.
        bare = [el for el in root.iter("node") if el.get("bounds") == "[0,900][1179,1020]"]
        check(len(bare) == 1 and bare[0].get("enabled") == "true",
              "a node with nothing but bounds converts and defaults sensibly",
              "the bounds-only node did not convert as expected")

        # An unparsable bounds leaves the attribute off rather than inventing one.
        weird = [el for el in root.iter("node") if el.get("resource-id") == "weird"][0]
        check(weird.get("bounds") is None,
              "an unparsable bounds is omitted, not guessed",
              "unparsable bounds became %r" % weird.get("bounds"))

        # 11: a degenerate root must fail loudly -- unless the device scale is on hand.
        degenerate = node(bounds="[0,0][0,0]", children=[node(**{"resource-id": "x"})])
        code11, _, _ = run(json.dumps(degenerate), png)
        check(code11 != 0,
              "a hierarchy with no usable bounds fails instead of guessing 1.0",
              "converter accepted a degenerate hierarchy (exit 0)")

        degenerate_root = dict(FIXTURE)
        degenerate_root["attributes"] = {"bounds": "[0,0][0,0]"}
        code11b, out11b, _ = run(json.dumps(degenerate_root), png, "--fallback-scale", "3")
        check(code11b == 0 and bounds_of(ET.fromstring(out11b), "login_submit") == "[30,60][330,210]",
              "--fallback-scale rescues a degenerate root with the device's own scale",
              "fallback scale did not reproduce the expected bounds (exit %d)" % code11b)

        # ...and with neither, the union of the children still gets there. This is
        # the last resort precisely because off-screen content skews it, so it
        # has to keep working for the case where nothing better exists.
        code11d, out11d, err11d = run(json.dumps(degenerate_root), png)
        check(code11d == 0 and "union" in err11d
              and bounds_of(ET.fromstring(out11d), "login_submit") == "[30,60][330,210]",
              "the union of all node bounds is the last-resort scale source",
              "union fallback did not produce the expected bounds (exit %d)" % code11d)

        # And with no PNG and no fallback there is nothing to derive a scale from.
        code11c, _, _ = run(json.dumps(FIXTURE), None)
        check(code11c != 0,
              "no PNG and no fallback scale is a hard failure",
              "converter invented a scale with nothing to measure")

        # 12: the shell validates the artifact exactly this way.
        check(root.tag == "hierarchy" and root.get("platform") == "ios",
              "root is <hierarchy> and records the platform",
              "root tag/platform is %r/%r" % (root.tag, root.get("platform")))

        if shutil.which("xmllint"):
            xml_path = tmp / "out.xml"
            xml_path.write_text(out, encoding="utf-8")
            rc = subprocess.run(["xmllint", "--noout", str(xml_path)],
                                capture_output=True).returncode
            check(rc == 0, "xmllint accepts the output", "xmllint rejected the output")
        else:
            print("skip xmllint not on PATH")

    print("\nSELFTEST PASSED" if ok else "\nSELFTEST FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
