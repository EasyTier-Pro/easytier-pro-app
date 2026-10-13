#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname)" != Darwin ]]; then
  echo "build_ios_core.sh requires macOS and Xcode" >&2
  exit 1
fi

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_REVISION="$(tr -d '\n' < "$APP_ROOT/scripts/ios_core_revision")"
CORE_REPO="${EASYTIER_REPO:-$APP_ROOT/build/ios-core-source}"
if [[ ! -e "$CORE_REPO/.git" ]]; then
  mkdir -p "$CORE_REPO"
  git -C "$CORE_REPO" init
  git -C "$CORE_REPO" remote add origin https://github.com/EasyTier/EasyTier.git
  git -C "$CORE_REPO" fetch --depth=1 origin "$CORE_REVISION"
  git -C "$CORE_REPO" checkout --detach FETCH_HEAD
fi
if [[ "$(git -C "$CORE_REPO" rev-parse HEAD)" != "$CORE_REVISION" ]]; then
  echo "EasyTier checkout must match scripts/ios_core_revision ($CORE_REVISION)" >&2
  exit 1
fi
if [[ -n "$(git -C "$CORE_REPO" status --porcelain --untracked-files=no)" ]]; then
  echo "EasyTier tracked sources must be clean" >&2
  exit 1
fi

# The app carries the event bridge until its core changes are available in an
# upstream revision. Keep the pinned base clean and patch only this derived
# checkout, retaining its target cache across builds.
PATCHED_REPO="$APP_ROOT/build/ios-core-patched-source"
APPLIED_PATCH="$APP_ROOT/build/ios-core-applied.patch"
if [[ ! -e "$PATCHED_REPO/.git" ]]; then
  git -C "$CORE_REPO" worktree add --detach "$PATCHED_REPO" "$CORE_REVISION"
fi
if [[ "$(git -C "$PATCHED_REPO" rev-parse HEAD)" != "$CORE_REVISION" ]]; then
  echo "Derived iOS core checkout has an unexpected revision" >&2
  exit 1
fi
if [[ -n "$(git -C "$PATCHED_REPO" status --porcelain --untracked-files=no)" ]]; then
  if [[ ! -f "$APPLIED_PATCH" ]] || ! git -C "$PATCHED_REPO" diff HEAD --binary | cmp -s - "$APPLIED_PATCH"; then
    echo "Derived iOS core checkout contains unexpected changes" >&2
    exit 1
  fi
  git -C "$PATCHED_REPO" reset --hard "$CORE_REVISION"
fi
git -C "$PATCHED_REPO" apply --check --index "$APP_ROOT/scripts/ios_core.patch"
git -C "$PATCHED_REPO" apply --index "$APP_ROOT/scripts/ios_core.patch"
git -C "$PATCHED_REPO" diff HEAD --binary > "$APPLIED_PATCH"
cd "$PATCHED_REPO"
export IPHONEOS_DEPLOYMENT_TARGET=13.0
# Xcode and rustc may ship different LLVM versions. Emit native objects for
# Apple's linker instead of passing Rust LLVM bitcode through the XCFramework.
export CARGO_PROFILE_RELEASE_LTO=false
CLANG_RT_DIR="$(xcrun clang -print-resource-dir)/lib/darwin"
DEVICE_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
OUTPUT="$APP_ROOT/ios/Frameworks"
STAGING="$APP_ROOT/build/ios-core-packaging"
mkdir -p "$OUTPUT" "$STAGING/headers" "$STAGING/iphoneos" "$STAGING/iphonesimulator"
cp "$APP_ROOT/ios/PacketTunnel/EasyTierCore.h" "$STAGING/headers/"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

SDKROOT="$DEVICE_SDK" \
RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-L$CLANG_RT_DIR -C link-arg=-lclang_rt.ios" \
  cargo build --locked -p easytier-ios --release --target aarch64-apple-ios
SDKROOT="$SIM_SDK" \
BINDGEN_EXTRA_CLANG_ARGS="--target=arm64-apple-ios13.0-simulator -isysroot $SIM_SDK" \
  RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-L$CLANG_RT_DIR -C link-arg=-lclang_rt.iossim" \
  cargo build --locked -p easytier-ios --release --target aarch64-apple-ios-sim

cp target/aarch64-apple-ios/release/libeasytier_ios.a "$STAGING/iphoneos/"
cp target/aarch64-apple-ios-sim/release/libeasytier_ios.a "$STAGING/iphonesimulator/"
# Include compiler-rt's stack probe implementation in each static slice.
libtool -static -arch_only arm64 -o "$STAGING/iphoneos/libEasyTierCore.a" \
  "$STAGING/iphoneos/libeasytier_ios.a" "$CLANG_RT_DIR/libclang_rt.ios.a"
libtool -static -arch_only arm64 -o "$STAGING/iphonesimulator/libEasyTierCore.a" \
  "$STAGING/iphonesimulator/libeasytier_ios.a" "$CLANG_RT_DIR/libclang_rt.iossim.a"
rm -rf "$OUTPUT/EasyTierCore.xcframework"
xcodebuild -create-xcframework \
  -library "$STAGING/iphoneos/libEasyTierCore.a" -headers "$STAGING/headers" \
  -library "$STAGING/iphonesimulator/libEasyTierCore.a" -headers "$STAGING/headers" \
  -output "$OUTPUT/EasyTierCore.xcframework"
CORE_VERSION="$(sed -n 's/^version = "\([^"]*\)"/\1/p' easytier/Cargo.toml | head -1)"
printf 'EASYTIER_CORE_VERSION = %s\n' "$CORE_VERSION" > "$OUTPUT/CoreVersion.xcconfig"
printf '%s\n' "$CORE_REVISION" > "$OUTPUT/core-revision.txt"
shasum -a 256 "$APP_ROOT/scripts/ios_core.patch" | awk '{print $1}' > "$OUTPUT/core-patch.sha256"
