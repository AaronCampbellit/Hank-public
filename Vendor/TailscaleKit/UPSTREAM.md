# Optional TailscaleKit rebuild

The current Hank app does not import or link TailscaleKit. No XCFramework binary
is distributed in this source tree. These instructions preserve an optional
future development path; running the script does not enable it in the app.

Upstream repository: https://github.com/tailscale/libtailscale
Pinned commit: 5e89501def80a6579ca5d0f9a02f336be62b8f2e
Local patch: applied by `rebuild.sh`
Purpose: preserve libtailscale error detail text for known POSIX errors and increase the Swift wrapper error buffer to 4096 bytes.

Rebuild with:
./Vendor/TailscaleKit/rebuild.sh

The generated XCFramework is ignored by Git. This historical pin is not a
release recommendation: before using a rebuilt framework, update and review its
upstream dependencies and Go toolchain, reproduce the source and local patch,
and carry the applicable licenses/notices alongside distributed output. The
[notice archive](../../THIRD_PARTY_NOTICES.md) describes the previous binary's
inspected dependency versions, not the contents of any future rebuild.
