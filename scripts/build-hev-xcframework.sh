#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export COPYFILE_DISABLE=1
export ZERO_AR_DATE=1
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT/Vendor"
BUILD_ROOT="$VENDOR_DIR/.build"
SOURCE_DIR="$BUILD_ROOT/hev-socks5-server"
STAGING_DIR="$BUILD_ROOT/apple"
OUTPUT="$VENDOR_DIR/HevSocks5Server.xcframework"
NOTICE_DIR="$ROOT/ThirdPartyNotices"
MANIFEST="$NOTICE_DIR/HevSocks5Server.provenance.json"

SERVER_URL="https://github.com/heiher/hev-socks5-server.git"
SERVER_TAG="2.12.0"
SERVER_SHA="b6287389b426895e9791474ca02375f3e434bda2"
TASK_SHA="8d83bbbf79557138726c8ee5a5fae99cbb978d61"
YAML_SHA="162227cd7d2b6108bc8bc133273e11413222ddf4"
CORE_SHA="4be2e621813ba0315cfacd995bf501bde91d6996"
MIN_IOS="17.0"

fail() {
    printf 'HEV build failed: %s\n' "$1" >&2
    exit 1
}

verify_revision() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(git -C "$path" rev-parse HEAD)"
    if [[ "$actual" != "$expected" ]]; then
        fail "revision mismatch for $path: expected $expected, got $actual"
    fi
}

safe_remove() {
    local path="$1"
    case "$path" in
        "$VENDOR_DIR"/*) rm -rf "$path" ;;
        *) fail "refusing to remove path outside Vendor" ;;
    esac
}

build_arch() {
    local sdk="$1"
    local arch="$2"
    local min_flag="-m${sdk}-version-min=${MIN_IOS}"
    local output_dir="$STAGING_DIR/${sdk}-${arch}"

    make -C "$SOURCE_DIR" clean >/dev/null
    make -C "$SOURCE_DIR" \
        PP="xcrun --sdk $sdk clang" \
        CC="xcrun --sdk $sdk clang" \
        AR="xcrun --sdk $sdk ar" \
        CFLAGS="-arch $arch $min_flag" \
        LFLAGS="-arch $arch $min_flag" \
        static

    install -d "$output_dir"
    xcrun libtool -static -o "$output_dir/libhev-socks5-server.a" \
        "$SOURCE_DIR/bin/libhev-socks5-server.a" \
        "$SOURCE_DIR/third-part/yaml/bin/libyaml.a" \
        "$SOURCE_DIR/third-part/hev-task-system/bin/libhev-task-system.a"
    make -C "$SOURCE_DIR" clean >/dev/null
}

merge_simulator_archives() {
    local output_dir="$STAGING_DIR/iphonesimulator-arm64-x86_64"
    install -d "$output_dir"
    xcrun lipo -create \
        "$STAGING_DIR/iphonesimulator-arm64/libhev-socks5-server.a" \
        "$STAGING_DIR/iphonesimulator-x86_64/libhev-socks5-server.a" \
        -output "$output_dir/libhev-socks5-server.a"
}

verify_archive_metadata() {
    local library="$1"
    local expected_platform="$2"
    local metadata
    local build_count
    local platform_count
    local minos_count

    metadata="$(xcrun otool -l "$library")"
    build_count="$(grep -c 'cmd LC_BUILD_VERSION' <<< "$metadata" || true)"
    platform_count="$(grep -c "platform $expected_platform" <<< "$metadata" || true)"
    minos_count="$(grep -c "minos $MIN_IOS" <<< "$metadata" || true)"
    [[ "$build_count" -gt 0 ]] || fail "missing LC_BUILD_VERSION metadata"
    [[ "$platform_count" -eq "$build_count" ]] || fail "unexpected platform metadata"
    [[ "$minos_count" -eq "$build_count" ]] || fail "unexpected minimum OS metadata"
}

safe_remove "$SOURCE_DIR"
safe_remove "$STAGING_DIR"
safe_remove "$OUTPUT"
install -d "$BUILD_ROOT" "$STAGING_DIR" "$NOTICE_DIR"

git clone --recursive --branch "$SERVER_TAG" --depth 1 --shallow-submodules "$SERVER_URL" "$SOURCE_DIR"
verify_revision "$SOURCE_DIR" "$SERVER_SHA"
verify_revision "$SOURCE_DIR/third-part/hev-task-system" "$TASK_SHA"
verify_revision "$SOURCE_DIR/third-part/yaml" "$YAML_SHA"
verify_revision "$SOURCE_DIR/src/core" "$CORE_SHA"

source_epoch="$(git -C "$SOURCE_DIR" show -s --format=%ct HEAD)"
export SOURCE_DATE_EPOCH="$source_epoch"

build_arch iphoneos arm64
build_arch iphonesimulator arm64
build_arch iphonesimulator x86_64
merge_simulator_archives

headers="$STAGING_DIR/include"
install -d "$headers"
install -m 0644 "$SOURCE_DIR/src/hev-main.h" "$headers/hev-main.h"
install -m 0644 "$SOURCE_DIR/module.modulemap" "$headers/module.modulemap"

xcodebuild -create-xcframework \
    -library "$STAGING_DIR/iphoneos-arm64/libhev-socks5-server.a" -headers "$headers" \
    -library "$STAGING_DIR/iphonesimulator-arm64-x86_64/libhev-socks5-server.a" -headers "$headers" \
    -output "$OUTPUT"

device_library="$OUTPUT/ios-arm64/libhev-socks5-server.a"
simulator_library="$OUTPUT/ios-arm64_x86_64-simulator/libhev-socks5-server.a"
[[ -f "$device_library" ]] || fail "device XCFramework slice is missing"
[[ -f "$simulator_library" ]] || fail "simulator XCFramework slice is missing"

if [[ "$(xcrun lipo -archs "$device_library")" != "arm64" ]]; then
    fail "unexpected device architectures"
fi
simulator_archs="$(xcrun lipo -archs "$simulator_library")"
[[ "$simulator_archs" == *"arm64"* && "$simulator_archs" == *"x86_64"* ]] || fail "unexpected simulator architectures"
verify_archive_metadata "$device_library" 2
verify_archive_metadata "$simulator_library" 7

install -m 0644 "$SOURCE_DIR/LICENSE" "$NOTICE_DIR/HevSocks5Server.txt"
install -m 0644 "$SOURCE_DIR/third-part/hev-task-system/LICENSE" "$NOTICE_DIR/HevTaskSystem.txt"
install -m 0644 "$SOURCE_DIR/third-part/yaml/License" "$NOTICE_DIR/Yaml.txt"
install -m 0644 "$SOURCE_DIR/src/core/LICENSE" "$NOTICE_DIR/HevSocks5Core.txt"

file_hashes="$BUILD_ROOT/xcframework-files.sha256"
: > "$file_hashes"
while IFS= read -r file; do
    relative="${file#"$OUTPUT"/}"
    read -r digest _ < <(shasum -a 256 "$file")
    printf '%s  %s\n' "$digest" "$relative" >> "$file_hashes"
done < <(find "$OUTPUT" -type f -print | sort)
read -r artifact_digest _ < <(shasum -a 256 "$file_hashes")
read -r device_digest _ < <(shasum -a 256 "$device_library")
read -r simulator_digest _ < <(shasum -a 256 "$simulator_library")

xcode_version="$(xcodebuild -version | paste -sd ';' -)"
clang_output="$(xcrun clang --version)"
clang_version="${clang_output%%$'\n'*}"
iphoneos_sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"

printf '%s\n' \
    '{' \
    '  "artifact": {' \
    '    "digestMethod": "SHA-256 of sorted relative-path file SHA-256 manifest",' \
    "    \"sha256\": \"$artifact_digest\"," \
    '    "slices": [' \
    "      {\"platform\": \"iOS\", \"architectures\": [\"arm64\"], \"minimumOS\": \"$MIN_IOS\", \"librarySHA256\": \"$device_digest\"}," \
    "      {\"platform\": \"iOS Simulator\", \"architectures\": [\"arm64\", \"x86_64\"], \"minimumOS\": \"$MIN_IOS\", \"librarySHA256\": \"$simulator_digest\"}" \
    '    ]' \
    '  },' \
    '  "source": {' \
    "    \"hev-socks5-server\": {\"url\": \"$SERVER_URL\", \"tag\": \"$SERVER_TAG\", \"revision\": \"$SERVER_SHA\"}," \
    "    \"hev-task-system\": {\"revision\": \"$TASK_SHA\"}," \
    "    \"yaml\": {\"revision\": \"$YAML_SHA\"}," \
    "    \"hev-socks5-core\": {\"revision\": \"$CORE_SHA\"}" \
    '  },' \
    '  "toolchain": {' \
    "    \"xcode\": \"$xcode_version\"," \
    "    \"clang\": \"$clang_version\"," \
    "    \"iphoneOSSDK\": \"$iphoneos_sdk\"," \
    "    \"iPhoneSimulatorSDK\": \"$simulator_sdk\"" \
    '  }' \
    '}' > "$MANIFEST"

printf 'Built %s\n' "$OUTPUT"
printf 'XCFramework SHA-256: %s\n' "$artifact_digest"
