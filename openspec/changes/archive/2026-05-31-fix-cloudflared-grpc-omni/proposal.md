## Why

`omnictl` from any machine outside the `jcom` cluster cannot complete PGP key
bootstrap against the upgraded Omni v1.8.1 server. The failure surfaces as
`Could not authenticate: open ~/.talos/keys/default-<id>.pgp: no such file or
directory` followed by `rpc error: code = Internal desc = server closed the
stream without sending trailers`. Server-side logs confirm `RegisterPublicKey`
returns OK with a valid `loginURL`, but the client never receives proper gRPC
trailers, so the renewal flow aborts before `WriteKey` / `browser.OpenURL` /
`AwaitPublicKeyConfirmation` can run. This was identified as the actual root
cause during the post-mortem of change `upgrade-omni-server-v1-8` (proposal
incorrectly attributed it to version mismatch).

Until this is fixed:

- The disaster-recovery P1 "export `jg-jiahd` Talos artifacts from Omni" can
  only progress via the Omni Web UI (`Plan B` path documented in the runbook).
- Any future Omni automation (CI service accounts, scripted cluster ops) that
  uses `omnictl` from outside the cluster is blocked.
- `omnictl` users have to repeatedly authenticate via browser flows that the
  CLI is supposed to bootstrap automatically.

The traffic path is `Cloudflare edge → cloudflared tunnel pod → envoy-external
Gateway → HTTPRoute "omni" → omni.omni.svc:8080 → Omni pod`. Trailers are
mandatory for gRPC (the response status code is in the trailer); whichever hop
strips them breaks the call.

## What Changes

- Identify the hop responsible for stripping HTTP/2 trailers between
  `omnictl` and Omni (Cloudflare edge, cloudflared, or Envoy — see design for
  candidate hypotheses and ordering).
- Apply the minimal configuration change to that hop so streaming and trailer-
  bearing gRPC calls (`auth.AuthService/RegisterPublicKey` and
  `auth.AuthService/AwaitPublicKeyConfirmation`, at minimum) succeed end-to-end.
- Verify by re-running the Phase 7 scenarios deferred in
  `upgrade-omni-server-v1-8`:
  - `omnictl get clusters` prints a registration URL (first call)
  - completing the browser flow → re-run succeeds and lists
    `jgu5-control-planes`
- Add a regression-style smoke test (manual checklist in the runbook is OK for
  now; future automation TBD) so chart/version bumps that touch the ingress
  path don't silently break gRPC again.
- Update the `omni-platform` capability spec's "omnictl PGP Keypair Auth
  Bootstraps Cleanly" requirement from "deferred" to "validated", moving the
  two scenarios back into a normal requirement.

**Out of scope:**
- General Cloudflare zone hardening (DDoS, WAF rules).
- Replacing the cloudflared tunnel with a different ingress mechanism (direct
  LoadBalancer, alternate DNS).
- Performance tuning of gRPC streaming.
- Adding service-account auth to `omnictl` workflows as an alternative path
  (separate concern; could be a third change if we decide we want it).

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `omni-platform`: the existing requirement "omnictl PGP Keypair Auth
  Bootstraps Cleanly" transitions from deferred (proposal acknowledged the
  scenarios are aspirational pending this change) to validated. The two
  scenarios under that requirement remain unchanged in wording — they just
  become actively verifiable rather than deferred.

## Impact

**Code / config potentially touched** (final scope determined in design):

- `kubernetes/apps/base/network/cloudflare-tunnel/app/helmrelease.yaml` —
  cloudflared `configMap.config.data.config.yaml` ingress entries (per-host
  override for `omni.janncot.com`?)
- `kubernetes/apps/extras/omni/omni/app/grpcroute.yaml` or `httproute.yaml`
  in the Omni extras — convert the main API route from HTTPRoute to GRPCRoute,
  or add a parallel GRPCRoute for the gRPC subset of methods
- Cloudflare zone settings (dashboard / `terraform` / `flarectl`) — the
  "Network → gRPC" toggle is a per-zone setting, may need enabling for the
  `janncot.com` zone
- `kubernetes/apps/extras/omni/omni/README.md` — remove the troubleshooting
  caveat once validated

**Validation surface:**

- After fix, both Phase 7 scenarios from `upgrade-omni-server-v1-8` MUST pass
  with `omnictl` v1.8.1 client against `omni.janncot.com`.
- Existing browser flows (Auth0 OIDC, Omniconfig download) MUST still work —
  this fix should not break the unary RPC path that is currently working.
- SideroLink connections via `omni-siderolink.janncot.duckdns.org` (which uses
  the nginx GRPC ingress, not cloudflared) MUST be unaffected.

**Stakeholders:**

- ferry133 (sole operator) — primary user of `omnictl`; whoever runs the next
  Omni upgrade will need automation to work eventually.
- Future Sidero-managed clusters that get added to this Omni — they don't care
  how trailers flow, but they care that `omnictl` works for routine ops.

**Risk surface:**

- Any change to the ingress layer affects every host routed through the same
  Gateway (cert-manager-webhook duckdns, all other `*.janncot.com` apps). The
  design must explain how the proposed change is scoped to the gRPC traffic
  only.
- Cloudflare zone settings affect ALL hostnames under `janncot.com`, including
  ones outside this k8s deployment. Be explicit about blast radius.
