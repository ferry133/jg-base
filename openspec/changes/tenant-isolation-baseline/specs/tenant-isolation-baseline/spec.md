## ADDED Requirements

### Requirement: tenant-admin is an explicit allow-list that excludes the Flux API

jg-base SHALL ship a `ClusterRole tenant-admin` to every cluster. It SHALL enumerate its permitted API groups and resources explicitly (no aggregation labels) and MUST NOT grant any verb on `*.toolkit.fluxcd.io`, `cilium.io`, `storage.k8s.io`, `networking.k8s.io` NetworkPolicy, or any cluster-scoped resource. A CI guard SHALL assert the exclusion list and SHALL fail on its own negative control.

#### Scenario: Exclusions hold
- **WHEN** the guard runs against `tenant-admin` on the branch
- **THEN** it reports no forbidden apiGroup or cluster-scoped resource and exits 0

#### Scenario: Negative control fails
- **WHEN** the guard runs against a copy of `tenant-admin` with one rule for `kustomize.toolkit.fluxcd.io` added
- **THEN** it exits non-zero naming that apiGroup

#### Scenario: No subject by default
- **WHEN** a cluster has no `app_repos`
- **THEN** `tenant-admin` exists with no RoleBinding or ClusterRoleBinding referencing it

### Requirement: Gateway accepts routes from tenant namespaces

The fleet gateway SHALL accept HTTPRoutes from namespaces labelled `jg.tenant`, in addition to the namespaces it accepts today, and SHALL NOT be widened to all namespaces.

#### Scenario: Tenant route accepted
- **WHEN** an HTTPRoute is created in a namespace labelled `jg.tenant=<name>`
- **THEN** its `Accepted` condition is True on the fleet gateway

#### Scenario: Unlabelled namespace still refused
- **WHEN** an HTTPRoute is created in a namespace with neither the tenant label nor today's allowance
- **THEN** its `Accepted` condition is False with reason `NotAllowedByListeners`

### Requirement: Daily check row 28 measures the tenant isolation invariants

The daily check SHALL carry a row 28 that reads ClusterRoleBindings, RoleBindings, Namespace labels and PersistentVolumeClaims and records: `fail` if any ClusterRoleBinding names a `flux-system/tenant-*` ServiceAccount, if any RoleBinding for a tenant ServiceAccount references a role other than `tenant-admin`, or if any tenant namespace lacks a `pod-security.kubernetes.io/enforce` label or carries `privileged`; otherwise `warn` for every tenant namespace holding a PersistentVolumeClaim (named); otherwise `ok`. With no tenant namespaces it SHALL record `skip`. It MUST NOT use `kubectl auth can-i --as`. The README legend SHALL list row 28 so `check-row-numbers-resolve.sh` passes.

#### Scenario: Four outcomes observed on a throwaway cluster
- **WHEN** the row runs on a cluster with no tenants, then with a compliant tenant, then with that tenant holding a PVC, then with a RoleBinding to `admin` added
- **THEN** it records `skip`, `ok`, `warn` naming the PVC, and `fail` naming the binding, in that order

#### Scenario: Missing read permission is not ok
- **WHEN** the daily-check ServiceAccount cannot list ClusterRoleBindings
- **THEN** the row records `skip` with a message saying the permission is missing, never `ok`
