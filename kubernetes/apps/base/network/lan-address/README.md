# lan-address

Finds one free address on the customer's LAN and publishes it as a
`CiliumLoadBalancerIPPool` named `pool-discovered`.

Only the `appliance` profile runs it. Every other profile declares its addresses
in `cluster.yaml`, and a second pool there would overlap the declared one —
Cilium rejects overlapping pools outright, whatever `disabled` says.

## Why it exists

An appliance is delivered to a LAN nobody has surveyed. Asking the customer
which addresses are free is asking the one question a zero-IT customer cannot
answer, so the cluster works it out instead. The three LAN-facing services share
a single address (`envoy-internal` 80/443, `k8s-gateway` 53, `mqtt` 1883 — no
overlap), which turns "find several free addresses" into "find one".

## The contract

**The pool is the only output.** Nothing else in the stack names this component:
no Service annotation, no template variable, no CUE field, no RBAC beyond
`pool-discovered` itself. That is deliberate — it is what makes the
implementation replaceable.

A replacement MUST:

- publish a `CiliumLoadBalancerIPPool` named `pool-discovered`, containing
  exactly one address, as a single-address block (`start` == `stop`)
- keep publishing the same address across restarts unless that address has
  actually been taken
- leave every other pool alone, in particular the `pool` rendered from
  `cluster.yaml`

A replacement MUST NOT require changes to Cilium configuration, Service
annotations, `jg-cluster-template` templates, or the CUE schema. If it does, the
contract has been broken and the boundary needs revisiting rather than widening.

## Why ARP is the first implementation and not the last

ARP proves only that nobody answered *just now*. It cannot prove the address is
outside the router's DHCP range, so a device that happens to be switched off can
still take the address later. The probe therefore re-checks its choice on every
pass and reselects when the address starts answering, recording the change on the
pool:

```
lan-address.jg-base/confirmed-at    last time the address was verified unanswered
lan-address.jg-base/previous        address it moved away from, if it moved
lan-address.jg-base/reselected-at   when that move happened
```

Reselection is a visible event, not a silent one — but it still means the LAN
services change address, which breaks anything that cached the old one.

**The real fix is to stop guessing.** A DHCP lease-holder — synthesising a MAC,
performing DHCPDISCOVER/REQUEST and renewing the lease — gets an address the
router has actually committed to, so nothing else can be given it. That is a new
component, not a change to this one, and the pool interface above is what lets it
be dropped in.

## Scan order

Downward from the top of the subnet (`.254` → `.200`). Routers hand out leases
from the low end far more often than the high end, so the top is the likeliest
place to find something that stays free. Addresses the node itself holds are
excluded, as is `.1` — conventionally the gateway.

Only `/24` subnets are supported; anything else exits with an error rather than
walking a range it was not designed for.
