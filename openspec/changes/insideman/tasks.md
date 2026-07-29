## 1. Bootstrap and validate against jg-jiahd (no pipeline changes yet)

- [ ] 1.1 Run `talosctl config new --roles=os:reader <output>` against jg-jiahd using the existing break-glass talosconfig (`jg-jiahd/talos/clusterconfig/talosconfig`); save the resulting scoped config locally (not committed).
- [ ] 1.2 Verify the scoped config's actual permission surface against jg-jiahd nodes: confirm `talosctl version`, `talosctl etcd members`, `talosctl get links` succeed, and confirm a mutating call (e.g. `talosctl reboot` on a non-critical check, or inspect the RPC-level rejection) is rejected server-side.
- [x] 1.3 Write `talos_mcp_server.py` in `k8scc` (FastMCP, HTTP/SSE transport, bind `127.0.0.1:<port>`) with tools: `get_node_status`, `get_etcd_members`, `get_link_status`, `get_service_logs` — each shelling out to the bundled `talosctl` binary against `TALOSCONFIG` env/path.
- [ ] 1.4 Manually run `talos_mcp_server.py` in a throwaway pod/container against jg-jiahd (mirroring the ephemeral-pod pattern from the 2026-07-27 incident) using the scoped config from 1.1, and confirm each tool returns correct data for jg-jiahd's three nodes.

## 2. k8scc image changes

- [x] 2.1 Add `talosctl` binary download to the Dockerfile (pin version to match the Talos server version in use; parametrize similarly to `TTYD_VERSION`).
- [x] 2.2 Add `talos_mcp_server.py` to the image (`COPY` + chmod, alongside `memory_mcp_server.py`).
- [x] 2.3 Confirm the `talos-mcp` container will run via a `command` override (`python3 /usr/local/bin/talos_mcp_server.py`) rather than `entrypoint.sh` — no changes needed to `entrypoint.sh`/`claude-session` for the sidecar's own startup.
- [x] 2.4 Add the remote-MCP registration block to `claude-session`: when the sidecar's endpoint is present (env-gated, matching the existing `claudecode_auth0_domain`-conditional pattern), register it in `~/.claude/settings.json` as a remote MCP server (URL-based), alongside the existing local `memory` stdio entry.
- [x] 2.5 Update `k8scc/CLAUDE.md`: document the `talos-mcp` sidecar, its credential model, and the tool surface. While in there, fix the pre-existing staleness noted during design research (dead `AUTH0_DOMAIN`/`AUTH0_CLIENT_ID` device-flow entries in the Runtime Configuration table; missing `TTYD_INTERFACE`/`TTYD_AUTH_HEADER`).
- [ ] 2.6 Build and push the image via the existing CI workflow; confirm the new short-SHA tag.

## 3. jg-cluster-template pipeline changes

- [x] 3.1 Add `talos_mcp_config?: string` to `.taskfiles/template/resources/cluster.schema.cue`.
- [x] 3.2 Add `TALOS_MCP_CONFIG_B64: "#{ talos_mcp_config | default('') | b64encode }#"` to `templates/config/kubernetes/components/sops/cluster-secrets.sops.yaml.j2`.
- [x] 3.3 Decide and implement: dedicated `talos-mcp-secret` vs. new key on existing `claude-code-secret` (see design.md Open Questions) — add the corresponding Flux-var-substituted Secret definition under `jg-base/kubernetes/apps/extras/claudecode/claude-code/app/` if dedicated, or extend `secret.yaml` if not. **Decided: dedicated** (`talos-mcp-secret.yaml`).
- [x] 3.4 Decide and implement: Secret-volume-file vs. base64-env for how `talos-mcp` consumes the credential (see design.md Open Questions). **Decided: volume-file** (`data.talosconfig`, base64 pre-encoded, mounted at `/etc/talos-mcp/talosconfig`).
- [x] 3.5 Add the `talos-mcp` container block to `templates/config/kubernetes/apps/extras/claudecode/claude-code/instances/helmrelease.yaml.j2` (mirrors the existing `oauth2-proxy` container block: own image/command, own securityContext non-root + `drop: ALL`, own resources sized like `oauth2-proxy`, own volume/env for the credential, no shared mounts with `app`). Gated on `talos_mcp_config is defined`, independent of the auth0/OIDC gate.
- [x] 3.6 Document `talos_mcp_config` in `cluster.sample.yaml` under the `claudecode/claude-code` extra section, including the bootstrap command from task 1.1 as inline guidance for future client onboarding. **Correction from 1.1's finding**: break-glass configs may carry `os:operator` only (insufficient to mint new certs) -- doc now says "needs os:admin" explicitly.

## 4. Roll out to jg-jiahd and verify end-to-end

- [ ] 4.1 Mirror the `instances/helmrelease.yaml.j2` sidecar block into jg-jiahd's rendered `kubernetes/apps/extras/claudecode/claude-code/instances/helmrelease.yaml` (same two-repo sync convention used for all prior `claude_instances` changes this session).
- [ ] 4.2 Add jg-jiahd's `talos_mcp_config` (base64 of the task-1.1 credential) to jg-jiahd's `cluster.yaml`, run `task configure`.
- [ ] 4.3 Commit and push jg-cluster-template, jg-base (if secret definition added there), and jg-jiahd changes; reconcile Flux.
- [ ] 4.4 Verify the `talos-mcp` container comes up healthy in the `cc` pod, and confirm (e.g. via `kubectl exec` into `app`) that the credential file/env is genuinely absent from the `app` container's filesystem.
- [ ] 4.5 From a real ttyd session (as the Claude Code agent, not via kubectl), call each of the four MCP tools and confirm correct results against jg-jiahd's live nodes.
- [ ] 4.6 Confirm a mutating attempt through the MCP path is rejected (either by omission — no such tool exists — and/or by directly testing the underlying credential's server-side rejection as in task 1.2).
