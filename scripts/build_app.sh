#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
configuration="${1:-debug}"
# A single product version feeds local bundles, CI artifacts and release tags.
app_version="$(cd "$project_dir/AgentOneLifeRuntime" && node -p 'require("./package.json").version')"
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
swift build -c "$configuration"

binary_path="$(swift build -c "$configuration" --show-bin-path)/AgentOne"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$binary_path" "$contents_dir/MacOS/AgentOne"

# SwiftPM resource bundle (LifeForm artwork etc.) must ship inside the .app,
# otherwise Bundle.module lookups fail at runtime.
resource_bundle="$(swift build -c "$configuration" --show-bin-path)/AgentOne_AgentOneApp.bundle"
if [[ -d "$resource_bundle" ]]; then
    cp -R "$resource_bundle" "$contents_dir/Resources/"
fi

life_runtime_source="$project_dir/AgentOneLifeRuntime/src/index.ts"
life_runtime_resources="$contents_dir/Resources/AgentOneLifeRuntime"
if [[ -f "$life_runtime_source" ]] && command -v deno >/dev/null 2>&1; then
    if [[ ! -d "$project_dir/AgentOneLifeRuntime/node_modules/@earendil-works/pi-agent-core" ]]; then
        echo "AgentOneLifeRuntime dependencies are missing. Run npm install in AgentOneLifeRuntime." >&2
        exit 1
    fi
    mkdir -p "$life_runtime_resources"
    deno compile \
        --quiet \
        --no-check \
        --sloppy-imports \
        --node-modules-dir=manual \
        --allow-env=AGENTONE_MODEL_ROUTE,AGENTONE_MODEL_PROVIDER,AGENTONE_OLLAMA_BASE_URL,AGENTONE_KIMI_ACCESS_TOKEN,AGENTONE_KIMI_BASE_URL,AGENTONE_KIMI_PLATFORM,AGENTONE_KIMI_VERSION,AGENTONE_KIMI_DEVICE_NAME,AGENTONE_KIMI_DEVICE_MODEL,AGENTONE_KIMI_OS_VERSION,AGENTONE_KIMI_DEVICE_ID,OPENAI_API_KEY,AGENTONE_MODEL_ID,AGENTONE_OPENAI_BASE_URL,AGENTONE_PI_PROTOCOL_VERSION,PI_CACHE_RETENTION,OPENAI_BASE_URL,OPENAI_ORG_ID,OPENAI_PROJECT_ID,OPENAI_WEBHOOK_SECRET,OPENAI_LOG,ANTHROPIC_LOG,HTTP_PROXY,HTTPS_PROXY,http_proxy,https_proxy \
        --allow-net \
        --output "$life_runtime_resources/agentone-life-runtime" \
        "$life_runtime_source"
elif [[ -f "$life_runtime_source" ]]; then
    echo "Deno is required to create the self-contained Pi sidecar." >&2
    exit 1
fi

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
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSAppleEventsUsageDescription</key>
    <string>AgentOne uses app context only when you enable it, so it can understand and restore your current task.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>AgentOne uses the microphone only during a conversation mode you explicitly start.</string>
    <key>NSScreenCaptureDescription</key>
    <string>AgentOne captures selected key moments for your private daily replay when you grant permission.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <false/>
        <key>NSExceptionDomains</key>
        <dict>
            <key>algoagent.zhuaninc.com</key>
            <dict>
                <key>NSIncludesSubdomains</key>
                <false/>
                <key>NSTemporaryExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$contents_dir/Info.plist"

# Signing directly inside an iCloud Drive workspace is unreliable because the
# File Provider can immediately re-attach FinderInfo/resource-fork metadata to
# an .app directory. Build and sign in a clean local staging directory, then
# archive the verified bundle for transport back into the workspace.
xattr -cr "$app_dir"
signing_identity="${AGENTONE_SIGNING_IDENTITY:--}"
if [[ "$signing_identity" == "-" ]]; then
    # An ordinary ad-hoc signature derives its designated requirement from the
    # executable CDHash. That hash changes on every build, so macOS TCC treats
    # each locally-built AgentOne as a different app and silently disconnects
    # Accessibility/Input Monitoring even while System Settings still shows an
    # older AgentOne entry as enabled. Keep the local-development requirement
    # stable across builds. Distribution builds should set
    # AGENTONE_SIGNING_IDENTITY to a real Developer ID identity instead.
    codesign \
        --force \
        --deep \
        --sign - \
        --requirements '=designated => identifier "life.agentone.desktop"' \
        "$app_dir" >/dev/null
else
    codesign --force --deep --sign "$signing_identity" "$app_dir" >/dev/null
fi
codesign --verify --deep --strict "$app_dir"

mkdir -p "$build_dir"
rm -f "$archive_path"
COPYFILE_DISABLE=1 ditto -c -k --keepParent "$app_dir" "$archive_path"

echo "$archive_path"
