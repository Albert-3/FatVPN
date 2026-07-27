#!/usr/bin/env bash
# Builds the combined mobile core (sing-box + Xray) into the Android plugin.
#
# Replaces fetch_singbox_libbox_android.sh: the artifact keeps the same name and
# library name (`libbox`), so nothing on the Kotlin side changes, but it now also
# carries the Xray core for nodes sing-box cannot speak to. See tool/fatcore for
# why the two cores have to live in one library.
#
# Usage: tool/build_fatcore_android.sh [abi ...]      (default: every ABI shipped)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT_DIR/tool/fatcore"
OUT_DIR="${TMPDIR:-/tmp}/fatcore-android"
SINGBOX_REF="$(sed -n 's|^[[:space:]]*github.com/sagernet/sing-box \(v[^ ]*\).*|\1|p' "$CORE_DIR/go.mod" | head -n1)"

# The two cores are ~80 MB of native code per ABI, so each one shipped is paid
# for in download size. 32-bit x86 is left out: no device uses it and the
# emulator image here is x86_64. Which ABIs exist under jniLibs is what decides
# what gets packaged — `abiFilters` cannot be used for this, it conflicts with
# the `--split-per-abi` the release build relies on.
ABIS=("$@")
if [[ ${#ABIS[@]} -eq 0 ]]; then
  ABIS=(arm64-v8a armeabi-v7a x86_64)
fi

declare -A GOARCH_OF=(
  [arm64-v8a]=android/arm64
  [armeabi-v7a]=android/arm
  [x86_64]=android/amd64
  [x86]=android/386
)

command -v go >/dev/null 2>&1 || { echo "Go is required but not in PATH." >&2; exit 1; }

# gomobile shells out to javac at the very end, after every Go package has been
# compiled — a missing JDK there wastes the whole build. Android Studio's bundled
# runtime is the one machines here reliably have.
if ! command -v javac >/dev/null 2>&1; then
  for candidate in \
    "${JAVA_HOME:-}" \
    "/c/Program Files/Android/Android Studio/jbr" \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home"; do
    if [[ -n "$candidate" && -x "$candidate/bin/javac" ]]; then
      export JAVA_HOME="$candidate"
      export PATH="$JAVA_HOME/bin:$PATH"
      break
    fi
  done
fi
command -v javac >/dev/null 2>&1 || {
  echo "A JDK (javac) is required but not in PATH; set JAVA_HOME." >&2
  exit 1
}

export PATH="$(go env GOPATH)/bin:$PATH"
export GOPRIVATE="github.com/xtls/*"
export GOFLAGS=-mod=mod

echo "Installing gomobile tooling (sagernet fork, as sing-box requires)..."
go install github.com/sagernet/gomobile/cmd/gomobile@latest
go install github.com/sagernet/gomobile/cmd/gobind@latest
gomobile init

TARGETS=""
for abi in "${ABIS[@]}"; do
  target="${GOARCH_OF[$abi]:-}"
  [[ -n "$target" ]] || { echo "Unknown ABI: $abi" >&2; exit 1; }
  TARGETS+="${TARGETS:+,}$target"
done

# Tags and flags carried over verbatim from the sing-box build they replace —
# dropping one silently removes a protocol from the shipped core.
TAGS="with_gvisor,with_quic,with_wireguard,with_utls,with_grpc,with_naive_outbound,with_clash_api,with_conntrack,badlinkname,tfogo_checklinkname0,with_tailscale,ts_omit_logtail,ts_omit_ssh,ts_omit_drive,ts_omit_taildrop,ts_omit_webclient,ts_omit_doctor,ts_omit_capture,ts_omit_kube,ts_omit_aws,ts_omit_synology,ts_omit_bird"
LD_FLAGS="-X github.com/sagernet/sing-box/constant.Version=$SINGBOX_REF -X internal/godebug.defaultGODEBUG=multipathtcp=0 -s -w -buildid= -checklinkname=0"

mkdir -p "$OUT_DIR"
AAR_FILE="$OUT_DIR/libbox.aar"
rm -f "$AAR_FILE"

echo "Building $TARGETS (sing-box $SINGBOX_REF + Xray)..."
(
  cd "$CORE_DIR"
  gomobile bind \
    -v \
    -o "$AAR_FILE" \
    -target "$TARGETS" \
    -androidapi 23 \
    -javapkg=io.nekohasekai \
    -libname=box \
    -trimpath \
    -buildvcs=false \
    -ldflags "$LD_FLAGS" \
    -tags "$TAGS" \
    github.com/sagernet/sing-box/experimental/libbox \
    ./fatxray
)

[[ -f "$AAR_FILE" ]] || { echo "libbox.aar was not produced." >&2; exit 1; }

echo "Syncing Android plugin artifacts..."
mkdir -p "$ROOT_DIR/android/libs"
unzip -p "$AAR_FILE" classes.jar > "$ROOT_DIR/android/libs/libbox.jar"

for abi in "${ABIS[@]}"; do
  plugin_out="$ROOT_DIR/android/src/main/jniLibs/${abi}"
  mkdir -p "$plugin_out"
  unzip -p "$AAR_FILE" "jni/${abi}/libbox.so" > "$plugin_out/libbox.so"
  echo "Synced ABI ${abi}"
done

echo "Verifying Android native page-size alignment..."
"$ROOT_DIR/tool/check_android_page_size.sh"

echo "Done. Cores in this build:"
unzip -l "$AAR_FILE" | sed -n 's|.*classes.jar.*|classes.jar|p' >/dev/null
echo "- io.nekohasekai.libbox.*  (sing-box $SINGBOX_REF)"
echo "- io.nekohasekai.fatxray.* (Xray)"
