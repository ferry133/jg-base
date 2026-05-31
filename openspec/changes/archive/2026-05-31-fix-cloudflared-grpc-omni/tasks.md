## 1. Investigation & Baseline

- [x] 1.1 Baseline failure reproduced: 3-line error `stream closed without sending trailers`, no key file written
- [x] 1.2 Server-side OK confirmed: `RegisterPublicKey` returned `grpc.code: OK` at 02:14:31Z with valid `loginUrl` for public-key-id `59e317b4d5db9ca7...`
- [x] 1.3 Hostname enumeration (resolves OQ-2): Omni hosts (`omni`, `omni-k8s`, `omni-siderolink` × `.com` + `.duckdns.org`); other `janncot.com` apps are all HTTP-only (cc, claude-code, echo, hb, ttyd, flux-webhook, pbx). Cloudflare gRPC zone-level toggle is non-breaking for HTTP-only traffic per docs → low risk to enable
- [x] 1.4 Omni gRPC path pattern `/<package>.<Service>/<Method>` does not overlap with UI `/` or REST `/api/...` paths — D3 allowlist approach avoids needing a wildcard match
- [x] 1.5 No existing GRPCRoute in the cluster (`kubectl get grpcroute -A` → No resources found). Our manifest will be the first; follow Gateway API v1 GRPCRoute spec directly

## 2. Step 1 — Cloudflare Zone "gRPC" Toggle

- [x] 2.1 Cloudflare zone `janncot.com` Network → gRPC toggle: **already ON** (operator-confirmed 2026-05-31) (resolves OQ-1)
- [x] 2.2 No change required — toggle was already enabled before this change started
- [x] 2.3 Re-test confirms same baseline failure (`stream closed without sending trailers`) with toggle ON → Cloudflare edge is not the culprit, trailers are being stripped further down the path
- [x] 2.4 Proceeding to Step 2 (sibling GRPCRoute at the Envoy Gateway layer)

## 3. Step 2 — Add Sibling GRPCRoute

- [x] 3.1 Read upstream `grpcroute-siderolink.yaml` template at v1.8.1; pattern adopted as basis
- [x] 3.2 Designed: hostname `omni.janncot.com`, parentRef `envoy-external` https listener, backendRef `omni.omni.svc:8080`, method matches for 4 services
- [x] 3.3 Replaced inactive `omni-siderolink` draft in `kubernetes/apps/extras/omni/omni/app/grpcroute.yaml` with new `omni-grpc` GRPCRoute
- [x] 3.4 Added `./grpcroute.yaml` to `kustomization.yaml` resources list
- [x] 3.5 `kustomize build` clean — 1 GRPCRoute + 2 HTTPRoute render in output
- [x] 3.6 Committed `09aa159 feat(omni): add GRPCRoute for omni.janncot.com gRPC services`
- [x] 3.7 Pushed + force reconciled
- [x] 3.8 GRPCRoute status: Accepted=True, ResolvedRefs=True
- [x] 3.9 Re-test still failed with `stream closed without sending trailers`
- [x] 3.10 Envoy access log proved request hit GRPCRoute (`route_name: grpcroute/omni/omni-grpc/rule/0`), `response_code: 200`, `response_flags: -` — Envoy is clean. cloudflared logs showed `context canceled` errors → trailer-stripping happens between envoy and cloudflared edge, not at envoy. GRPCRoute kept as architectural intent; proceed to Step 3

## 4. Step 3 — cloudflared Tunnel Ingress Scheme (SKIPPED per operator)

- [~] 4.1–4.6 **Skipped** — the candidate fix (`TUNNEL_TRANSPORT_PROTOCOL: quic → http2` + `TUNNEL_POST_QUANTUM: true → false`) is tunnel-wide and affects 7+ unrelated apps on the cloudflared catch-all rule. Operator declined the change at the gate; proceeded directly to R5 fallback (Section 4a)

## 4a. R5 Fallback — Separate Hostname via nginx Ingress (the actual fix)

- [x] 4a.1 Determined `*.janncot.duckdns.org` is DuckDNS auto-wildcarded → ferry133's public IP (`1.34.181.95`); no new DNS record needed
- [x] 4a.2 Added nginx Ingress `omni-grpc-ing` for `omni-grpc.janncot.duckdns.org` → `omni.omni.svc:8080` with `nginx.ingress.kubernetes.io/backend-protocol: "GRPC"` to `kubernetes/apps/extras/omni/omni/app/ingress.yaml`; cert-manager auto-issued cert via DuckDNS DNS01 webhook (~2 min)
- [x] 4a.3 Pushed `1914f69 feat(omni): add nginx Ingress for omnictl gRPC fallback (R5)`, reconciled
- [x] 4a.4 First retest: `RegisterPublicKey` succeeded client-side, `WriteKey` saved `.pgp`, `browser.OpenURL` fired → but `AwaitPublicKeyConfirmation` streaming RPC hit nginx's default 60s `proxy-read-timeout` → 504
- [x] 4a.5 Added `nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"` + `proxy-send-timeout: "3600"` annotations
- [x] 4a.6 Pushed `fcda246 fix(omni): bump nginx ingress timeouts for streaming gRPC`, reconciled
- [x] 4a.7 Updated `~/.talos/omni/config` URL: `https://omni.janncot.com → https://omni-grpc.janncot.duckdns.org`

## 5. Verification

- [x] 5.1 Fresh-state run: `rm -f ~/.talos/keys/default-*.pgp && omnictl get clusters --omniconfig ~/.talos/omni/config` against new hostname
- [x] 5.2 Output: `Public key ... is now registered`, `PGP key saved to ~/.talos/keys/default-ferry133@gmail.com.pgp`, then cluster listing (no `no such file or directory`, no `stream closed`)
- [x] 5.3 `.pgp` file present (985 bytes, mode 600)
- [x] 5.4 Browser opened to `omni.janncot.com/authenticate?flow=cli&public-key-id=...`, operator clicked Grant Access, omnictl received confirmation and printed: `default Cluster jgu5 v15 Talos 1.13.2 K8s 1.35.2`
- [x] 5.5 `curl -sI https://omni.janncot.com/` → `HTTP/2 200` (no UI regression)
- [x] 5.6 Siderolink ingress still on `10.9.8.6`, unchanged

## 6. Documentation

- [x] 6.1 Updated `kubernetes/apps/extras/omni/omni/README.md` Troubleshooting section — replaced the "Known limitation" entry with a resolved-status block recording the R5 fallback (separate hostname + nginx + GRPC backend-protocol + 3600s timeouts), what was tried and rejected (cloudflared transport switch), and the omniconfig change operators must make
- [ ] 6.2 Commit pending in Phase 7 batch

## 7. Close Out

- [ ] 7.1 Update memory `project_omni_platform.md` — replace "Known blocker" with "Resolved via R5 fallback to omni-grpc.janncot.duckdns.org"
- [ ] 7.2 Commit + push README + tasks + (later) archive move
- [ ] 7.3 `openspec validate fix-cloudflared-grpc-omni` + `openspec archive fix-cloudflared-grpc-omni`

## 8. Rollback (per-step, if any single step regresses traffic)

- [ ] 8.1 **Step 1 rollback**: turn the Cloudflare zone gRPC toggle back OFF in the dashboard
- [ ] 8.2 **Step 2 rollback**: `git revert` the GRPCRoute commit; flux reconcile (the HTTPRoute alone keeps omni.janncot.com working as it did before — just back to the original broken state for omnictl)
- [ ] 8.3 **Step 3 rollback**: `git revert` the cloudflared HelmRelease commit; flux reconcile cloudflare-tunnel; verify pod restarts cleanly with the previous config
- [ ] 8.4 If multiple steps were applied and the issue is unclear which broke: revert in reverse order one at a time, re-testing after each
