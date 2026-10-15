## MODIFIED Requirements

### Requirement: Isolated Talos credential per client

Each `claude_instances` pod that has a Talos MCP sidecar enabled SHALL hold up to two Talos client credentials, both resolving only to that client's own cluster and both distinct from any operator-held credential: a **reader credential** whose role ceiling is `os:reader` (an Omni Reader-role service account's talosconfig, routed through Omni), and an OPTIONAL **operator credential** whose role ceiling is `os:operator` (an Omni break-glass talosconfig, routed directly to the nodes on the LAN). The operator credential's absence SHALL leave the sidecar behaving exactly as a reader-only sidecar.

#### Scenario: Credential is cluster-specific
- **WHEN** either credential is bootstrapped for a client — the reader one as a dedicated Omni service account holding the Omni `Reader` role, the operator one as `omnictl talosconfig --cluster <that cluster> --break-glass`
- **THEN** each credential resolves only to that client's own cluster and cannot reach any other cluster's Talos API

#### Scenario: Credential role is read-only
- **WHEN** the `talos-mcp` sidecar's reader credential attempts a mutating or admin-only Talos API call (e.g. reboot, config apply, upgrade, client-certificate minting)
- **THEN** the call is rejected server-side by the credential's `os:reader` role ceiling, independent of what the calling code requests

#### Scenario: Operator credential cannot reset or reconfigure
- **WHEN** the `talos-mcp` sidecar's operator credential attempts an admin-only Talos API call (reset, apply-config, upgrade, client-certificate minting)
- **THEN** the call is rejected server-side by the credential's `os:operator` role ceiling, independent of what the calling code requests

#### Scenario: Empty operator credential means absent
- **WHEN** the operator credential's Secret key is present but empty (the template field was not set, so Flux substituted `${TALOS_OPERATOR_CONFIG_B64:-}` to nothing)
- **THEN** the sidecar treats the operator credential as absent — no mutating tool is registered and no direct-LAN fallback is attempted — rather than failing on a zero-byte talosconfig

### Requirement: Credential isolated from the agent shell

Both Talos credentials — the reader talosconfig with the Omni service-account key and endpoint it needs, and the operator talosconfig — SHALL be mounted only into the `talos-mcp` sidecar container's own filesystem/environment, never into the `app` container where the terminal user and Claude Code agent process run.

#### Scenario: Agent shell cannot read either credential
- **WHEN** a user or the Claude Code agent runs a shell command inside the `app` container (e.g. `cat`, `env`, `ls`, `find / -name '*talosconfig*'`)
- **THEN** no path or environment variable in that container exposes the raw contents of either credential

#### Scenario: Sidecar reachable only within the pod
- **WHEN** the `talos-mcp` sidecar's MCP server is running
- **THEN** it is bound to a loopback address reachable only from other containers in the same pod, not from the client's LAN or the public internet

### Requirement: Read-only Talos diagnostic tools available via MCP

The `app` container's Claude Code agent SHALL have access, via a registered remote MCP server, to read-only Talos diagnostic tools: node status, etcd member list, network link status (SideroLink/KubeSpan), and service logs. Each tool SHALL try the Omni-proxied path with the reader credential first and, when that path fails and the operator credential is present, retry once directly against the named node on the LAN with the operator credential; the response SHALL state which path answered.

#### Scenario: Agent queries node status without operator involvement
- **WHEN** the Claude Code agent in a ttyd session calls the Talos MCP `get_node_status` tool for a node in its own cluster
- **THEN** it receives the node's Talos version/health status without any credential being supplied by, or visible to, the remote operator

#### Scenario: Agent diagnoses a SideroLink-style connectivity issue unassisted
- **WHEN** the Claude Code agent calls `get_link_status` and `get_etcd_members` for nodes in its own cluster
- **THEN** it receives link state and etcd membership data sufficient to distinguish "node/cluster unhealthy" from "management-plane connectivity issue," without the remote operator generating or transmitting any Talos credential

#### Scenario: Management plane down, node still answers on the LAN
- **WHEN** a node's SideroLink to Omni is down so the Omni-proxied call to it times out or returns `Unavailable`, and the operator credential is present
- **THEN** the same read tool answers from the node directly over the LAN and its first line (after the expiry warning line, when one is present) reads `[via direct LAN]`, so the agent can read the node's own `siderolink` link state during the very outage that hides it from Omni

#### Scenario: Management plane down, no operator credential
- **WHEN** the Omni-proxied call fails and no operator credential is present
- **THEN** the tool returns the Omni-path error and names the direct-LAN fallback as unavailable on this cluster, so the agent reports a credential gap rather than a dead node

## REMOVED Requirements

### Requirement: No mutating Talos capability introduced
**Reason**: 2026-10-11 showed the "manual, ephemeral break-glass workflow" this requirement deferred to costs the operator company ~3 hours and the on-site agent nothing it can do; the company's on-site agent (`im`) must be able to graceful-reboot a node of the cluster it maintains on its own diagnosis. `im` is the company's tool and only company staff reach it (ferry133 ruling 2026-10-15, superseding the 2026-10-12 wording "with the on-site human's approval"), so the gate is server-side, never a human prompt.
**Migration**: Replaced by "Gated mutating capability" below; the reader credential's read-only ceiling is unchanged, and the mutating tool exists only where an operator credential has been provisioned per `operator-credential-lifecycle`.

## ADDED Requirements

### Requirement: Gated mutating capability

The sidecar SHALL expose exactly one mutating tool, a graceful node reboot, and only while a non-empty, readable and unexpired operator credential is mounted. The tool's call contract (two-phase confirmation, call-time node allowlist, audit line, own-node handling, and — since the 2026-10-15 ruling — the server-side guardrails: control-plane quorum, per-node cooldown, caller-supplied reason) is specified in `k8scc`'s `talos-operator-escalation` capability; this requirement fixes the sidecar-level conditions. No human approval is part of the contract: the sidecar SHALL NOT depend on the agent's permission profile prompting anyone.

#### Scenario: No operator credential, no mutating tool
- **WHEN** the MCP server's tool list is inspected on a sidecar whose operator credential is absent or empty
- **THEN** it contains only the four read-only diagnostic tools; `reboot_node` is not present

#### Scenario: Operator credential present, one mutating tool
- **WHEN** the MCP server's tool list is inspected on a sidecar whose operator credential is mounted, non-empty, readable and unexpired
- **THEN** it contains the four read-only tools plus `reboot_node`, and no tool capable of reset, apply-config, upgrade, shutdown or certificate minting

#### Scenario: Node outside this cluster is refused
- **WHEN** `reboot_node` is called with an IP that is not an InternalIP of a node in this cluster at call time
- **THEN** the call is refused before any Talos API call is made, and the refusal is written to the audit line

#### Scenario: No human prompt is relied upon
- **WHEN** the agent calls `reboot_node` under a permission profile that auto-allows the tool (no prompt, nobody at the terminal)
- **THEN** the only gates are the sidecar's own: credential present, node allowlisted at call time, two-phase token, and the server-side guardrails; the audit line is written regardless of how the agent's permission layer resolved the call
