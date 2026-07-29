## Why

Remote client support today (the `claude_instances` / `cc.<client-domain>` web terminals deployed via `claudecode/claude-code`) has no safe way to query a client's Talos layer. The only credential in the system capable of doing so is the operator's own break-glass talosconfig — permanent-root, unscoped across every cluster it's ever been issued for. During the 2026-07-27 jg-jiahd Omni "Not Ready" incident, diagnosing a SideroLink connectivity failure required manually copying that break-glass credential into a throwaway pod, twice blocked by the security-review classifier before an explicit one-time authorization was given. That workflow doesn't scale to routine client support and isn't something a resident client-side agent can self-serve.

Talos natively supports scoped, role-based client certificates (`os:reader`/`os:operator`/`os:admin`) independent of Omni, but nothing in this stack currently issues, stores, or wires one in. This change gives each client's `cc.<domain>` instance a permanently-resident, read-only Talos credential — isolated from the agent's own shell — so it can self-diagnose the class of issue seen on 2026-07-27 without any operator involvement or credential ever crossing the remote-operator boundary.

## What Changes

- New `talos-mcp` sidecar container added to each `claude_instances` pod (mirrors the existing `oauth2-proxy` sidecar pattern: same pod, own container filesystem, reachable only via loopback since the pod is `hostNetwork: true`).
- New `talos_mcp_server.py` (FastMCP, HTTP/SSE transport, bound to `127.0.0.1`) exposing read-only diagnostic tools backed by a bundled `talosctl` binary: node status, etcd member list, network link status (SideroLink/KubeSpan), service logs.
- New per-cluster Talos credential: an `os:reader`-scoped client certificate (`talosctl config new --roles=os:reader`), bootstrapped once per client from the operator's existing break-glass config, stored SOPS-encrypted in that client's own `cluster-secrets.sops.yaml`, and mounted **only** into the `talos-mcp` container — never the `app` container the terminal user/agent shell runs in.
- `claude-session` registers `talos-mcp`'s HTTP endpoint as a remote MCP server (new pattern — the existing `memory` MCP server is a local stdio subprocess, which cannot provide this isolation property).
- Mutating Talos operations (reboot, config apply, etc.) are explicitly **out of scope** for this change — `os:reader` certs are rejected by the Talos API server-side for any write RPC, so this is a hard boundary, not a policy one. Elevated/mutating access remains the existing manual, ephemeral, explicitly-authorized break-glass workflow.

## Capabilities

### New Capabilities
- `talos-mcp-sidecar`: isolated, read-only Talos API access for `claude_instances` pods — credential bootstrap, sidecar container, MCP server, and the secret-provisioning pipeline that gets a scoped credential from `cluster.yaml` into the running sidecar.

### Modified Capabilities
(none — this does not change Omni platform behavior or requirements; it works around Omni's lack of per-cluster credential scoping by using Talos's own native RBAC directly)

## Impact

- **k8scc** (`ghcr.io/ferry133/claude-code` image source): new `talos_mcp_server.py`, `talosctl` binary added to the Dockerfile, CLAUDE.md updated.
- **jg-cluster-template**: new `cluster.schema.cue` field, new `cluster-secrets.sops.yaml.j2` key (base64-wrapped, following the existing `OMNI_GPG_KEY_B64` pattern for multi-line secret content), new sidecar container block in `instances/helmrelease.yaml.j2`, `cluster.sample.yaml` documentation.
- **jg-base**: no change to the shared `claude-code` app plumbing (`ocirepository.yaml`/`rbac.yaml`/`secret.yaml`) — the existing shared `cluster-admin` ServiceAccount/RBAC for the `app` container is untouched and out of scope for this change.
- **jg-jiahd**: reference implementation / first rollout target — rendered `instances/helmrelease.yaml` gets the new sidecar, plus a manually-bootstrapped `os:reader` credential for this specific cluster.
- **Operator workflow**: one new manual step per client onboarding (mint the `os:reader` cert using the existing break-glass config, paste into `cluster.yaml`) — no change to `task configure`'s automated pipeline beyond picking up the new field.
