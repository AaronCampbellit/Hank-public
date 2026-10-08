# Third-party notices

The repository's original-code license does not replace third-party licenses.
This inventory is dated October 8, 2026. The current source tree does not contain
or link a third-party networking framework; this is not an App Store release
certification.

## Optional networking rebuild and preserved notices

The current Xcode project's Frameworks build phases are empty, its Swift package
pins are empty, and app source has no `import TailscaleKit`. The legacy
`TailscaleSettings` SwiftData model is retained only for local-store compatibility;
it does not activate a networking library.

[Optional upstream/rebuild instructions](Vendor/TailscaleKit/UPSTREAM.md) retain
libtailscale revision `5e89501def80a6579ca5d0f9a02f336be62b8f2e` and the declared
Swift error-detail/buffer patch. The standalone rebuild script is the only writer
of `Vendor/TailscaleKit/TailscaleKit.xcframework`; no application build, test, or
deployment path invokes it. Generated output is ignored by Git. No XCFramework
payload is included in this source tree.

The following license archive describes the previously inspected, unlinked
framework, whose build metadata named Go 1.26.2 and 42 dependency modules plus
libtailscale. These are preserved upstream notices, not current application
dependencies or approval to redistribute a rebuilt framework. A future rebuild
must refresh the exact dependency inventory, preserve full applicable notices,
verify source/patch provenance, and pass current security checks before release.

| Component | Binary-recorded version | Inspected root terms | Exact upstream source | Preserved text |
| --- | --- | --- | --- | --- |
| `github.com/tailscale/libtailscale` | `v0.0.0-20260228020650-5e89501def80+dirty` | BSD-3-Clause | [source](https://github.com/tailscale/libtailscale/tree/5e89501def80) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__tailscale__libtailscale/v0.0.0-20260228020650-5e89501def80_dirty/LICENSE) |
| `filippo.io/edwards25519` | `v1.1.0` | BSD-3-Clause | [source](https://github.com/FiloSottile/edwards25519/tree/v1.1.0) | [LICENSE](third-party-licenses/vendored-tailscale/filippo.io__edwards25519/v1.1.0/LICENSE) |
| `github.com/aws/aws-sdk-go-v2` | `v1.41.0` | Apache-2.0 | [source](https://github.com/aws/aws-sdk-go-v2/tree/v1.41.0) | [LICENSE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2/v1.41.0/LICENSE.txt), [NOTICE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2/v1.41.0/NOTICE.txt) |
| `github.com/aws/aws-sdk-go-v2/config` | `v1.29.5` | Apache-2.0 | [source](https://github.com/aws/aws-sdk-go-v2/tree/config/v1.29.5/config) | [LICENSE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__config/v1.29.5/LICENSE.txt), [NOTICE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__config/v1.29.5/NOTICE.txt) |
| `github.com/aws/aws-sdk-go-v2/credentials` | `v1.17.58` | Apache-2.0 | [source](https://github.com/aws/aws-sdk-go-v2/tree/credentials/v1.17.58/credentials) | [LICENSE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__credentials/v1.17.58/LICENSE.txt), [NOTICE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__credentials/v1.17.58/NOTICE.txt) |
| `github.com/aws/aws-sdk-go-v2/feature/ec2/imds` | `v1.16.27` | Apache-2.0 | [source](https://github.com/aws/aws-sdk-go-v2/tree/feature/ec2/imds/v1.16.27/feature/ec2/imds) | [LICENSE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__feature__ec2__imds/v1.16.27/LICENSE.txt), [NOTICE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__feature__ec2__imds/v1.16.27/NOTICE.txt) |
| `github.com/aws/aws-sdk-go-v2/internal/configsources` | `v1.4.16` | Apache-2.0 | [source](https://github.com/aws/aws-sdk-go-v2/tree/internal/configsources/v1.4.16/internal/configsources) | [LICENSE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__internal__configsources/v1.4.16/LICENSE.txt), [NOTICE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__internal__configsources/v1.4.16/NOTICE.txt) |
| `github.com/aws/aws-sdk-go-v2/internal/endpoints/v2` | `v2.7.16` | Apache-2.0 | [source](https://github.com/aws/aws-sdk-go-v2/tree/internal/endpoints/v2.7.16/internal/endpoints) | [LICENSE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__internal__endpoints__v2/v2.7.16/LICENSE.txt), [NOTICE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__internal__endpoints__v2/v2.7.16/NOTICE.txt) |
| `github.com/aws/aws-sdk-go-v2/internal/ini` | `v1.8.2` | Apache-2.0 | [source](https://github.com/aws/aws-sdk-go-v2/tree/internal/ini/v1.8.2/internal/ini) | [LICENSE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__internal__ini/v1.8.2/LICENSE.txt), [NOTICE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__internal__ini/v1.8.2/NOTICE.txt) |
| `github.com/aws/aws-sdk-go-v2/service/internal/accept-encoding` | `v1.13.4` | Apache-2.0 | [source](https://github.com/aws/aws-sdk-go-v2/tree/service/internal/accept-encoding/v1.13.4/service/internal/accept-encoding) | [LICENSE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__service__internal__accept-encoding/v1.13.4/LICENSE.txt), [NOTICE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__service__internal__accept-encoding/v1.13.4/NOTICE.txt) |
| `github.com/aws/aws-sdk-go-v2/service/internal/presigned-url` | `v1.13.16` | Apache-2.0 | [source](https://github.com/aws/aws-sdk-go-v2/tree/service/internal/presigned-url/v1.13.16/service/internal/presigned-url) | [LICENSE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__service__internal__presigned-url/v1.13.16/LICENSE.txt), [NOTICE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__service__internal__presigned-url/v1.13.16/NOTICE.txt) |
| `github.com/aws/aws-sdk-go-v2/service/sso` | `v1.24.14` | Apache-2.0 | [source](https://github.com/aws/aws-sdk-go-v2/tree/service/sso/v1.24.14/service/sso) | [LICENSE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__service__sso/v1.24.14/LICENSE.txt), [NOTICE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__service__sso/v1.24.14/NOTICE.txt) |
| `github.com/aws/aws-sdk-go-v2/service/ssooidc` | `v1.28.13` | Apache-2.0 | [source](https://github.com/aws/aws-sdk-go-v2/tree/service/ssooidc/v1.28.13/service/ssooidc) | [LICENSE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__service__ssooidc/v1.28.13/LICENSE.txt), [NOTICE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__service__ssooidc/v1.28.13/NOTICE.txt) |
| `github.com/aws/aws-sdk-go-v2/service/sts` | `v1.41.5` | Apache-2.0 | [source](https://github.com/aws/aws-sdk-go-v2/tree/service/sts/v1.41.5/service/sts) | [LICENSE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__service__sts/v1.41.5/LICENSE.txt), [NOTICE.txt](third-party-licenses/vendored-tailscale/github.com__aws__aws-sdk-go-v2__service__sts/v1.41.5/NOTICE.txt) |
| `github.com/aws/smithy-go` | `v1.24.0` | Apache-2.0 | [source](https://github.com/aws/smithy-go/tree/v1.24.0) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__aws__smithy-go/v1.24.0/LICENSE), [NOTICE](third-party-licenses/vendored-tailscale/github.com__aws__smithy-go/v1.24.0/NOTICE) |
| `github.com/creachadair/msync` | `v0.7.1` | BSD-3-Clause | [source](https://github.com/creachadair/msync/tree/v0.7.1) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__creachadair__msync/v0.7.1/LICENSE) |
| `github.com/fxamacker/cbor/v2` | `v2.9.0` | MIT | [source](https://github.com/fxamacker/cbor/tree/v2.9.0) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__fxamacker__cbor__v2/v2.9.0/LICENSE) |
| `github.com/gaissmai/bart` | `v0.18.0` | MIT | [source](https://github.com/gaissmai/bart/tree/v0.18.0) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__gaissmai__bart/v0.18.0/LICENSE) |
| `github.com/go-json-experiment/json` | `v0.0.0-20250813024750-ebf49471dced` | BSD-3-Clause | [source](https://github.com/go-json-experiment/json/tree/ebf49471dced) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__go-json-experiment__json/v0.0.0-20250813024750-ebf49471dced/LICENSE) |
| `github.com/golang/groupcache` | `v0.0.0-20241129210726-2c02b8208cf8` | Apache-2.0 | [source](https://github.com/golang/groupcache/tree/2c02b8208cf8) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__golang__groupcache/v0.0.0-20241129210726-2c02b8208cf8/LICENSE) |
| `github.com/google/btree` | `v1.1.3` | Apache-2.0 | [source](https://github.com/google/btree/tree/v1.1.3) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__google__btree/v1.1.3/LICENSE) |
| `github.com/google/uuid` | `v1.6.0` | BSD-3-Clause | [source](https://github.com/google/uuid/tree/v1.6.0) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__google__uuid/v1.6.0/LICENSE) |
| `github.com/hdevalence/ed25519consensus` | `v0.2.0` | BSD-3-Clause | [source](https://github.com/hdevalence/ed25519consensus/tree/v0.2.0) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__hdevalence__ed25519consensus/v0.2.0/LICENSE) |
| `github.com/huin/goupnp` | `v1.3.0` | BSD-2-Clause | [source](https://github.com/huin/goupnp/tree/v1.3.0) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__huin__goupnp/v1.3.0/LICENSE) |
| `github.com/klauspost/compress` | `v1.18.2` | BSD-3-Clause / Apache-2.0 / MIT (file-specific; full upstream text retained) | [source](https://github.com/klauspost/compress/tree/v1.18.2) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__klauspost__compress/v1.18.2/LICENSE) |
| `github.com/pires/go-proxyproto` | `v0.8.1` | Apache-2.0 | [source](https://github.com/pires/go-proxyproto/tree/v0.8.1) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__pires__go-proxyproto/v0.8.1/LICENSE) |
| `github.com/prometheus-community/pro-bing` | `v0.4.0` | MIT | [source](https://github.com/prometheus-community/pro-bing/tree/v0.4.0) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__prometheus-community__pro-bing/v0.4.0/LICENSE) |
| `github.com/tailscale/peercred` | `v0.0.0-20250107143737-35a0c7bd7edc` | BSD-3-Clause | [source](https://github.com/tailscale/peercred/tree/35a0c7bd7edc) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__tailscale__peercred/v0.0.0-20250107143737-35a0c7bd7edc/LICENSE) |
| `github.com/tailscale/wireguard-go` | `v0.0.0-20250716170648-1d0488a3d7da` | MIT | [source](https://github.com/tailscale/wireguard-go/tree/1d0488a3d7da) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__tailscale__wireguard-go/v0.0.0-20250716170648-1d0488a3d7da/LICENSE) |
| `github.com/x448/float16` | `v0.8.4` | MIT | [source](https://github.com/x448/float16/tree/v0.8.4) | [LICENSE](third-party-licenses/vendored-tailscale/github.com__x448__float16/v0.8.4/LICENSE) |
| `go4.org/mem` | `v0.0.0-20240501181205-ae6ca9944745` | Apache-2.0 | [source](https://github.com/go4org/mem/tree/ae6ca9944745) | [LICENSE](third-party-licenses/vendored-tailscale/go4.org__mem/v0.0.0-20240501181205-ae6ca9944745/LICENSE) |
| `go4.org/netipx` | `v0.0.0-20231129151722-fdeea329fbba` | BSD-3-Clause | [source](https://github.com/go4org/netipx/tree/fdeea329fbba) | [LICENSE](third-party-licenses/vendored-tailscale/go4.org__netipx/v0.0.0-20231129151722-fdeea329fbba/LICENSE) |
| `golang.org/x/crypto` | `v0.46.0` | BSD-3-Clause | [source](https://github.com/golang/crypto/tree/v0.46.0) | [LICENSE](third-party-licenses/vendored-tailscale/golang.org__x__crypto/v0.46.0/LICENSE) |
| `golang.org/x/exp` | `v0.0.0-20250620022241-b7579e27df2b` | BSD-3-Clause | [source](https://github.com/golang/exp/tree/b7579e27df2b) | [LICENSE](third-party-licenses/vendored-tailscale/golang.org__x__exp/v0.0.0-20250620022241-b7579e27df2b/LICENSE) |
| `golang.org/x/net` | `v0.48.0` | BSD-3-Clause | [source](https://github.com/golang/net/tree/v0.48.0) | [LICENSE](third-party-licenses/vendored-tailscale/golang.org__x__net/v0.48.0/LICENSE) |
| `golang.org/x/oauth2` | `v0.32.0` | BSD-3-Clause | [source](https://github.com/golang/oauth2/tree/v0.32.0) | [LICENSE](third-party-licenses/vendored-tailscale/golang.org__x__oauth2/v0.32.0/LICENSE) |
| `golang.org/x/sync` | `v0.19.0` | BSD-3-Clause | [source](https://github.com/golang/sync/tree/v0.19.0) | [LICENSE](third-party-licenses/vendored-tailscale/golang.org__x__sync/v0.19.0/LICENSE) |
| `golang.org/x/sys` | `v0.40.0` | BSD-3-Clause | [source](https://github.com/golang/sys/tree/v0.40.0) | [LICENSE](third-party-licenses/vendored-tailscale/golang.org__x__sys/v0.40.0/LICENSE) |
| `golang.org/x/term` | `v0.38.0` | BSD-3-Clause | [source](https://github.com/golang/term/tree/v0.38.0) | [LICENSE](third-party-licenses/vendored-tailscale/golang.org__x__term/v0.38.0/LICENSE) |
| `golang.org/x/text` | `v0.32.0` | BSD-3-Clause | [source](https://github.com/golang/text/tree/v0.32.0) | [LICENSE](third-party-licenses/vendored-tailscale/golang.org__x__text/v0.32.0/LICENSE) |
| `golang.org/x/time` | `v0.12.0` | BSD-3-Clause | [source](https://github.com/golang/time/tree/v0.12.0) | [LICENSE](third-party-licenses/vendored-tailscale/golang.org__x__time/v0.12.0/LICENSE) |
| `gvisor.dev/gvisor` | `v0.0.0-20250205023644-9414b50a5633` | Apache-2.0 | [source](https://github.com/google/gvisor/tree/9414b50a5633) | [LICENSE](third-party-licenses/vendored-tailscale/gvisor.dev__gvisor/v0.0.0-20250205023644-9414b50a5633/LICENSE) |
| `tailscale.com` | `v1.94.1` | BSD-3-Clause | [source](https://github.com/tailscale/tailscale/tree/v1.94.1) | [LICENSE](third-party-licenses/vendored-tailscale/tailscale.com/v1.94.1/LICENSE) |

The framework's Go toolchain/runtime license is preserved in
[Go-go1.26.2-LICENSE](third-party-licenses/vendored-tailscale/Go-go1.26.2-LICENSE). The
[provenance manifest](third-party-licenses/vendored-tailscale/provenance.json)
records exact upstream license/notice URLs and copy digests. Root module licenses
were retrieved for all 43 identified modules, together with available AWS NOTICE
texts. Mixed file-specific terms in `klauspost/compress` are retained verbatim.

## Distribution limits

Historical Git commits may still contain the removed binary payload. A clean
source snapshot excludes it; deleting it from the current source tree does not
remove it from repository history. The archived provenance manifest records
upstream notice sources and digests, but it is not an independently reproduced
build and does not establish complete historical binary compliance.

No third-party Swift package is resolved or linked by the current project.
Native UI uses Apple platform frameworks and system symbols through their SDK
APIs; this repository does not bundle Apple framework or symbol-font binaries.
The existing Hank icon artwork has no explicit author metadata here; no evidence
of copied third-party artwork was identified. New screenshots have a documented
simulator capture provenance in `docs/screenshots/README.md`.
