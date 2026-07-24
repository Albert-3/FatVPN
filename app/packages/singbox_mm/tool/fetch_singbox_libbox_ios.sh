#!/usr/bin/env bash
set -euo pipefail

# iOS counterpart of fetch_singbox_libbox_android.sh: builds Libbox.xcframework
# from the same sing-box source/ref via `gomobile bind -target ios,iossimulator`
# instead of `-target android`. Must run on a machine with Xcode installed
# (Codemagic mac_mini_m2 runner) — there is no local Mac available for this
# project, so this script is only ever exercised in CI.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${TMPDIR:-/tmp}/signbox_singbox_libbox_ios"
SRC_DIR="$TMP_DIR/sing-box"
REF="${SINGBOX_REF:-v1.13.11}"

command -v go >/dev/null 2>&1 || {
  echo "Go is required but not found in PATH." >&2
  exit 1
}

command -v xcodebuild >/dev/null 2>&1 || {
  echo "xcodebuild is required but not found in PATH (this script only runs on macOS/Xcode)." >&2
  exit 1
}

GO_BIN_DIR="$(go env GOPATH)/bin"
PATH="$GO_BIN_DIR:$PATH"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

if [[ "$REF" == "latest" ]]; then
  RELEASE_JSON="$TMP_DIR/release.json"
  curl -sL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" > "$RELEASE_JSON"
  REF="$(grep -o '"tag_name":[[:space:]]*"[^"]*"' "$RELEASE_JSON" | head -n1 | cut -d'"' -f4)"
fi

if [[ -z "$REF" ]]; then
  echo "Unable to resolve sing-box release tag." >&2
  exit 1
fi

echo "Using sing-box ref: $REF"
echo "Installing gomobile tooling..."
go install -v github.com/sagernet/gomobile/cmd/gomobile@latest
go install -v github.com/sagernet/gomobile/cmd/gobind@latest
gomobile init

echo "Cloning sing-box source..."
git clone --depth 1 --branch "$REF" "https://github.com/SagerNet/sing-box" "$SRC_DIR"

# Same feature set as the Android build (fetch_singbox_libbox_android.sh) for
# parity. If the iOS build fails on one of these tags, trim here first —
# with_gvisor/with_tailscale are the most likely offenders on iOS toolchains.
TAGS="with_gvisor,with_quic,with_wireguard,with_utls,with_grpc,with_naive_outbound,with_clash_api,with_conntrack,badlinkname,tfogo_checklinkname0,with_tailscale,ts_omit_logtail,ts_omit_ssh,ts_omit_drive,ts_omit_taildrop,ts_omit_webclient,ts_omit_doctor,ts_omit_capture,ts_omit_kube,ts_omit_aws,ts_omit_synology,ts_omit_bird"
LD_FLAGS="-X github.com/sagernet/sing-box/constant.Version=$REF -X internal/godebug.defaultGODEBUG=multipathtcp=0 -s -w -buildid= -checklinkname=0"
OUT_DIR="$ROOT_DIR/ios/Frameworks"
XCFRAMEWORK="$OUT_DIR/Libbox.xcframework"

echo "Building Libbox.xcframework from official source..."
mkdir -p "$OUT_DIR"
rm -rf "$XCFRAMEWORK"
(
  cd "$SRC_DIR"
  gomobile bind \
    -v \
    -o "$XCFRAMEWORK" \
    -target ios,iossimulator \
    -trimpath \
    -buildvcs=false \
    -ldflags "$LD_FLAGS" \
    -tags "$TAGS" \
    ./experimental/libbox
)

if [[ ! -d "$XCFRAMEWORK" ]]; then
  echo "Libbox.xcframework was not produced." >&2
  exit 1
fi

# Tried `strip -S` here to shrink the archive — it made zero difference.
# Go's debug info (gopclntab, DWARF) isn't stored in traditional Mach-O
# symbol tables, so macOS's strip doesn't touch it; `-ldflags "-s -w"`
# (already passed to gomobile bind above) only affects a *final* linked
# binary, not an intermediate static archive meant to be linked later by
# Xcode. ~300MB combined (both slices) is apparently just the real size of
# sing-box + tailscale + gvisor + cronet(quic) statically linked for arm64 —
# shrinking it further means trimming build tags (with_tailscale is the
# most likely candidate, if it turns out unused), a feature-scope decision
# separate from packaging hygiene.
echo "Done."
echo "- Libbox.xcframework written to $XCFRAMEWORK"
du -sh "$XCFRAMEWORK"
