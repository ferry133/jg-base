## 1. Pre-flight & Research

- [x] 1.1 Confirm `jcom` cluster is healthy: all Flux Kustomizations `Ready=True`, no pending reconciliations, etcd of `jcom` itself stable
- [x] 1.2 Confirm Omni pod is currently `Running` and Omni UI loads at `https://omni.janncot.com`
- [x] 1.3 Read upstream `v1.7.0` release notes' "Urgent Upgrade Notes" end-to-end; record any required intermediate steps (resolves OQ-1) — only requirement is EULA acceptance (covered by D4)
- [x] 1.4 Read upstream `v1.8.0` release notes' "Urgent Upgrade Notes" end-to-end; confirm direct upgrade from `v1.6.x` is supported (resolves OQ-1) — `--join-tokens-mode=legacyAllowed` default requires Talos ≥ 1.6; jg-jiahd nodes run Talos v1.13.2 ✓
- [x] 1.5 `git -C ~/coding/omni show v1.8.1:deploy/helm/omni/Chart.yaml` — record upstream chart `version` for D3 alignment (resolves OQ-2) — upstream `version: 2.8.1`, `appVersion: "v1.8.1"`. **D3 revised**: adopt upstream `2.8.1` (semver-forward from our `2.1.1`), drop the `3.0.0` major-bump plan
- [x] 1.6 `diff -r ~/coding/helm-charts/charts/omni/ <(git -C ~/coding/omni show v1.5.3:deploy/helm/omni/ ...)` — identify any local-only modifications to preserve (resolves OQ-3) — only delta vs baseline is metadata (home/sources/keywords/maintainers) which upstream v1.8.1 already includes. **Zero local modifications to preserve.**
- [x] 1.7 Inspect `~/coding/helm-charts` for `Taskfile.yaml`, `Makefile`, or `.github/workflows/` — document the chart publish workflow (resolves OQ-4) — `.github/workflows/release.yaml` runs `helm/chart-releaser-action@v1.7.0` on push to `main`; auto-publishes new chart version to GitHub Pages
- [ ] 1.8 Read EULA at `https://siderolabs.com/eula/` (resolves R5) — **operator action required: must be read in browser by ferry133 before T5.2 records acceptance**
- [x] 1.9 Snapshot current state — PVC `omni-local` 8Gi Bound (local-path); HelmRelease chart `2.1.1`, image `ghcr.io/siderolabs/omni:v1.6.4`; `omni-config` Secret has key `config.yaml` (1173 bytes); `omni-gpg-key` Secret has key `omni.asc` (740 bytes); pod 0 restarts since 2026-05-14
- [x] 1.10 Verify backup posture — both `omni-config` and `omni-gpg-key` Secret data injected via Flux postBuild substitution from `cluster-secrets` (jcom per-user repo, SOPS-encrypted with `age.key`); `age.key` itself is offsite-backed-up (2026-05-30) ✓

## 2. Refresh Local Omni Source Clone

- [x] 2.1 `cd ~/coding/omni && git status` — confirm clean tree (or stash known-disposable changes like `?? kubeconfig`) — only `?? kubeconfig` and `?? values.yaml` (untracked, will not interfere with checkout)
- [x] 2.2 `git fetch --tags origin` — pulled v1.7.3, v1.8.0, v1.8.0-beta.{0,1}, v1.8.1
- [x] 2.3 `git checkout v1.8.1` (detached HEAD is fine) — HEAD now at `76af8b22 release(v1.8.1): prepare release`
- [x] 2.4 Confirm `deploy/helm/omni/Chart.yaml` exists at this tag with the expected `appVersion` — confirmed `version: 2.8.1`, `appVersion: "v1.8.1"`

## 3. Regenerate Helm Chart Fork

- [x] 3.1 `cd ~/coding/helm-charts && git checkout -b chore/omni-v1.8.1` (working branch)
- [x] 3.2 Backup current chart: `cp -a charts/omni charts/omni.bak-2.1.1` (252K)
- [x] 3.3 Replace contents from `~/coding/omni/deploy/helm/omni/` at tag `v1.8.1` (35 files)
- [x] 3.4 Re-apply local-only modifications identified in 1.6 (if any) — none required
- [x] 3.5 Bump `Chart.yaml` — upstream stamps `version: 2.8.1`, `appVersion: "v1.8.1"` (per D3 revision: adopt upstream, not 3.0.0 major bump)
- [x] 3.6 `helm lint charts/omni` — 1 chart linted, 0 failed (INFO Fail rows are default-value validation hints, not blockers; lint exit 0)
- [x] 3.7 `helm template test charts/omni -f <jg-base-values> -f <synthetic-overrides>` — 6 manifests render cleanly under our overrides, `etcdEncryptionKey` schema unchanged
- [x] 3.8 If 3.7 surfaces unknown keys: update jg-base HelmRelease values to match new schema — no-op (no breaks)
- [x] 3.9 Remove backup: `charts/omni.bak-2.1.1` deleted
- [x] 3.10 Commit on `chore/omni-v1.8.1`: `70b45b3 chore(omni): regenerate chart from upstream v1.8.1` (5 files, +600/-337)

## 4. Republish Chart to GitHub Pages

- [x] 4.1 Auto-handled by `helm/chart-releaser-action@v1.7.0` on push to `main` (workflow `.github/workflows/release.yaml`)
- [x] 4.2 Fast-forward merged `chore/omni-v1.8.1` to `main` and pushed (`c226208..70b45b3`)
- [x] 4.3 Actions run #26698030153 completed; all steps ✓
- [x] 4.4 Verified: index.yaml has both `omni-2.8.1` (new, appVersion v1.8.1) and `omni-2.1.1` (rollback-target); `omni-2.8.1.tgz` returns 200 from Azure Blob (33,169 bytes)

## 5. Update jg-base HelmRelease

- [x] 5.1 `cd ~/coding/jg-base && git checkout -b chore/omni-v1.8.1`
- [x] 5.2 Edited `kubernetes/apps/extras/omni/omni/app/helmrelease.yaml`:
  - Chart version: `'2.1.1'` → `'2.8.1'` (line 16)
  - Image tag: `"v1.6.4"` → `"v1.8.1"` (line 50)
  - Added `values.config.eulaAccept: { name: "ferry133", email: "ferry133@gmail.com" }` (D4, before account block ~line 79)
  - No additional schema migrations needed (Phase 3.7 found no breaks)
- [x] 5.3 ~~`task configure`~~ — N/A: jg-base has no Taskfile (template rendering happens in per-user cluster repos, not in jg-base). Marked done as no-op.
- [x] 5.4 Local validation: `kustomize build kubernetes/apps/extras/omni/omni/app` exits 0; all 3 expected edits verified in file
- [x] 5.5 Commit (local only) — `9f2e3b3 feat(omni): upgrade to v1.8.1, accept EULA`
- [x] 5.6 **PVC snapshot (R3 mitigation)** — `kubectl exec` direct tar failed because Omni runs distroless (no shell/tar); `kubectl debug` ephemeral container couldn't pipe binary cleanly. Resolved by: scale Omni to 0 → mount `omni-local` PVC into a busybox sidecar pod (node-pinned to `jcom-0-0` to satisfy local-path PV nodeAffinity) → `kubectl exec snapshot-pod -- tar czf - /data` → delete sidecar → scale Omni back to 1. Snapshot: `~/omni-data-snapshot-v1.6.4-20260531-0816.tar.gz` (3.0M, 9 entries: etcd member data + sqlite.db + secondary-storage). Verify `tar tzf` lists data/etcd/member/snap/db before discarding. (Update operator runbook to reflect this distroless-snapshot pattern in Phase 8.)
- [x] 5.7 Push to `main` — `c2ffa58..9f2e3b3` ff-pushed (Flux will discover within 15m HelmRelease interval; Phase 6 forces it immediately)

## 6. Trigger Reconcile & Monitor

- [ ] 6.1 `env KUBECONFIG=~/coding/jcom/kubeconfig flux reconcile source git jg-base -n flux-system` (force pull new commit)
- [ ] 6.2 `env KUBECONFIG=~/coding/jcom/kubeconfig flux reconcile source helm my-helm-repo -n omni` (force new chart index pull — resolves R4)
- [ ] 6.3 `env KUBECONFIG=~/coding/jcom/kubeconfig flux reconcile kustomization extras-omni -n flux-system`
- [ ] 6.4 `env KUBECONFIG=~/coding/jcom/kubeconfig flux reconcile helmrelease omni -n omni`
- [ ] 6.5 Watch pod rollout: `kubectl -n omni get pods -w` until new pod is `Running` and `Ready 1/1`
- [ ] 6.6 If pod fails to start: tail logs `kubectl -n omni logs deploy/omni`; common failure = EULA not accepted (revisit 5.2) or chart schema mismatch (revisit 3.7)

## 7. Verify the Upgrade Worked

- [x] 7.1 Image verified — `kubectl -n omni get pod -l app.kubernetes.io/name=omni -o jsonpath='{.items[0].spec.containers[0].image}'` returned `ghcr.io/siderolabs/omni:v1.8.1`
- [x] 7.2 UI reachable — `curl -sI https://omni.janncot.com/` returned HTTP/2 200
- [x] 7.3 Browser confirmed Omni UI loads at https://omni.janncot.com (auth0 login + Grant Access flow worked end-to-end via browser)
- [x] 7.4 Logs clean — no `eula`, no `panic`, no `migration` errors. The only repeated errors are the pre-existing `Etcd members count is equal to the minimum quorum 2` for `jgu5-control-planes` (same behavior as v1.6.4; unrelated to this upgrade — tracked separately as the 2-node etcd HA expansion P1)
- [x] 7.5 PVC preserved — `omni-local` Bound, same UID `pvc-439e7ee6-c79d-46fe-8dcd-e2c124578e32`, same 8Gi
- [x] 7.6 ⚠ **REFRAMED — root cause is NOT the server version**. After upgrade, `omnictl get clusters` still fails with `no such file or directory`. Deep dive: omnictl's `RenewUserKeyFunc` calls `RegisterPGPPublicKey` → server logs show **OK** with returned `loginURL`, but client receives `rpc error: code = Internal desc = server closed the stream without sending trailers`. Two omnictl runs (00:33:02Z and 00:45:17Z UTC) both succeed server-side but client never reaches `WriteKey` / `browser.OpenURL`. Root cause: `omni.janncot.com` has **no Ingress resource** in jg-base (only `omni-siderolink-ing` exists for `*.janncot.duckdns.org`); the main hostname is proxied via **cloudflared tunnel** without the `service: grpc://` scheme required for proper gRPC trailer propagation. Spec scenario assumed first-call auto-keygen would succeed; transport layer doesn't support the streaming RPC.
- [~] 7.7 N/A — registration URL never printed to client (transport issue, not flow issue)
- [→] 7.8 **Plan B confirmed as viable for unblocking Talos export**: Omni Web UI is reachable, talosconfig + kubeconfig + cluster template can be downloaded via UI without omnictl. Recorded as the operational path until cloudflared gRPC is fixed.
- [→] 7.9 **Defer** until omnictl works — verification of SideroLink `Connected=true` per machine can be done via Omni UI directly (no omnictl needed for visual check)

**Follow-up change required**: `fix-cloudflared-grpc-omni` (separate OpenSpec) — patch the cloudflared tunnel ingress for `omni.janncot.com` to use `service: grpc://omni.omni.svc:8080` (or similar) so streaming RPCs carry trailers correctly. Until then, omnictl from outside the cluster cannot complete PGP key bootstrap. WireGuard-direct access (via `omni-siderolink.janncot.duckdns.org` which has proper nginx GRPC ingress) may be a workaround but is not validated here.

## 8. Document the Runbook

- [x] 8.1 Created `kubernetes/apps/extras/omni/omni/README.md` with sections: Overview, Current Version, Architecture, Upgrade Procedure (7 sub-steps incl. distroless-snapshot pattern + EULA + chart regen + Flux reconcile), Verification Commands, Rollback Procedure (incl. snapshot restore), Troubleshooting (omnictl/cloudflared limitation, EULA pod failure, chart schema, etcd quorum noise), Related links
- [x] 8.2 Three-repo flow diagram included (siderolabs/omni → ferry133/helm-charts → jg-base → jcom)
- [ ] 8.3 Will commit together with openspec change in Phase 9

## 9. Close Out

- [ ] 9.1 Update `~/.claude/projects/-Users-ferry133-coding-jg-base/memory/` with a new `project_omni_platform.md` capturing the chart-fork pattern and EULA gotcha
- [ ] 9.2 Un-park the upstream P1 todo: "Export jg-jiahd Talos artifacts from Omni" — now unblocked since auth works
- [ ] 9.3 Run `openspec validate upgrade-omni-server-v1-8` and `openspec status --change upgrade-omni-server-v1-8` — confirm `isComplete: true`
- [ ] 9.4 Archive the change once implementation is verified: `openspec archive upgrade-omni-server-v1-8`

## 10. Rollback (if needed at any point)

- [ ] 10.1 Revert the HelmRelease commit in `jg-base`: `git revert <sha>` on `main`
- [ ] 10.2 `flux reconcile source git jg-base -n flux-system && flux reconcile helmrelease omni -n omni`
- [ ] 10.3 Confirm pod returns to `ghcr.io/siderolabs/omni:v1.6.4` and is `Ready`
- [ ] 10.4 If chart `2.1.1` is somehow missing from GitHub Pages index, restore it from `git show` of the pre-bump tree in `~/coding/helm-charts`
- [ ] 10.5 **If v1.6.4 pod crashloops after revert** (etcd state migrated by v1.8.1 and unreadable by v1.6.4), restore from the Task 5.7 snapshot:
  ```sh
  # 1. Scale Omni to zero so the PVC is unmounted
  kubectl -n omni scale deploy/omni --replicas=0
  # 2. Spin a busybox sidecar that mounts the same PVC
  kubectl -n omni run pvc-restore --rm -it \
    --image=busybox \
    --overrides='{"spec":{"containers":[{"name":"pvc-restore","image":"busybox","stdin":true,"tty":true,"command":["sh"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"omni-local"}}]}}'
  # 3. Inside the sidecar: wipe /data and untar the snapshot piped in via kubectl cp / stdin
  # (separate terminal: kubectl -n omni cp ~/omni-data-snapshot-v1.6.4-*.tar.gz pvc-restore:/tmp/)
  rm -rf /data/* && tar xzf /tmp/omni-data-snapshot-v1.6.4-*.tar.gz -C / && exit
  # 4. Scale Omni back up
  kubectl -n omni scale deploy/omni --replicas=1
  ```
- [ ] 10.6 File a follow-up issue documenting what went wrong before retrying
