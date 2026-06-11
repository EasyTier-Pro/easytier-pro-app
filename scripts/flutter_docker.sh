#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cache_root="${EASYTIER_ANDROID_DOCKER_CACHE:-/data/project/.cache/easytier-pro-app}"
gradle_home="${EASYTIER_GRADLE_USER_HOME:-$cache_root/gradle-home}"
pub_cache="${EASYTIER_PUB_CACHE:-$cache_root/pub-cache}"
ndk_cache="${EASYTIER_ANDROID_NDK_CACHE:-$cache_root/android-sdk/ndk}"
cmake_cache="${EASYTIER_ANDROID_CMAKE_CACHE:-$cache_root/android-sdk/cmake}"
android_temp_cache="${EASYTIER_ANDROID_TEMP_CACHE:-$cache_root/android-sdk/temp}"
image="${EASYTIER_FLUTTER_DOCKER_IMAGE:-ghcr.io/cirruslabs/flutter:stable}"
gradle_distribution="${EASYTIER_GRADLE_DISTRIBUTION:-bin}"

usage() {
  cat <<'EOF'
Usage:
  scripts/flutter_docker.sh <command> [args...]

Examples:
  scripts/flutter_docker.sh flutter pub get
  scripts/flutter_docker.sh flutter test test/widget_test.dart
  scripts/flutter_docker.sh flutter build apk --debug

Environment:
  EASYTIER_ANDROID_DOCKER_CACHE   Host cache root. Defaults to /data/project/.cache/easytier-pro-app.
  EASYTIER_FLUTTER_DOCKER_IMAGE   Flutter image. Defaults to ghcr.io/cirruslabs/flutter:stable.
  EASYTIER_GRADLE_DISTRIBUTION    bin or all. Defaults to bin for smaller Gradle downloads.
  EASYTIER_ANDROID_NDK_CACHE      Host Android NDK cache directory.
  EASYTIER_ANDROID_CMAKE_CACHE    Host Android CMake cache directory.
  EASYTIER_ANDROID_TEMP_CACHE     Host Android SDK temporary download directory.
EOF
}

if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mkdir -p "$gradle_home" "$pub_cache" "$ndk_cache" "$cmake_cache" "$android_temp_cache"

tmp_wrapper=""
wrapper_mount_args=()
case "$gradle_distribution" in
  bin)
    tmp_wrapper="$(mktemp)"
    sed \
      's#gradle-\([0-9][^/]*\)-all\.zip#gradle-\1-bin.zip#g' \
      "$repo_root/android/gradle/wrapper/gradle-wrapper.properties" \
      >"$tmp_wrapper"
    wrapper_mount_args=(
      -v "$tmp_wrapper:/workspace/android/gradle/wrapper/gradle-wrapper.properties:ro"
    )
    ;;
  all)
    ;;
  *)
    echo "EASYTIER_GRADLE_DISTRIBUTION must be 'bin' or 'all'." >&2
    exit 2
    ;;
esac

cleanup() {
  if [[ -n "$tmp_wrapper" ]]; then
    rm -f "$tmp_wrapper"
  fi
}
trap cleanup EXIT

docker run --rm \
  -v "$repo_root:/workspace" \
  -v "$gradle_home:/gradle-home" \
  -v "$pub_cache:/pub-cache" \
  -v "$ndk_cache:/opt/android-sdk-linux/ndk" \
  -v "$cmake_cache:/opt/android-sdk-linux/cmake" \
  -v "$android_temp_cache:/opt/android-sdk-linux/.temp" \
  -e GRADLE_USER_HOME=/gradle-home \
  -e PUB_CACHE=/pub-cache \
  -w /workspace \
  "${wrapper_mount_args[@]}" \
  "$image" \
  "$@"
