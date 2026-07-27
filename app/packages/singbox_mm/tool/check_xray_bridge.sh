#!/usr/bin/env bash
# Fails unless the committed Libbox.xcframework carries the Xray bridge.
#
# The framework in the repository is a build artifact: it is produced on a Mac
# by build_fatcore_ios.sh (workflow `ios-libbox-xcframework`), downloaded, and
# committed into Git LFS. So it can lag the Go module behind it — and did, from
# the day the second core was written until the framework was rebuilt.
#
# Without this check that mismatch surfaces as a Swift compile error deep in the
# PacketTunnel target ("cannot find 'FatxrayStart' in scope"), which reads like
# a code bug rather than a stale binary. Run it right after `git lfs pull`.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCFRAMEWORK="$ROOT_DIR/ios/Frameworks/Libbox.xcframework"

if [[ ! -d "$XCFRAMEWORK" ]]; then
  echo "Libbox.xcframework is missing at $XCFRAMEWORK." >&2
  exit 1
fi

# An LFS pointer left unresolved is a ~130-byte text file where a binary should
# be, and every later error it causes is misleading. Catch it here.
if grep -qs "^version https://git-lfs" "$XCFRAMEWORK"/*/Libbox.framework/Versions/A/Libbox; then
  echo "Libbox.xcframework still holds Git LFS pointers — 'git lfs pull' did" >&2
  echo "not run, or ran without credentials." >&2
  exit 1
fi

if ! grep -rq --include='*.h' "FatxrayStart" "$XCFRAMEWORK"; then
  cat >&2 <<'MSG'
Libbox.xcframework has no Xray bridge (FatxrayStart is absent from its headers).

It predates the second core, so the PacketTunnel target cannot compile against
it. Rebuild it:

  1. run the `ios-libbox-xcframework` workflow in Codemagic
  2. download Libbox.xcframework.zip from its artifacts
  3. unzip over app/packages/singbox_mm/ios/Frameworks/
  4. commit it (the binaries are tracked in Git LFS — see .gitattributes)
MSG
  exit 1
fi

echo "Libbox.xcframework carries both cores (sing-box + Xray)."
