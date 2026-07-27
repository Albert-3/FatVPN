#!/usr/bin/env bash
# iOS counterpart of build_fatcore_android.sh: builds the combined core
# (sing-box + Xray) as Libbox.xcframework.
#
# Replaces fetch_singbox_libbox_ios.sh. The framework keeps its name so nothing
# in the Xcode wiring changes, but it now also exports the Xray bridge, which
# the Network Extension needs for nodes on Xray's XHTTP transport.
#
# The two cores must be in one framework, not two. Each gomobile/cgo build is a
# static Go archive that defines the Go runtime's symbols; linking two of them
# into one binary fails on duplicate symbols, and an .appex is one binary.
#
# Must run on a machine with Xcode — there is no local Mac on this project, so
# this only ever runs on the Codemagic mac_mini_m2 runner.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT_DIR/tool/fatcore"
SINGBOX_REF="$(sed -n 's|^[[:space:]]*github.com/sagernet/sing-box \(v[^ ]*\).*|\1|p' "$CORE_DIR/go.mod" | head -n1)"

command -v go >/dev/null 2>&1 || { echo "Go is required but not in PATH." >&2; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || {
  echo "xcodebuild is required (this script only runs on macOS/Xcode)." >&2
  exit 1
}

export PATH="$(go env GOPATH)/bin:$PATH"
export GOPRIVATE="github.com/xtls/*"
export GOFLAGS=-mod=mod

echo "Installing gomobile tooling..."
go install -v github.com/sagernet/gomobile/cmd/gomobile@latest
go install -v github.com/sagernet/gomobile/cmd/gobind@latest
gomobile init

# Same feature set as the Android build for parity. If the iOS build fails on
# one of these tags, trim here first — with_gvisor/with_tailscale are the most
# likely offenders on iOS toolchains.
TAGS="with_gvisor,with_quic,with_wireguard,with_utls,with_grpc,with_naive_outbound,with_clash_api,with_conntrack,badlinkname,tfogo_checklinkname0,with_tailscale,ts_omit_logtail,ts_omit_ssh,ts_omit_drive,ts_omit_taildrop,ts_omit_webclient,ts_omit_doctor,ts_omit_capture,ts_omit_kube,ts_omit_aws,ts_omit_synology,ts_omit_bird"
LD_FLAGS="-X github.com/sagernet/sing-box/constant.Version=$SINGBOX_REF -X internal/godebug.defaultGODEBUG=multipathtcp=0 -s -w -buildid= -checklinkname=0"
OUT_DIR="$ROOT_DIR/ios/Frameworks"
XCFRAMEWORK="$OUT_DIR/Libbox.xcframework"

echo "Building Libbox.xcframework (sing-box $SINGBOX_REF + Xray)..."
mkdir -p "$OUT_DIR"
rm -rf "$XCFRAMEWORK"
(
  cd "$CORE_DIR"
  gomobile bind \
    -v \
    -o "$XCFRAMEWORK" \
    -target ios,iossimulator \
    -trimpath \
    -buildvcs=false \
    -ldflags "$LD_FLAGS" \
    -tags "$TAGS" \
    github.com/sagernet/sing-box/experimental/libbox \
    ./fatxray
)

[[ -d "$XCFRAMEWORK" ]] || { echo "Libbox.xcframework was not produced." >&2; exit 1; }

echo "Done."
echo "- Libbox.xcframework written to $XCFRAMEWORK"
echo "- Exports LibboxXxx (sing-box $SINGBOX_REF) and FatxrayXxx (Xray)"
du -sh "$XCFRAMEWORK"
