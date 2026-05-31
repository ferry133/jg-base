## Context

### The failing call path

```
omnictl (Mac, grpc-go/1.81.0)
   │  TLS 1.3, HTTP/2, gRPC
   ▼
Cloudflare edge (proxy mode, janncot.com zone)
   │  HTTP/2 (cloudflared protocol: quic or http2 per env var)
   ▼
cloudflared tunnel pod (network ns, jcom cluster)
   │  current ingress: service: https://envoy-external.network.svc:443
   │                   originRequest.http2Origin: true
   ▼
envoy-external Gateway (LoadBalancer 10.9.8.5, envoy-gateway controller)
   │  HTTPRoute "omni" — hostname "omni.janncot.com"
   ▼
omni.omni.svc:8080 (Omni's main HTTP+gRPC multiplexed port)
   ▼
Omni pod
```

### What we observed

- Server logs show TWO recent `RegisterPublicKey` calls (timestamps `00:33:02Z`
  and `00:45:17Z` UTC on 2026-05-31), both `grpc.code: OK`, both returning a
  valid `loginUrl`.
- Client (`omnictl`) on both calls reports `rpc error: code = Internal desc =
  server closed the stream without sending trailers`.
- `omnictl` never writes the locally-generated PGP key to
  `~/.talos/keys/default-ferry133@gmail.com.pgp` — because the error returns
  before reaching `WriteKey` in `renewUserKeyViaAuthFlow`. The `~/.talos/keys`
  directory mtime DOES advance (from `ensureCustomPath` calling `MkdirAll`),
  confirming the code reaches the path-resolution step.
- Unary RPCs that don't depend on trailers being meaningfully populated
  *appear* to work — Auth0 OIDC and `Omniconfig` succeed in the browser. But
  every gRPC response carries trailers, so "works" here means "the client
  didn't notice missing trailers because no payload was after". Streaming RPCs
  (`AwaitPublicKeyConfirmation`) and unary RPCs where the client strictly
  validates trailers (`RegisterPublicKey` from `grpc-go` 1.81+) fail.

### Hop-by-hop suspects

| Hop | Could strip trailers? | Evidence |
|---|---|---|
| Cloudflare edge (orange-cloud proxied) | Yes — zone-level "gRPC" toggle must be ON | Cloudflare docs explicitly call this out as required for gRPC |
| cloudflared tunnel | Yes — if `service` is `https://` to a non-gRPC-aware origin, trailers may be lost | Current config uses `https://` + `http2Origin: true`, which is the *Cloudflare-recommended* form for gRPC. Still suspect because the origin (envoy) speaks HTTP, not raw gRPC, and we're routing through Envoy Gateway not directly to Omni |
| envoy-external Gateway | Yes — HTTPRoute is for HTTP traffic; for gRPC, Envoy Gateway supports `GRPCRoute` as a distinct kind | Currently using `HTTPRoute "omni"`. Upstream Omni chart ships `templates/gatewayApi/httproute-ui.yaml` for the UI on the same port. Mixing HTTP and gRPC on one HTTPRoute is the suspicious config. |
| omni pod | No — server logs confirm OK responses with trailers | Server log entries show full `grpc.response.content` populated |

The single strongest hypothesis is **HTTPRoute being used where a GRPCRoute is
required**. Envoy can serve gRPC over an HTTPRoute, but trailer handling under
HTTPRoute is best-effort; GRPCRoute exists specifically to signal "this is gRPC
traffic, preserve trailers and stream framing." The fact that server-side logs
show OK while client-side sees missing trailers points directly at an
intermediary (most likely Envoy under HTTPRoute) silently dropping them.

The second strongest is the Cloudflare zone-level "gRPC" toggle. Reportable
fact: we don't yet know if it's enabled — needs a glance at the dashboard.

## Goals / Non-Goals

**Goals:**

- Restore end-to-end gRPC trailer propagation from omnictl through to Omni,
  with no regression to existing HTTP-only traffic on the same Gateway.
- Keep the fix minimal and scoped — preferably one file or one toggle.
- Document the fix well enough that the next operator can replicate it on a
  fresh cluster bootstrap (it's bound to come up again).
- Reactivate the two `omnictl` PGP scenarios in the `omni-platform` capability
  spec.

**Non-Goals:**

- Switching `omni.janncot.com` off the cloudflared tunnel.
- Migrating away from Envoy Gateway to nginx (or vice versa).
- Refactoring the cloudflared tunnel's catch-all `*.${SECRET_DOMAIN}` rule.
- General gRPC support for other hostnames (we will measure: does any other
  current app need streaming gRPC? If not, scope this strictly to omni).

## Decisions

### D1: Hypothesis-test in priority order before changing anything

Rather than committing to a single fix candidate up front, the implementation
phase will follow an investigative ordering. Each step is cheap and
non-destructive:

1. **Read Cloudflare dashboard** for the `janncot.com` zone, Network → gRPC
   toggle. If OFF: enable it. This is a zone-wide setting (acceptable risk —
   gRPC ON does not break HTTP traffic).
2. **Check HTTPRoute vs GRPCRoute on the Omni route**. The upstream Omni chart
   v1.8.1 ships both `httproute-ui.yaml` and `grpcroute-siderolink.yaml`. The
   main `omni.janncot.com` host is currently served by HTTPRoute. **The most
   correct fix is to add a parallel GRPCRoute** (matching gRPC paths like
   `/auth.AuthService/*`, `/management.ManagementService/*`) so streaming RPCs
   flow through the gRPC path while UI traffic stays on HTTPRoute.
3. **Verify cloudflared ingress** is using `service: http2://...` or
   `service: https://...` with `http2Origin: true`. Currently
   `https://envoy-external.network.svc:443` + `http2Origin: true`. Per
   Cloudflare docs, this is the recommended form for gRPC origins. If steps 1
   & 2 don't fix things, then look here.

We will not change all three at once — that loses signal. After each step we
re-test `omnictl get clusters` and observe.

**Alternative considered:** going straight to switching `service:` to
`grpc://...` in cloudflared. Rejected because:
(a) Cloudflare's `grpc://` service scheme is for tunnel ingress that *speaks
gRPC natively to its origin*, not for fronting an HTTP/2-multiplexed reverse
proxy like Envoy. Using it here may break unary HTTP traffic for
`omni.janncot.com`.
(b) The same cloudflared ingress catches `*.${SECRET_DOMAIN}` — changing it
affects every host routed through the tunnel.

### D2: Where to add the GRPCRoute

The upstream Omni chart's `grpcroute-siderolink.yaml` template is opt-in via
`gatewayApi.enabled` and a separate hostname (`*.siderolink.example.com` in
defaults). For our case we want a GRPCRoute on the **same** hostname
(`omni.janncot.com`) but matching only gRPC method paths (`/<package>.<service>/*`).

Two options:

| Option | Trade-off |
|---|---|
| **Override chart templates** via HelmRelease values (if upstream supports custom hostnames + path matching) | No new YAML; goes away on chart upgrade if upstream changes the template name |
| **Add a sibling GRPCRoute manifest in `extras/omni/omni/app/`** (not chart-generated) | Independent of chart; survives upgrades; clearer ownership |

**Decision: sibling GRPCRoute.** Reason: this is a per-deployment routing
decision that depends on our specific ingress layout; it shouldn't live in the
chart fork (which we want kept identical to upstream for clean upgrades — per
the `upgrade-omni-server-v1-8` change's chart-fork pattern).

### D3: How to scope the GRPCRoute matches

The GRPCRoute should route only **gRPC service calls** to `omni:8080`, while
HTTPRoute keeps serving the Web UI and static assets. gRPC service paths
follow `/<package>.<Service>/<Method>` (e.g., `/auth.AuthService/RegisterPublicKey`).
At minimum, match these gRPC services to start:

- `auth.AuthService` (PGP key registration + confirmation)
- `management.ManagementService` (Omniconfig + many others)
- `cluster.ClusterService` (clusters resource)
- `omni.machine.MachineService` (machines)

Or — simpler — match all paths beginning with `/<something>.<something>/` (a
typical gRPC pattern). The risk of overlap with REST API paths like
`/api/v1/...` is low because Omni's HTTP API uses different prefixes (no
`/<package>.<Service>/` pattern). We'll confirm during T1 by inspecting Omni's
HTTP route table.

**Decision: explicit allowlist of known gRPC service names.** Reason: safer than
a wildcard. New services added by upstream Omni won't be auto-routed via gRPC,
but that's fine — we'll add them when needed, and our future upgrades will
catch it (renewal test in regression checklist).

### D4: Cloudflare zone gRPC toggle

Even with a proper GRPCRoute, the Cloudflare edge zone setting matters. The
edge proxy must be aware that traffic is gRPC to preserve trailers and HPACK
table handling. Setting this to ON is zone-wide.

**Decision: enable it.** Reason: it's a no-op for non-gRPC traffic; Cloudflare
explicitly documents that turning it on does not affect HTTP performance. The
only risk is if some other hostname under `janncot.com` is sensitive to gRPC
inference being on — for ferry133's home-ops setup, no such workload exists.

### D5: Validation strategy

After each step in D1, run the **same** validation command sequence:

```sh
rm -f ~/.talos/keys/*.pgp                                    # clean state
omnictl get clusters --omniconfig ~/.talos/omni/config 2>&1  # see the failure or success
ls -la ~/.talos/keys/                                        # was a key written?
```

Stop as soon as the call either succeeds or prints a `loginUrl` for browser
confirmation. Server logs (`kubectl -n omni logs deploy/omni`) are the
ground-truth check: even when the client sees "stream closed", the server
should log `RegisterPublicKey ... grpc.code: OK` — that confirms the failure
is purely transport-layer.

## Risks / Trade-offs

- **R1: Adding a GRPCRoute on the same hostname as HTTPRoute may conflict at
  the Gateway API resolution layer**  
  → Mitigation: GRPCRoute and HTTPRoute are designed by Gateway API to coexist
  (each with its own match rules). Envoy Gateway documents this pattern. We
  validate by hitting both a UI path and a gRPC service after the change.

- **R2: Enabling Cloudflare zone gRPC silently changes behavior of another
  host on the zone**  
  → Mitigation: enumerate all `*.janncot.com` hostnames currently in use
  (probably easy — they all live in this repo's manifests + the linebot
  external setup). If any of them is sensitive, document the change before
  applying.

- **R3: cloudflared tunnel HTTP/2 default may not propagate trailers even when
  the rest of the path is gRPC-aware**  
  → Mitigation: this is exactly what step D1.3 in the investigation order
  tests. Have alternative `service: http2://...` config ready if needed.

- **R4: Tear-down risk during testing — if a misconfigured GRPCRoute is
  applied, omni.janncot.com may stop serving anything**  
  → Mitigation: apply via PR + Flux reconcile cycle so revert is git revert +
  reconcile (the same rollback pattern as `upgrade-omni-server-v1-8`). Do not
  hot-apply via kubectl. Keep a verification cycle that exercises both UI
  (`curl -sI`) and gRPC (`omnictl`) after each change.

- **R5: The fix turns out to be a deeper bug in cloudflared or Envoy Gateway
  that requires upstream change**  
  → Mitigation: scoped time-box of ~3 hours on the investigation. If we hit a
  dead-end, the fallback workaround is to expose Omni's gRPC via a separate
  hostname (e.g., `omni-grpc.janncot.duckdns.org`) using the existing nginx
  ingress with `backend-protocol: GRPC` (which we know works — that's
  how `omni-siderolink-ing` is configured). omnictl would then point at the
  new hostname. This is a worse user experience but unblocks automation.

## Open Questions

- **OQ-1**: Is the Cloudflare zone gRPC toggle currently ON or OFF? (resolve
  in T1)
- **OQ-2**: Do any other `*.janncot.com` hostnames depend on the zone's gRPC
  toggle being OFF? (resolve in T1 by enumerating hosts and their workloads)
- **OQ-3**: Does upstream Omni's `grpcroute-siderolink.yaml` template require
  modification, or can we leave it as-is and add our own sibling
  GRPCRoute? (resolve in T2)
- **OQ-4**: Can a single GRPCRoute cover all four gRPC services we listed in
  D3, or must we shard them across multiple GRPCRoutes (Gateway API
  precedence rules vary by controller)? (resolve in T2 — check Envoy Gateway's
  GRPCRoute conformance)
- **OQ-5**: Is there an `omnictl serviceaccount`-based path that avoids the
  streaming PGP confirmation entirely? If yes, would it survive the same
  transport issue? (out-of-scope for the fix here, but worth noting as
  fallback — track in a follow-up if needed)

## Migration Plan

(Sketch only — full task list comes in `tasks.md` once we move past
proposal+design.)

1. Read Cloudflare dashboard, enumerate hosts, decide on toggle.
2. (If toggle change needed) Apply zone setting; re-test.
3. (If insufficient) Author a `extras/omni/omni/app/grpcroute.yaml`; PR +
   reconcile + test.
4. (If still insufficient) Adjust cloudflared ingress config; PR + reconcile +
   test.
5. Update `omni-platform` capability spec to remove the "deferred" status from
   the omnictl PGP requirement.
6. Update `extras/omni/omni/README.md` troubleshooting section to mark the
   gRPC limitation as resolved and refer back to this change.

**Rollback:** every step is git-revertable. PVC state on Omni is unaffected by
any of these changes (network-layer only). Worst case `omni.janncot.com`
becomes unreachable — revert the relevant manifest, Flux reconciles, traffic
restores.
