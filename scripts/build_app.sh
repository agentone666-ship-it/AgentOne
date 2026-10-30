#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
configuration="${1:-debug}"
# A single product version feeds local bundles, CI artifacts and release tags.
app_version="$(cat "$project_dir/VERSION")"
build_number="${AGENTONE_BUILD_NUMBER:-1}"
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[0-9]+$ ]]; then
    echo "App version must be X.Y.Z and build number must be numeric." >&2
    exit 1
fi
build_dir="$project_dir/build"
archive_path="$build_dir/AgentOne.app.zip"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentone-app-build.XXXXXX")"
app_dir="$staging_dir/AgentOne.app"
contents_dir="$app_dir/Contents"

cleanup() {
    rm -rf "$staging_dir"
}
trap cleanup EXIT

cd "$project_dir"
swift build -c "$configuration" --product AgentOne
swift build -c "$configuration" --product AgentOneRecorder

binary_path="$(swift build -c "$configuration" --show-bin-path)/AgentOne"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$binary_path" "$contents_dir/MacOS/AgentOne"
recorder_app="$contents_dir/Helpers/AgentOneRecorder.app"
mkdir -p "$recorder_app/Contents/MacOS" "$recorder_app/Contents/Resources"
cp "$(dirname "$binary_path")/AgentOneRecorder" "$recorder_app/Contents/MacOS/AgentOneRecorder"

# Only the new CaptureKit resource bundle ships; the legacy Agent runtime and
# its LifeForm/chat resources stay out of the default distribution.
resource_bundle="$(swift build -c "$configuration" --show-bin-path)/AgentOne_AgentOneCaptureKit.bundle"
if [[ -d "$resource_bundle" ]]; then
    cp -R "$resource_bundle" "$contents_dir/Resources/"
    cp -R "$resource_bundle" "$recorder_app/Contents/Resources/"
fi

plugin_resources="$contents_dir/Resources/agentone-memory"
mkdir -p "$plugin_resources"
for resource in server.mjs store.mjs recall.mjs conversations.mjs schema.sql migrate-v2.sql README.md plugin.json mcp.json .mcp.json; do
    cp "$project_dir/plugins/agentone-memory/$resource" "$plugin_resources/$resource"
done

cp -R "$project_dir/plugins/agentone-memory/.codex-plugin" "$project_dir/plugins/agentone-memory/skills" "$plugin_resources/"

cp "$project_dir/tools/laya-decision/worker.py" "$contents_dir/Resources/laya-worker.py"
cp "$project_dir/tools/voiceprint/worker.py" "$contents_dir/Resources/voiceprint-worker.py"
cp "$project_dir/tools/voiceprint/setup.py" "$contents_dir/Resources/voiceprint-setup.py"
cp "$project_dir/tools/voiceprint/voiceprint_policy.py" "$contents_dir/Resources/voiceprint_policy.py"

cat > "$contents_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AgentOne</string>
    <key>CFBundleIdentifier</key>
    <string>life.agentone.desktop</string>
    <key>CFBundleName</key>
    <string>AgentOne</string>
    <key>CFBundleDisplayName</key>
    <string>AgentOne</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSLocationUsageDescription</key>
    <string>AgentOne uses system location to automatically attach a place, accuracy and sample time to your local recordings and activity memory.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>AgentOne automatically adds your system location to local recording memory.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>AgentOne automatically mixes microphone input with system audio into one recording for your personal audio memory after you grant permission. You can pause automatic recording from the island.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>AgentOne automatically records system audio as local memory after you grant permission. You can pause automatic recording at any time.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>AgentOne uses on-device speech recognition only when you enable local transcription. Unsupported on-device recognition remains queued.</string>
    <key>NSScreenCaptureDescription</key>
    <string>AgentOne uses ScreenCaptureKit for local system audio. This version does not save screen video.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <false/>
    </dict>
</dict>
</plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$contents_dir/Info.plist"

# A distinct bundle identity keeps the headless worker out of the UI app's
# LaunchServices/Accessibility identity when the island exits and reopens.
cp "$contents_dir/Info.plist" "$recorder_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable AgentOneRecorder" "$recorder_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier life.agentone.recorder" "$recorder_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName AgentOneRecorder" "$recorder_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName AgentOne Recorder" "$recorder_app/Contents/Info.plist"

# Signing directly inside an iCloud Drive workspace is unreliable because the
# File Provider can immediately re-attach FinderInfo/resource-fork metadata to
# an .app directory. Build and sign in a clean local staging directory, then
# archive the verified bundle for transport back into the workspace.
xattr -cr "$app_dir"
signing_identity="${AGENTONE_SIGNING_IDENTITY:--}"
if [[ "$signing_identity" == "-" ]]; then
    codesign --force --sign - --requirements '=designated => identifier "life.agentone.recorder"' "$recorder_app" >/dev/null
    # An ordinary ad-hoc signature derives its designated requirement from the
    # executable CDHash. That hash changes on every build, so macOS TCC treats
    # each locally-built AgentOne as a different app and silently disconnects
    # Accessibility/Input Monitoring even while System Settings still shows an
    # older AgentOne entry as enabled. Keep the local-development requirement
    # stable across builds. Distribution builds should set
    # AGENTONE_SIGNING_IDENTITY to a real Developer ID identity instead.
    codesign \
        --force \
        --sign - \
        --requirements '=designated => identifier "life.agentone.desktop"' \
        "$app_dir" >/dev/null
else
    codesign --force --sign "$signing_identity" "$recorder_app" >/dev/null
    codesign --force --sign "$signing_identity" "$app_dir" >/dev/null
fi
codesign --verify --deep --strict "$app_dir"

mkdir -p "$build_dir"
rm -f "$archive_path"
COPYFILE_DISABLE=1 ditto -c -k --keepParent "$app_dir" "$archive_path"

echo "$archive_path"
