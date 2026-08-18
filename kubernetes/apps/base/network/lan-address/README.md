# lan-address

Finds two free addresses on the customer's LAN and publishes them as two
`CiliumLoadBalancerIPPool`s: `pool-discovered` and `pool-discovered-external`.

Only the `appliance` profile runs it. Every other profile declares its addresses
in `cluster.yaml`, and a second pool there would overlap the declared one —
Cilium rejects overlapping pools outright, whatever `disabled` says.

## Why it exists

An appliance is delivered to a LAN nobody has surveyed. Asking the customer
which addresses are free is asking the one question a zero-IT customer cannot
answer, so the cluster works it out instead.

## Why two addresses, and therefore two pools

The three LAN-facing services share a single address (`envoy-internal` 80/443,
`k8s-gateway` 53, `mqtt` 1883 — no overlap) through Cilium's sharing key.
`envoy-external` cannot join them: it listens on the same 80/443 as
`envoy-internal`, and Cilium only shares an address between services whose ports
do not collide. So there are two consumers and two addresses.

**They are published as two selector-scoped pools rather than one pool holding
both addresses, because one pool does not express the allocation — it only
permits it.** Cilium walks a pool's blocks in order, so which consumer ends up
with which address is a convention, not a constraint. If `envoy-external` takes
the shared address it evicts `envoy-internal`, `k8s-gateway` and `mqtt`
together, and the symptom is *total* LAN DNS failure rather than partial: every
name in the cluster domain goes NXDOMAIN while the same names keep answering
over the public tunnel, because cloudflared's origin is a ClusterIP and never
needed the LB address. That asymmetry is what keeps the failure invisible. See
ferry133/jg-base#9, and `jgt-appliance` `bc63c81` for the version that produced
it in practice.

Two pools with different addresses cannot overlap, and neither consumer can
reach the other's pool, so nothing depends on ordering.

## The contract

**The two pools are the only output.** Nothing else in the stack names this
component: no Service annotation, no template variable, no CUE field, no RBAC
beyond those two pool names. That is deliberate — it is what makes the
implementation replaceable.

A replacement MUST:

- publish two `CiliumLoadBalancerIPPool`s, `pool-discovered` and
  `pool-discovered-external`, each containing exactly one address as a
  single-address block (`start` == `stop`), and each carrying the
  `serviceSelector` described below
- keep publishing the same address on the same pool across restarts unless that
  address has actually been taken
- leave every other pool alone, in particular the `pool` rendered from
  `cluster.yaml`

A replacement MUST NOT require changes to Cilium configuration, Service
annotations, `jg-cluster-template` templates, or the CUE schema. If it does, the
contract has been broken and the boundary needs revisiting rather than widening.

### The two selectors are complements of one predicate

```yaml
# pool-discovered — the shared LAN address
serviceSelector:
  matchExpressions:
    - key: gateway.envoyproxy.io/owning-gateway-name
      operator: NotIn
      values: ["envoy-external"]

# pool-discovered-external
serviceSelector:
  matchLabels:
    gateway.envoyproxy.io/owning-gateway-name: "envoy-external"
```

Complements, not two enumerations. Enumerating the sharing group by name would
mean a LAN-facing service added later matches nothing and waits forever, and the
list of things it forgot would not appear in any result — so the shared pool is
defined as *everything that is not `envoy-external`* instead.

Three things this depends on, all checked against the deployed versions rather
than assumed:

- Cilium matches the selector against the Service's own labels plus a reserved
  `io.kubernetes.service.name` / `io.kubernetes.service.namespace` it injects
  (`operator/pkg/lbipam/service_store.go:186`, v1.19.1).
- A `NotIn` requirement matches a Service that does not carry the key at all
  (vendored `k8s.io/apimachinery/pkg/labels/selector.go`, v1.19.1). This is what
  puts `k8s-gateway` — a Helm chart Service with no Envoy Gateway labels — on
  the shared side.
- The key is Envoy Gateway's own label naming the Gateway a proxy Service
  belongs to, *not* the Service name. The generated Service name has changed
  shape across Envoy Gateway releases; on the deployed v1.7.0 it happens to be
  `envoy-external`, but that is a coincidence this must not rest on.

Verified 2026-08-19 against the live `jgt-appliance` API by listing every
Service in the cluster under each selector: the two sets are disjoint and their
union is every Service. `daily-check` re-checks the *consequence* daily — that
`envoy-external` holds the external pool's address and the sharing group holds
the shared one — because a selector that silently stops matching produces a
cluster that looks exactly like a healthy one until something reshuffles.

## Why ARP is the first implementation and not the last

ARP proves only that nobody answered *just now*. It cannot prove the address is
outside the router's DHCP range, so a device that happens to be switched off can
still take the address later. The probe therefore re-checks its choices on every
pass and reselects when an address starts answering, recording the change on the
pool that moved:

```
lan-address.jg-base/confirmed-at    last time the address was verified unanswered
lan-address.jg-base/previous        address it moved away from, if it moved
lan-address.jg-base/reselected-at   when that move happened
```

Reselection is a visible event, not a silent one — but it still means a LAN
service changes address, which breaks anything that cached the old one.

**The real fix is to stop guessing.** A DHCP lease-holder — synthesising a MAC,
performing DHCPDISCOVER/REQUEST and renewing the lease — gets an address the
router has actually committed to, so nothing else can be given it. That is a new
component, not a change to this one, and the pool interface above is what lets
it be dropped in.

## Scan order

Downward from the top of the subnet (`.254` → `.200`). Routers hand out leases
from the low end far more often than the high end, so the top is the likeliest
place to find something that stays free. Addresses the node itself holds are
excluded, as is `.1` — conventionally the gateway.

The shared address is filled first. When only one address is free, the shared
pool gets it — that is the one carrying LAN DNS — and `envoy-external` is
visibly `<pending>` rather than quietly taking the shared address, which is the
whole point of scoping the pools.

Only `/24` subnets are supported; anything else exits with an error rather than
walking a range it was not designed for.
