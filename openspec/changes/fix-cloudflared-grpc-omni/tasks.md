## 1. Investigation & Baseline

- [ ] 1.1 Confirm baseline failure is still reproducible after the v1.8.1 upgrade landed: `rm -f ~/.talos/keys/*.pgp && omnictl get clusters --omniconfig ~/.talos/omni/config 2>&1 | tee /tmp/baseline.log`; expect "stream closed without trailers"
- [ ] 1.2 Confirm baseline server-side behavior is OK: `env KUBECONFIG=~/coding/jcom/kubeconfig kubectl -n omni logs deploy/omni --tail=200 | grep -E 'RegisterPublicKey|new public key registered'` — the most recent entry SHOULD have `grpc.code: OK`, proving the failure is purely transport-layer
- [ ] 1.3 Enumerate all `*.janncot.com` hostnames currently in use (grep manifests in `~/coding/jg-base ~/coding/jcom ~/coding/jg-jiahd`); list which serve gRPC vs HTTP only — needed to assess blast radius of any zone-level change (resolves OQ-2)
- [ ] 1.4 Inspect Omni HTTP API to confirm that gRPC service paths (`/<package>.<Service>/<Method>`) do not overlap with REST paths (resolves the D3 wildcard-vs-allowlist assumption)
- [ ] 1.5 Inspect existing GRPCRoute precedents in the cluster: `kubectl get grpcroute -A` — if any exist, mimic their structure (resolves OQ-4 by example)

## 2. Step 1 — Cloudflare Zone "gRPC" Toggle

- [ ] 2.1 Log into Cloudflare dashboard for `janncot.com` zone; navigate to Network → gRPC. Record current setting (resolves OQ-1)
- [ ] 2.2 If OFF: enable it. Document the change in this change's notes (the toggle is zone-wide; mention any unexpected behavior on other hosts to watch for)
- [ ] 2.3 Re-test: `rm -f ~/.talos/keys/*.pgp && omnictl get clusters --omniconfig ~/.talos/omni/config 2>&1`; capture output. If success or registration URL printed → jump to task 5
- [ ] 2.4 If still failing: capture both client output and the matching server log entry timestamp; proceed to step 3

## 3. Step 2 — Add Sibling GRPCRoute

- [ ] 3.1 Read `~/coding/omni/deploy/helm/omni/templates/gatewayApi/grpcroute-siderolink.yaml` at the deployed tag (`v1.8.1`) for the canonical Omni GRPCRoute shape (path matches, parentRefs)
- [ ] 3.2 Design the GRPCRoute manifest: hostname `omni.janncot.com`, parentRef the existing `envoy-external` Gateway https listener, backendRef `omni.omni.svc:8080`, method matches for the four gRPC services from design D3 (`auth.AuthService`, `management.ManagementService`, `cluster.ClusterService`, `omni.machine.MachineService`)
- [ ] 3.3 Create `kubernetes/apps/extras/omni/omni/app/grpcroute.yaml` containing the new GRPCRoute (sibling to the existing HTTPRoute — D2 decision)
- [ ] 3.4 Add the new file to `kubernetes/apps/extras/omni/omni/app/kustomization.yaml` if it uses an explicit `resources` list
- [ ] 3.5 Local validation: `kustomize build kubernetes/apps/extras/omni/omni/app`; ensure both HTTPRoute and GRPCRoute appear in the rendered output
- [ ] 3.6 Commit on a feature branch in `jg-base`: `feat(omni): add GRPCRoute for omni.janncot.com gRPC services`
- [ ] 3.7 Push, then force-reconcile: `env KUBECONFIG=~/coding/jcom/kubeconfig flux reconcile source git jg-base -n flux-system && flux reconcile kustomization extras-omni -n flux-system`
- [ ] 3.8 Wait for the GRPCRoute to become `Accepted=True`: `kubectl -n omni get grpcroute omni -o jsonpath='{.status.parents[*].conditions[?(@.type=="Accepted")].status}'`
- [ ] 3.9 Re-test omnictl per task 2.3 pattern; capture output. If success or URL printed → jump to task 5
- [ ] 3.10 If still failing: capture client output + server log + Envoy access logs (`kubectl -n network logs deploy/envoy-omni-* -c envoy --tail=100`); proceed to step 4

## 4. Step 3 — cloudflared Tunnel Ingress Scheme (last resort)

- [ ] 4.1 Read current cloudflared `configMap.config.data.config.yaml` in `kubernetes/apps/base/network/cloudflare-tunnel/app/helmrelease.yaml`
- [ ] 4.2 Decide on the per-host override approach: add a `- hostname: omni.janncot.com` entry BEFORE the catch-all `- hostname: "*.${SECRET_DOMAIN}"`, using either `service: h2c://...` (if Envoy serves HTTP/2 cleartext on a separate port) or keep `https://` but explicitly add `grpc: true` if supported by cloudflared
- [ ] 4.3 Validate the proposed config syntax against cloudflared docs for the current image tag (`2026.2.0`)
- [ ] 4.4 Edit the HelmRelease; commit; push; reconcile (`flux reconcile helmrelease cloudflare-tunnel -n network`)
- [ ] 4.5 Watch cloudflared pod for reload (`kubectl -n network logs deploy/cloudflare-tunnel --tail=50`); confirm no startup errors
- [ ] 4.6 Re-test omnictl per task 2.3 pattern. If still failing → escalate per R5 (fallback hostname `omni-grpc.janncot.duckdns.org` via nginx with `backend-protocol: GRPC`); document in the runbook and exit this change as "blocked by upstream"

## 5. Verification

- [ ] 5.1 Re-run validation script with FRESH state: `rm -f ~/.talos/keys/*.pgp && omnictl get clusters --omniconfig ~/.talos/omni/config 2>&1`
- [ ] 5.2 Output MUST either succeed listing clusters, OR print a URL beginning with `https://omni.janncot.com/`; output MUST NOT contain `no such file or directory` or `server closed the stream without sending trailers`
- [ ] 5.3 Verify `~/.talos/keys/default-ferry133@gmail.com.pgp` exists with `-rw-------` perms (WriteKey completed) — `ls -la ~/.talos/keys/`
- [ ] 5.4 If URL was printed: visit it in browser, click Grant Access, then re-run `omnictl get clusters` — MUST list `jgu5-control-planes`
- [ ] 5.5 Regression: `curl -sI https://omni.janncot.com/` MUST still return `HTTP/2 200` (UI unaffected by gRPC fix)
- [ ] 5.6 Regression: `omni-siderolink.janncot.duckdns.org` machine connectivity unchanged (visible in Omni UI Machines page)

## 6. Documentation

- [ ] 6.1 Update `kubernetes/apps/extras/omni/omni/README.md` Troubleshooting section: change the "Known limitation as of 2026-05-31" to "Resolved in fix-cloudflared-grpc-omni (date)"; record which step(s) of D1 actually proved necessary (e.g., "only zone toggle", "zone toggle + GRPCRoute", etc.)
- [ ] 6.2 Commit: `docs(omni): mark gRPC trailer issue resolved`

## 7. Close Out

- [ ] 7.1 Update memory `~/.claude/projects/-Users-ferry133-coding-jg-base/memory/project_omni_platform.md` — remove the "Known blocker" section; replace with a brief note that the gRPC path works and which layer was the culprit
- [ ] 7.2 `openspec validate fix-cloudflared-grpc-omni` and `openspec archive fix-cloudflared-grpc-omni` (only after specs scenarios verified passing)
- [ ] 7.3 Push final state to origin/main

## 8. Rollback (per-step, if any single step regresses traffic)

- [ ] 8.1 **Step 1 rollback**: turn the Cloudflare zone gRPC toggle back OFF in the dashboard
- [ ] 8.2 **Step 2 rollback**: `git revert` the GRPCRoute commit; flux reconcile (the HTTPRoute alone keeps omni.janncot.com working as it did before — just back to the original broken state for omnictl)
- [ ] 8.3 **Step 3 rollback**: `git revert` the cloudflared HelmRelease commit; flux reconcile cloudflare-tunnel; verify pod restarts cleanly with the previous config
- [ ] 8.4 If multiple steps were applied and the issue is unclear which broke: revert in reverse order one at a time, re-testing after each
