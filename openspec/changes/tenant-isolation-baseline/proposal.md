Part of: `fleet-ops` / `standalone-app-repos`

**Owning repo**：`jg-base` —— 本 sub-change 改的檔案（`kubernetes/apps/base/flux-system/tenant-rbac/`、gateway 的 `allowedRoutes`、`monitoring/daily-check/app/configmap.yaml` 與 README 圖例、`rbac.yaml`）全在這裡；root change 住在 `fleet-ops`，持有 `standalone-app-repos` 與 `tenant-repo-provisioning` 的 spec。

## Why

Root 的 Why 不在這裡複述（`fleet-ops/openspec/changes/standalone-app-repos/proposal.md`）。jg-base 的份額是「每一座叢集都要先有的底」：tenant 的身分天花板（`ClusterRole tenant-admin`）、tenant 的 HTTPRoute **搶不走**既有 hostname、以及隔離不變量每天被量一次。量到的現況（2026-10-17，`origin/main 6f3c454`）：NetworkPolicy／ResourceQuota／LimitRange／policy engine 全為 0，PSA 標籤 4 個 Namespace 全 `privileged`，唯一的 cluster-admin 綁定是 im 的 SA，沒有任何 Kustomization 設 `serviceAccountName`，Flux 的三支多租戶旗標都沒開；**兩座 Gateway 的 https 監聽器已是 `allowedRoutes.namespaces.from: All`、http 是 `Same`**（`network/envoy-gateway/app/envoy.yaml`；jg-base-0a review 指出、我複量）——所以 tenant 的路由今天就會被接受，問題不是放行而是 hostname 搶佔。k8s jg-jiahd `v1.36.0`、jcom `v1.35.2`（jg-base-0a 量），`ValidatingAdmissionPolicy` 自 1.30 GA。

## What Changes

- 新增 `ClusterRole tenant-admin`（`kubernetes/apps/base/flux-system/tenant-rbac/`）：**明列**的 apiGroups 與 verbs（core 除 Node／PV／Namespace、`apps`、`batch`、`autoscaling`、`policy`、`gateway.networking.k8s.io` HTTPRoute、`rbac.authorization.k8s.io` Role／RoleBinding）；**不含** `*.toolkit.fluxcd.io`、`cilium.io`、`networking.k8s.io` NetworkPolicy、`storage.k8s.io`、任何 cluster-scoped 資源；**verbs 不含 `escalate`／`bind`／`impersonate`，verbs／resources／apiGroups 三欄都不用 `*`**（否則 tenant 建一個含 `kustomize.toolkit.fluxcd.io` 的 Role 綁給自己、再丟一個沒有 `serviceAccountName` 的 Kustomization，controller 就以 cluster-admin 替他套——jg-base-0a review）。對沒有 tenant 的叢集是一個沒人綁的 ClusterRole，零影響。
- 新增 `ValidatingAdmissionPolicy` ＋ `ValidatingAdmissionPolicyBinding` ＋ param ConfigMap：對帶 `jg.tenant` 標籤的 namespace，HTTPRoute 的 **CREATE 與 UPDATE** 都要過——每個 hostname 必須以 `.<tenant>.<domain>` 結尾（tenant 名取自 namespace 標籤；domain 經 `paramRef` 讀 **jg-base 自己渲染**的 ConfigMap，值是既有 `postBuild.substituteFrom cluster-secrets` 的 `${SECRET_DOMAIN}`——不動 jgct，避開第 4 類點頭）。**gateway 的 `envoy.yaml` 不動**——https 已 `from: All`，收窄成 selector 會動到 7 個既有路由 namespace，而且擋不住 hostname 搶佔。
- 主池 `CiliumLoadBalancerIPPool`（`kube-system/cilium/app/networks.yaml`）加 `serviceSelector` **排除** `jg.tenant` namespace：root D9 的 `lan_ip` grant 讓 tenant 從模板渲染的專用子池拿 LAN IP，而今天的主池沒有 selector、任何 namespace 的 LB Service 都能從它拿——不排除，grant 就形同虛設。
- daily-check 新增第 **28** 列「tenant 隔離不變量」：沒有任何 ClusterRoleBinding 的 subject 是 `flux-system/tenant-*` SA；tenant namespace 的 RoleBinding 只指 `tenant-admin`；PSA enforce 標籤在，`privileged` 只在 `jg.tenant-privileged=granted` 標籤同在時算 `ok`（列名——那是公司在 `cluster.yaml` 授的 `host_network` grant），沒有標籤的 `privileged` 是 `fail`（偷升）；tenant namespace 裡有 PVC → `warn`（root 的 `appliance-backup` MODIFIED）；沒有 tenant → `skip`。**以結構斷言，不用 `kubectl auth can-i --as`**（Omni 代理下它說謊，而 daily-check 也不該拿 impersonate 權）。README 圖例同步，`scripts/check-row-numbers-resolve.sh` 會要求。
- `daily-check/app/rbac.yaml` 加讀 `clusterrolebindings`／`rolebindings`／`namespaces`／`persistentvolumeclaims` 的權限（若尚未有）。
- CI 守衛：`tenant-admin` 的 apiGroups 不含上述禁列、verbs 不含 `escalate`／`bind`／`impersonate`、三欄無 `*`；負對照三份（加 `kustomize.toolkit.fluxcd.io`、加 `escalate`、`verbs: ["*"]`）都要紅。

## Capabilities

### New Capabilities

- `tenant-isolation-baseline`：fleet 出貨給每一座叢集的 tenant 底——`tenant-admin` 的範圍與禁列（apiGroups、verbs、通配）、tenant namespace 的 HTTPRoute hostname 範圍（VAP）、主池不服務 tenant namespace、第 28 列的四種結果（含 privileged-by-grant）。

### Modified Capabilities

（無。`talos-mcp-sidecar`、`omni-platform` 不動。）

## Impact

- `kubernetes/apps/base/flux-system/tenant-rbac/{kustomization,clusterrole}.yaml`（新）＋ `flux-system/kustomization.yaml` 收錄
- `kubernetes/apps/base/flux-system/tenant-rbac/{vap,vap-binding}.yaml`（新）；`network/envoy-gateway/app/envoy.yaml` **不動**
- `kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml`（第 28 列）、`README.md`（圖例）、`app/rbac.yaml`
- `kubernetes/apps/base/kube-system/cilium/app/networks.yaml`（主池 `serviceSelector`）
- `scripts/check-tenant-admin-role.sh`（新守衛）、`.github/workflows/flux-local.yaml` 接上
- 四座既有叢集：多一個 ClusterRole、一支只選 `jg.tenant` namespace 的 VAP（對既有 7 個路由 namespace 不匹配、零影響——binding 的 `namespaceSelector` 是這一句的證據，PR 附 `flux-local` diff）、daily-check 多一列 `skip`——沒有 tenant 時第 28 列永遠 `skip`，不影響 `FAIL_COUNT`。
