#!/usr/bin/env bash
# detect_project.py against planted build files: packages with flavour suffixes, the gradle
# property version, the iOS bundle id, the test-tag file; --write fills only empty values.
. "$(dirname "${BASH_SOURCE[0]//\\//}")/lib.sh"
DET="$ROOT/template/.claude/smart-screenshot/bin/detect_project.py"

A="$(new_tmp detect-a)"
mkdir -p "$A/app/src/main/kotlin/x" "$A/build" "$A/iosApp/iosApp.xcodeproj"
cat > "$A/app/build.gradle.kts" <<'K'
android {
    defaultConfig {
        applicationId = "com.example.app"
        versionCode = providers.gradleProperty("app.versionCode").get().toInt()
    }
    buildTypes { debug { applicationIdSuffix = ".debug" } }
    productFlavors { create("dev") { applicationIdSuffix = ".dev" }; create("qa") { applicationIdSuffix = ".qa" } }
}
K
printf 'app.versionCode=12\n' > "$A/gradle.properties"
printf 'applicationId "com.ignored.build"\n' > "$A/build/build.gradle"
: > "$A/app/src/main/kotlin/x/TestTags.kt"
cat > "$A/iosApp/iosApp.xcodeproj/project.pbxproj" <<'X'
PRODUCT_BUNDLE_IDENTIFIER = com.example.app.iosTests;
PRODUCT_BUNDLE_IDENTIFIER = com.example.app;
PRODUCT_BUNDLE_IDENTIFIER = com.example.app;
PRODUCT_BUNDLE_IDENTIFIER = "$(INHERITED)";
CURRENT_PROJECT_VERSION = 12;
X
j="$(ss_py "$DET" --root "$A" --json)"
assert_contains "packages: debug combos first" "$j" '"com.example.app.dev.debug"'
assert_eq "packages order" "com.example.app.dev.debug com.example.app.qa.debug com.example.app.debug com.example.app.dev com.example.app.qa com.example.app" \
  "$(ss_py -c 'import json,sys; print(" ".join(json.load(sys.stdin)["android"]["packages"]))' <<< "$j")"
assert_not_contains "build/ skipped" "$j" "com.ignored.build"
assert_contains "gradle property version" "$j" '"file": "gradle.properties"'
assert_contains "gradle property regex" "$j" '"regex": "^app\\.versionCode=(.*)$"'
assert_contains "ios bundle id (most frequent, no tests)" "$j" '"bundleId": "com.example.app"'
assert_contains "test tags file" "$j" '"testTagsFile": "app/src/main/kotlin/x/TestTags.kt"'

# --write: fills empties, keeps user values, --force overwrites
CFG="$A/config.json"
printf '{ "android": { "package": "keep.me" }, "ios": { "bundleId": "" }, "version": { "file": "", "regex": "" } }\n' > "$CFG"
out="$(ss_py "$DET" --root "$A" --write "$CFG")"
assert_contains "write: bundleId filled" "$out" "detected ios.bundleId"
assert_contains "write: version filled" "$out" "detected version"
c="$(cat "$CFG")"
assert_contains "write: user package kept" "$c" '"package": "keep.me"'
assert_contains "write: packages added" "$c" '"packages": ['
assert_eq "write: LF only" "0" "$(cr_count "$CFG")"
out="$(ss_py "$DET" --root "$A" --write "$CFG")"
assert_contains "write again: nothing new" "$out" "nothing new detected"
ss_py "$DET" --root "$A" --write "$CFG" --force >/dev/null
assert_not_contains "force overwrites the package" "$(cat "$CFG")" '"package": "keep.me"'

# A literal versionCode, a manifest package, pubspec
B="$(new_tmp detect-b)"
mkdir -p "$B/android/app/src/main"
printf 'android { defaultConfig { applicationId "com.b.app"\n versionCode 7 } }\n' > "$B/android/app/build.gradle"
printf '<manifest package="com.b.app"/>\n' > "$B/android/app/src/main/AndroidManifest.xml"
printf 'name: b\nversion: 1.2.3+45\n' > "$B/pubspec.yaml"
j="$(ss_py "$DET" --root "$B" --json)"
assert_contains "single package, no suffixes" "$j" '"package": "com.b.app"'
assert_not_contains "no packages list" "$j" '"packages"'
assert_contains "literal versionCode file" "$j" '"file": "android/app/build.gradle"'
# The human output
out="$(ss_py "$DET" --root "$B")"
assert_contains "human output" "$out" "android.package:  com.b.app"
C="$(new_tmp detect-c)"
out="$(ss_py "$DET" --root "$C")"
assert_contains "empty project: dashes" "$out" "android.package:  -"

report detect
