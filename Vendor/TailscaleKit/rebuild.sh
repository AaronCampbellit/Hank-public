#!/bin/sh
set -eu

# Optional development output only; not linked by Hank. See UPSTREAM.md for
# provenance, dependency/security review, and redistribution requirements.

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/hank-libtailscale-build"
UPSTREAM_REPO="https://github.com/tailscale/libtailscale.git"
UPSTREAM_COMMIT="5e89501def80a6579ca5d0f9a02f336be62b8f2e"

rm -rf "$WORK_DIR"
git clone "$UPSTREAM_REPO" "$WORK_DIR"
cd "$WORK_DIR"
git checkout "$UPSTREAM_COMMIT"
python3 - <<'PY'
from pathlib import Path

path = Path("swift/TailscaleKit/TailscaleError.swift")
source = path.read_text()
source = source.replace(
    "return .posixError( POSIXError(code))",
    "return .posixError(POSIXError(code), details)"
)
source = source.replace(
    "static let kMaxErrorMessageLength: Int = 256",
    "static let kMaxErrorMessageLength: Int = 4096"
)
source = source.replace(
    "let res = tailscale_errmsg(self, buf, 256)",
    "let res = tailscale_errmsg(self, buf, Self.kMaxErrorMessageLength)"
)
path.write_text(source)
PY

cd "$WORK_DIR/swift"
make ios-fat

rm -rf "$ROOT_DIR/Vendor/TailscaleKit/TailscaleKit.xcframework"
cp -R \
  "$WORK_DIR/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework" \
  "$ROOT_DIR/Vendor/TailscaleKit/TailscaleKit.xcframework"

echo "Rebuilt TailscaleKit.xcframework from $UPSTREAM_COMMIT"
