# tenant-isolation-baseline Specification

## Purpose
The floor every cluster carries before any tenant exists (sub-change of `fleet-ops` / `standalone-app-repos`, archived 2026-10-20): a `tenant-admin` ClusterRole that is the ceiling of a tenant's identity, admission policies so a tenant cannot take an existing hostname or a shared-pool LAN address, and a daily-check row that reads the isolation invariants every day.
## Requirements
### Requirement: tenant-admin is an explicit allow-list that excludes the Flux API, escalation verbs and wildcards

jg-base SHALL ship a `ClusterRole tenant-admin` to every cluster. It SHALL enumerate its permitted API groups, resources and verbs explicitly (no aggregation labels). It MUST NOT grant any verb on `*.toolkit.fluxcd.io`, `cilium.io`, `storage.k8s.io`, `networking.k8s.io` NetworkPolicy, or any cluster-scoped resource; it MUST NOT grant the verbs `escalate`, `bind` or `impersonate`; and it MUST NOT use `*` in `verbs`, `resources` or `apiGroups`. A CI guard SHALL assert all three exclusion classes and SHALL fail on each of its negative controls.

#### Scenario: Exclusions hold
- **WHEN** the guard runs against `tenant-admin` on the branch
- **THEN** it reports no forbidden apiGroup, verb, wildcard or cluster-scoped resource and exits 0

#### Scenario: Negative controls fail
- **WHEN** the guard runs against three copies of `tenant-admin` — one with a rule for `kustomize.toolkit.fluxcd.io`, one with `escalate` added to a verb list, one with `verbs: ["*"]`
- **THEN** it exits non-zero for each, naming the offending apiGroup, verb or wildcard

#### Scenario: Tenant cannot widen itself
- **WHEN** a tenant ServiceAccount bound to `tenant-admin` creates a Role granting `kustomize.toolkit.fluxcd.io`
- **THEN** the API server refuses it (escalation prevention) because the tenant holds neither that permission nor `escalate`

#### Scenario: No subject by default
- **WHEN** a cluster has no `app_repos`
- **THEN** `tenant-admin` exists with no RoleBinding or ClusterRoleBinding referencing it

### Requirement: Tenant HTTPRoute hostnames are scoped by admission policy, not by the gateway

jg-base SHALL ship a `ValidatingAdmissionPolicy`, a binding whose `namespaceSelector` matches only namespaces carrying the `jg.tenant` label, and the policy's parameter ConfigMap, whose `domain` value jg-base fills itself through the existing `postBuild.substituteFrom cluster-secrets` variable `${SECRET_DOMAIN}` (no template change). The policy's `matchConstraints` SHALL cover both CREATE and UPDATE of HTTPRoutes. For an HTTPRoute in a tenant namespace it SHALL deny admission unless `spec.hostnames` is non-empty and every hostname ends with `.<value of jg.tenant>.<domain>`; a missing parameter SHALL deny (`parameterNotFoundAction: Deny`). The fleet gateways' `allowedRoutes` SHALL NOT be changed by this capability (their https listeners already accept routes from all namespaces).

#### Scenario: Takeover refused on create
- **WHEN** an HTTPRoute in a tenant namespace is created naming `im.<domain>` as a hostname
- **THEN** admission rejects it and the message names the policy and the hostname

#### Scenario: Takeover refused on update
- **WHEN** a compliant HTTPRoute in a tenant namespace is updated so that a hostname becomes `im.<domain>`
- **THEN** admission rejects the update and the stored object keeps its previous hostnames

#### Scenario: Scoped hostname admitted
- **WHEN** an HTTPRoute in a tenant namespace names only `app.<tenant>.<domain>`
- **THEN** it is admitted and the gateway reports `Accepted=True`

#### Scenario: Empty hostnames refused
- **WHEN** an HTTPRoute in a tenant namespace has no `spec.hostnames`
- **THEN** admission rejects it

#### Scenario: Parameter missing denies
- **WHEN** the parameter ConfigMap is absent
- **THEN** every HTTPRoute change in a tenant namespace is denied, never silently allowed

#### Scenario: Existing namespaces untouched
- **WHEN** an HTTPRoute is created or updated in a namespace without the `jg.tenant` label
- **THEN** the policy does not evaluate it and `envoy.yaml` is byte-identical to before this capability

### Requirement: Tenant Services never draw from the shared LoadBalancer pool

A `LoadBalancer` Service in a namespace labelled `jg.tenant` SHALL never receive an address from the fleet's shared `CiliumLoadBalancerIPPool`; it SHALL receive one only from the tenant pool the cluster template renders for a `lan_ip` grant, and without that grant it SHALL receive none (refused by admission or left pending). The tenant pool's range SHALL be disjoint from the shared pool's blocks, and neither pool SHALL report `PoolConflict`. The mechanism — a `serviceSelector` on the shared pool, an admission policy on tenant Services, or both — SHALL be chosen by measuring what this Cilium's `serviceSelector` matches; this requirement fixes the outcome, not the mechanism.

#### Scenario: Tenant without a grant gets no address
- **WHEN** a tenant namespace without a `lan_ip` grant creates a `LoadBalancer` Service
- **THEN** the Service holds no address from any pool — either admission refused it or it stays pending

#### Scenario: Tenant with a grant draws only from its own pool
- **WHEN** a tenant with `lan_ip: N` creates a `LoadBalancer` Service
- **THEN** its address lies in the tenant pool's range and not in the shared pool's blocks

#### Scenario: Pools do not conflict
- **WHEN** a tenant pool is rendered beside the shared pool
- **THEN** neither `CiliumLoadBalancerIPPool` reports a `PoolConflict` condition, and the tenant pool allocates

#### Scenario: Platform Services unaffected
- **WHEN** a `LoadBalancer` Service exists in a non-tenant namespace
- **THEN** it receives an address from the shared pool as before

### Requirement: The daily check carries a tenant-isolation row (numbered when implemented)

The daily check SHALL carry a tenant-isolation row — taking the next free number when it is implemented — that reads ClusterRoleBindings, RoleBindings, Namespace labels and PersistentVolumeClaims and records: `fail` if any ClusterRoleBinding names a `flux-system/tenant-*` ServiceAccount, if any RoleBinding for a tenant ServiceAccount references a role other than `tenant-admin`, if any tenant namespace lacks a `pod-security.kubernetes.io/enforce` label, or if a tenant namespace carries `enforce=privileged` **without** the label `jg.tenant-privileged=granted`; otherwise `warn` for every tenant namespace holding a PersistentVolumeClaim (named); otherwise `ok`, naming any tenant that is privileged by grant. With no tenant namespaces it SHALL record `skip`. It MUST NOT use `kubectl auth can-i --as`. The README legend SHALL list that row under its number so `check-row-numbers-resolve.sh` passes.

#### Scenario: Four outcomes observed on a throwaway cluster
- **WHEN** the row runs on a cluster with no tenants, then with a compliant tenant, then with that tenant holding a PVC, then with a RoleBinding to `admin` added
- **THEN** it records `skip`, `ok`, `warn` naming the PVC, and `fail` naming the binding, in that order

#### Scenario: Granted privilege is ok, stolen privilege is fail
- **WHEN** a tenant namespace is `enforce=privileged` with `jg.tenant-privileged=granted`, and then the same label is removed by hand
- **THEN** the row records `ok` naming the tenant as privileged by grant, and then `fail` naming the namespace

#### Scenario: Missing read permission is not ok
- **WHEN** the daily-check ServiceAccount cannot list ClusterRoleBindings
- **THEN** the row records `skip` with a message saying the permission is missing, never `ok`

