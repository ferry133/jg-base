Part of: `fleet-ops` / `standalone-app-repos`

**Owning repo**：`jg-base` —— 本 sub-change 改的檔案（`kubernetes/apps/base/flux-system/tenant-rbac/`、gateway 的 `allowedRoutes`、`monitoring/daily-check/app/configmap.yaml` 與 README 圖例、`rbac.yaml`）全在這裡；root change 住在 `fleet-ops`，持有 `standalone-app-repos` 與 `tenant-repo-provisioning` 的 spec。

## Why

Root 的 Why 不在這裡複述（`fleet-ops/openspec/changes/standalone-app-repos/proposal.md`）。jg-base 的份額是「每一座叢集都要先有的底」：tenant 的身分天花板（`ClusterRole tenant-admin`）、tenant 的 HTTPRoute 能被 gateway 接受、以及隔離不變量每天被量一次。量到的現況（2026-10-17，`origin/main 6f3c454`）：NetworkPolicy／ResourceQuota／LimitRange／policy engine 全為 0，PSA 標籤 4 個 Namespace 全 `privileged`，唯一的 cluster-admin 綁定是 im 的 SA，沒有任何 Kustomization 設 `serviceAccountName`，Flux 的三支多租戶旗標都沒開。

## What Changes

- 新增 `ClusterRole tenant-admin`（`kubernetes/apps/base/flux-system/tenant-rbac/`）：**明列**的 apiGroups（core 除 Node／PV／Namespace、`apps`、`batch`、`autoscaling`、`policy`、`gateway.networking.k8s.io` HTTPRoute、`rbac.authorization.k8s.io` Role／RoleBinding）；**不含** `*.toolkit.fluxcd.io`、`cilium.io`、`networking.k8s.io` NetworkPolicy、`storage.k8s.io`、任何 cluster-scoped 資源。對沒有 tenant 的叢集是一個沒人綁的 ClusterRole，零影響。
- gateway 的 `allowedRoutes.namespaces` 放行帶 `jg.tenant` 標籤的 namespace（檔案與現值待 root 任務 1.3 量出來）。
- daily-check 新增第 **28** 列「tenant 隔離不變量」：沒有任何 ClusterRoleBinding 的 subject 是 `flux-system/tenant-*` SA；tenant namespace 的 RoleBinding 只指 `tenant-admin`；PSA enforce 標籤在且不是 `privileged`；tenant namespace 裡有 PVC → `warn`（root 的 `appliance-backup` MODIFIED）；沒有 tenant → `skip`。**以結構斷言，不用 `kubectl auth can-i --as`**（Omni 代理下它說謊，而 daily-check 也不該拿 impersonate 權）。README 圖例同步，`scripts/check-row-numbers-resolve.sh` 會要求。
- `daily-check/app/rbac.yaml` 加讀 `clusterrolebindings`／`rolebindings`／`namespaces`／`persistentvolumeclaims` 的權限（若尚未有）。
- CI 守衛：`tenant-admin` 的 apiGroups 不含上述禁列；負對照是加一行 `kustomize.toolkit.fluxcd.io` 要紅。

## Capabilities

### New Capabilities

- `tenant-isolation-baseline`：fleet 出貨給每一座叢集的 tenant 底——`tenant-admin` 的範圍與禁列、gateway 對 tenant namespace 的放行、第 28 列的四種結果。

### Modified Capabilities

（無。`talos-mcp-sidecar`、`omni-platform` 不動。）

## Impact

- `kubernetes/apps/base/flux-system/tenant-rbac/{kustomization,clusterrole}.yaml`（新）＋ `flux-system/kustomization.yaml` 收錄
- gateway 物件（檔案待 1.3）
- `kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml`（第 28 列）、`README.md`（圖例）、`app/rbac.yaml`
- `scripts/check-tenant-admin-role.sh`（新守衛）、`.github/workflows/flux-local.yaml` 接上
- 四座既有叢集：多一個 ClusterRole、gateway 多一條 selector、daily-check 多一列 `skip`——沒有 tenant 時第 28 列永遠 `skip`，不影響 `FAIL_COUNT`。
