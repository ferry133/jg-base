# design — tenant-isolation-baseline（jg-base 份額）

Root 的設計決策在 `fleet-ops/openspec/changes/standalone-app-repos/design.md`；這裡只寫 jg-base 要落實的三條，與各自在 jg-base 裡的形狀。

## Context

- `ClusterRole admin` 經 aggregation 吸收 Flux 的 `flux-edit`，所以 tenant 綁 `admin` 就能建 Kustomization／HelmRelease，而那些物件沒有 `serviceAccountName` 時 controller 以 cluster-admin 套用——這是 root D3 要關的唯一提權路。明列的 `tenant-admin` 是關法。
- daily-check 的列是 `# N. <title>` ＋ probe ＋ `record <ok|warn|fail|skip>`（`configmap.yaml:119-127`）；最後一列是 27（`:1793`）；`check-row-numbers-resolve.sh` 要求圖例同步、不釘總數。
- gateway：兩座 Gateway 的 https 監聽器 `allowedRoutes.namespaces.from: All`、http `Same`（`network/envoy-gateway/app/envoy.yaml`，`6f3c454`；jg-base-0a 指出、複量）。HTTPRoute 分佈 7 個 namespace。
- k8s jg-jiahd `v1.36.0`、jcom `v1.35.2`：`ValidatingAdmissionPolicy` 自 1.30 GA，CEL 可讀 `namespaceObject.metadata.labels` 與 `params`。

## Decisions

- **D-a 明列而非扣除，verbs 一起釘**：RBAC 沒有「`admin` 減某些 group」。`tenant-admin` 是一份 verbs×resources 的白名單；守衛釘的是**禁列**（不含什麼），不是允列——漏給比多給安全。禁列有三類：apiGroups（`*.toolkit.fluxcd.io`、`cilium.io`、`storage.k8s.io`、cluster-scoped）、**verbs（`escalate`、`bind`、`impersonate`）**、**通配（三欄的 `*`）**。只釘第一類時，tenant 用 Role＋RoleBinding 把 Flux API 加給自己的那條路守衛看不見（jg-base-0a review）。
- **D-b 第 28 列用結構不用 impersonation**：讀 CRB／RoleBinding／Namespace 標籤／PVC 四種物件就夠；`can-i --as` 在 Omni 代理下回的是呼叫者自己的權限（2026-09 量到），而且要給 daily-check `impersonate` 權才跑得動，本身就是提權。
- **D-e 第 28 列分得出「授予的 privileged」與「偷升的」**：root D9 的 `host_network` grant 由模板把 namespace 標成 `privileged` ＋ `jg.tenant-privileged=granted`；tenant 對 Namespace 無 verb，加不了那個標籤。所以 `privileged` 有標籤 → `ok` 並列名（每天看得到誰是特權 tenant，但不響——每跑必響的檢查會被關掉）；`privileged` 無標籤 → `fail`。
- **D-f 主池排除 tenant namespace**：Cilium LB IPAM 沒有 selector 的 pool 服務所有 Service；tenant 的 `lan_ip` 子池由模板渲染，但只要主池還沒有 selector，tenant 的 LB Service 也能從主池拿 IP、quota 擋不住主池。排除用 namespace 標籤（`io.kubernetes.service.namespace` 的 selector 或 Cilium 的 namespace label 支援——3.x 量哪個寫法在這版 Cilium 成立），負對照是 base 的 LB Service 照常拿到 IP。
- **D-c `warn` 不 `fail` tenant PVC**：缺口是設計上的（root 把 tenant 資料排除在備份外），`fail` 會每天打 `/fail` ping 讓 dead-man switch 哭；`warn` 進 DETAILS 讓人看得到。
- **D-d gateway 不動，hostname 用 VAP 圈**：第一版寫「selector 不用 `from: All`」，前提反了——https 早就是 `from: All`，tenant 的路由今天就被接受；收窄是動到 7 個既有 namespace 的變更，而且**擋不住真問題**：Gateway API 不按 namespace 分 hostname，tenant 可掛 `im.<domain>` 搶走既有服務。所以：`ValidatingAdmissionPolicy` 選 `HTTPRoute`，binding 的 `namespaceSelector` 只選帶 `jg.tenant` 的 namespace，CEL 斷言 `object.spec.hostnames` 每一個都以 `'.' + namespaceObject.metadata.labels['jg.tenant'] + '.' + params.data.domain` 結尾（空 hostnames 也拒——沒有 hostname 的路由吃全部）。`matchConstraints` 的 operations 是 **CREATE 與 UPDATE**——只擋 CREATE 的話，先建合規路由再改 hostname 就繞過去了（jg-base-0a）。param 是 **jg-base 自己渲染**的 ConfigMap，`domain: ${SECRET_DOMAIN}` 由既有 `postBuild.substituteFrom cluster-secrets` 代入——不動 jgct（jg-base-0a 的建議；模板渲染會是 jgct 第 4 類要點頭的工作）。不引進 policy engine。

## Risks

- [`tenant-admin` 漏了廠商需要的資源] → 廠商回來要，加一行、過守衛、合併；方向是對的。
- [VAP 誤選到既有 namespace] → binding 只用 `namespaceSelector: jg.tenant exists`；拋棄式叢集上對 `default`／`network` 的 HTTPRoute 做負對照（不被評估）。`flux-local` diff 證明四座只多三個物件。
- [VAP 的 param ConfigMap 不在時] → `paramRef.parameterNotFoundAction: Deny`——量不到就拒，不是放行。
- [第 28 列的 RBAC 讀權在舊叢集未到就先跑] → `record skip "tenant isolation" "no RBAC read permission"`——量不到要說量不到，不是 `ok`。
