#!/usr/bin/env bash
# bin/config.sh: config readers (jq and Python paths), slug rules, version fallback, stem
# collisions, PNG/XML checks.
. "$(dirname "${BASH_SOURCE[0]//\\//}")/lib.sh"
D="$(new_tmp config)"
cat > "$D/config.json" <<'JSON'
{ "outputDir": "shots", "slugMaxLength": 20,
  "android": { "package": "com.example.app", "packages": ["a.b.debug", "a.b"] },
  "ios": { "simulators": ["iPhone 16"], "hierarchyTimeout": 30 },
  "version": { "file": "gradle.properties", "regex": "^app\\.versionCode=(.*)$" } }
JSON
printf 'app.versionCode=77\nother=1\n' > "$D/gradle.properties"

export SMART_SCREENSHOT_CONFIG="$D/config.json"
assert_eq "config_get scalar" "com.example.app" "$(config_get .android.package)"
assert_eq "config_get number" "30" "$(config_get .ios.hierarchyTimeout)"
assert_eq "config_get default" "dflt" "$(config_get .nope dflt)"
assert_eq "config_get empty-string is missing" "x" "$(SMART_SCREENSHOT_CONFIG="$ROOT/template/.claude/smart-screenshot/config.example.json" config_get .android.package x)"
assert_eq "config_list" "a.b.debug a.b" "$(config_list .android.packages | tr '\n' ' ' | sed 's/ $//')"
assert_eq "config_list missing" "" "$(config_list .android.nope)"
if command -v jq >/dev/null 2>&1; then
  # Force the Python reader and compare.
  assert_eq "python reader: scalar" "com.example.app" "$(_config_py get "$D/config.json" .android.package)"
  assert_eq "python reader: list" "a.b.debug a.b" "$(_config_py list "$D/config.json" .android.packages | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "python reader: default" "" "$(_config_py get "$D/config.json" .android.nope || true)"
else
  pass "no jq here: config_get already went through Python"
fi
SMART_SCREENSHOT_CONFIG="$D/broken.json"; printf '{not json' > "$D/broken.json"
assert_eq "broken config -> default" "dflt" "$(config_get .outputDir dflt)"
SMART_SCREENSHOT_CONFIG="$D/config.json"

# ---- slug
slug_of() { # subject [maxlen]
  local g; g="$(new_tmp slug)"
  git -C "$g" init -q; git -C "$g" config user.email t@t; git -C "$g" config user.name t
  git -C "$g" commit -q --allow-empty -m "$1"
  ss_commit_slug "$g"
}
assert_eq "slug strips a Jira ticket (len 20)" "Fix-the-thing-quickl" "$(slug_of 'ABC-123: Fix the thing quickly')"
assert_eq "slug strips [TICKET]" "Do-it" "$(slug_of '[PROJ-9] Do it')"
assert_eq "slug strips #issue" "Add-login-button" "$(slug_of '#42 Add login button')"
assert_eq "slug of a plain subject" "Small-fixes-here" "$(slug_of 'Small fixes, here!')"
SMART_SCREENSHOT_CONFIG="$D/none.json"
assert_eq "slug default length 10, trailing dash trimmed" "Fix-the-th" "$(slug_of 'ABC-123: Fix the thing quickly')"
NOGIT="$(mktemp -d "${TMPDIR:-/tmp}/ss-nogit.XXXXXX")"
assert_eq "no git -> empty slug" "" "$(ss_commit_slug "$NOGIT")"
rmdir "$NOGIT"
SMART_SCREENSHOT_CONFIG="$D/config.json"

# ---- version fallback (relative file resolves against the project root; use an absolute one here)
cat > "$D/config.json" <<JSON
{ "version": { "file": "$D/gradle.properties", "regex": "^app\\\\.versionCode=(.*)\$" } }
JSON
assert_eq "version fallback via regex" "77" "$(ss_version_fallback)"
printf '{ "version": { "file": "%s/missing", "regex": "x" } }\n' "$D" > "$D/config.json"
assert_eq "version fallback missing file -> empty" "" "$(ss_version_fallback 2>/dev/null)"
printf '{}' > "$D/config.json"
assert_eq "no version fallback configured -> empty" "" "$(ss_version_fallback)"

# ---- stem collision (date frozen through a shell function)
date() { printf 'FIXED\n'; }
ss_pick_stem "$D" smartScreenShot 5 slug
assert_eq "first stem" "smartScreenShot_FIXED_FIXED_v5_slug" "$SS_STEM"
touch "$D/smartScreenShot_FIXED_FIXED_v5_slug.bounds.png"
ss_pick_stem "$D" smartScreenShot 5 slug
assert_eq "a bounds variant alone forces _2" "smartScreenShot_FIXED_FIXED_v5_slug_2" "$SS_STEM"
touch "$D/smartScreenShot_FIXED_FIXED_v5_slug_2.xml"
ss_pick_stem "$D" smartScreenShot 5 ""
assert_eq "no slug, no collision" "smartScreenShot_FIXED_FIXED_v5" "$SS_STEM"
ss_pick_stem "$D" smartScreenShot 5 slug
assert_eq "…and _3 after _2" "smartScreenShot_FIXED_FIXED_v5_slug_3" "$SS_STEM"
unset -f date

# ---- artifact checks
printf '\x89PNG\r\n\x1a\nrest' > "$D/ok.png"; printf 'GIF89a' > "$D/bad.png"; : > "$D/empty.png"
ss_png_ok "$D/ok.png" && pass "png signature accepted" || fail "png signature accepted"
ss_png_ok "$D/bad.png" && fail "non-png rejected" || pass "non-png rejected"
ss_png_ok "$D/empty.png" && fail "empty png rejected" || pass "empty png rejected"
printf '<?xml version="1.0"?><hierarchy rotation="0"><node bounds="[0,0][1,1]"/></hierarchy>\n' > "$D/ok.xml"
printf '<?xml version="1.0"?><nope/>\n' > "$D/noroot.xml"
printf '<hierarchy><node></hierarchy>\n' > "$D/broken.xml"
ss_xml_ok "$D/ok.xml" && pass "xml accepted" || fail "xml accepted"
ss_xml_ok "$D/noroot.xml" && fail "xml without hierarchy rejected" || pass "xml without hierarchy rejected"
if command -v xmllint >/dev/null 2>&1; then
  ss_xml_ok "$D/broken.xml" && fail "malformed xml rejected (xmllint)" || pass "malformed xml rejected (xmllint)"
fi

# ---- output dir
SMART_SCREENSHOT_CONFIG="$D/config.json"
printf '{ "outputDir": "captures/here/" }' > "$D/config.json"
assert_eq "outputDir relative to root" "$(ss_root)/captures/here" "$(ss_output_dir)"
printf '{ "outputDir": "%s/abs" }' "$D" > "$D/config.json"
assert_eq "outputDir absolute" "$D/abs" "$(ss_output_dir)"
assert_eq "SMART_SCREENSHOT_DIR wins" "/x/y" "$(SMART_SCREENSHOT_DIR=/x/y ss_output_dir)"

report config
