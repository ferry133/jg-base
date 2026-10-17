# design — tenant-isolation-baseline（jg-base 份額）

Root 的設計決策在 `fleet-ops/openspec/changes/standalone-app-repos/design.md`；這裡只寫 jg-base 要落實的三條，與各自在 jg-base 裡的形狀。

## Context

- `ClusterRole admin` 經 aggregation 吸收 Flux 的 `flux-edit`，所以 tenant 綁 `admin` 就能建 Kustomization／HelmRelease，而那些物件沒有 `serviceAccountName` 時 controller 以 cluster-admin 套用——這是 root D3 要關的唯一提權路。明列的 `tenant-admin` 是關法。
- daily-check 的列是 `# N. <title>` ＋ probe ＋ `record <ok|warn|fail|skip>`（`configmap.yaml:119-127`）；最後一列是 27（`:1793`）；`check-row-numbers-resolve.sh` 要求圖例同步、不釘總數。
- gateway：兩座 Gateway 的 https 監聽器 `allowedRoutes.namespaces.from: All`、http `Same`（`network/envoy-gateway/app/envoy.yaml`，`6f3c454`；jg-base-0a 指出、複量）。HTTPRoute 分佈 7 個 namespace。
- k8s jg-jiahd `v1.36.0`、jcom `v1.35.2`：`ValidatingAdmissionPolicy` 自 1.30 GA，CEL 可讀 `namespaceObject.metadata.labels` 與 `params`。

## Decisions

- **D-a 明列而非扣除，verbs 一起釘**：RBAC 沒有「`admin` 減某些 group」。`tenant-admin` 是一份 verbs×resources 的白名單；守衛釘的是**禁列**（不含什麼），不是允列——漏給比多給安全。禁列有三類：apiGroups（`*.toolkit.fluxcd.io`、`cilium.io`、`storage.k8s.io`、cluster-scoped）、**verbs（`escalate`、`bind`、`impersonate`）**、**通配（三欄的 `*`）**。只釘第一類時，tenant 用 Role＋RoleBinding 把 Flux API 加給自己的那條路守衛看不見（jg-base-0a review）。
- **D-b tenant 隔離那一列（下一個空號）用結構不用 impersonation**：讀 CRB／RoleBinding／Namespace 標籤／PVC 四種物件就夠；`can-i --as` 在 Omni 代理下回的是呼叫者自己的權限（2026-09 量到），而且要給 daily-check `impersonate` 權才跑得動，本身就是提權。
- **D-e tenant 隔離那一列分得出「授予的 privileged」與「偷升的」**：root D9 的 `host_network` grant 由模板把 namespace 標成 `privileged` ＋ `jg.tenant-privileged=granted`；tenant 對 Namespace 無 verb，加不了那個標籤。所以 `privileged` 有標籤 → `ok` 並列名（每天看得到誰是特權 tenant，但不響——每跑必響的檢查會被關掉）；`privileged` 無標籤 → `fail`。
- **D-f tenant 的 LB Service 永遠拿不到主池位址——寫結果，機制量了再定**（jg-base-0a review 兩點）：
  - **不重疊是前提**：`networks.yaml:1-20` 記著 2026-08-12 的事故——一個是主池子集的窄池 `PoolConflict=cidr_overlap`，從未發出位址、沒人發現。tenant 池從 `lb_pool_blocks` 切子集會死得一樣。所以 tenant 的 `lan_ip_range` 必須在主池之外（模板側斷言不相交），3b.2 讀兩個池的 `PoolConflict` 都要是空。
  - **selector 認什麼要先量**：我的理解（推論，未量）是 Cilium `serviceSelector` 比 Service 標籤加合成的 `io.kubernetes.service.namespace`／`name`，不比 namespace 標籤。Service 標籤 tenant 自己能設，所以「主池排除 tenant」不能靠 tenant 守規矩。候選：(A) 主池 `io.kubernetes.service.namespace notIn [tenant…]`——合成標籤 tenant 設不了，但要在主池列舉每座叢集的 tenant 名，是每座的結構；(B) VAP 選 `jg.tenant` namespace 的 Service：`type=LoadBalancer` 必須 namespace 有 `jg.tenant-lan-ip=granted` 且 Service 帶 `jg.tenant=<自己的 tenant 名>`（CEL 比 namespace 標籤），主池 selector `jg.tenant DoesNotExist`、tenant 池 `jg.tenant=<name>`——全是 Service 標籤（確定支援），VAP 讓標籤可信。偏好 (B)：主池不必知道任何 tenant；(A) 當退路。
  - 負對照：base 的 LB Service 照常拿到 IP；無 grant 的 tenant LB Service 被拒或 pending。
- **D-c `warn` 不 `fail` tenant PVC**：缺口是設計上的（root 把 tenant 資料排除在備份外），`fail` 會每天打 `/fail` ping 讓 dead-man switch 哭；`warn` 進 DETAILS 讓人看得到。
- **D-d gateway 不動，hostname 用 VAP 圈**：第一版寫「selector 不用 `from: All`」，前提反了——https 早就是 `from: All`，tenant 的路由今天就被接受；收窄是動到 7 個既有 namespace 的變更，而且**擋不住真問題**：Gateway API 不按 namespace 分 hostname，tenant 可掛 `im.<domain>` 搶走既有服務。所以：`ValidatingAdmissionPolicy` 選 `HTTPRoute`，binding 的 `namespaceSelector` 只選帶 `jg.tenant` 的 namespace，CEL 斷言 `object.spec.hostnames` 每一個都以 `'.' + namespaceObject.metadata.labels['jg.tenant'] + '.' + params.data.domain` 結尾（空 hostnames 也拒——沒有 hostname 的路由吃全部）。`matchConstraints` 的 operations 是 **CREATE 與 UPDATE**——只擋 CREATE 的話，先建合規路由再改 hostname 就繞過去了（jg-base-0a）。param 是 **jg-base 自己渲染**的 ConfigMap，`domain: ${SECRET_DOMAIN}` 由既有 `postBuild.substituteFrom cluster-secrets` 代入——不動 jgct（jg-base-0a 的建議；模板渲染會是 jgct 第 4 類要點頭的工作）。不引進 policy engine。

## Risks

- [`tenant-admin` 漏了廠商需要的資源] → 廠商回來要，加一行、過守衛、合併；方向是對的。
- [VAP 誤選到既有 namespace] → binding 只用 `namespaceSelector: jg.tenant exists`；拋棄式叢集上對 `default`／`network` 的 HTTPRoute 做負對照（不被評估）。`flux-local` diff 證明四座只多三個物件。
- [VAP 的 param ConfigMap 不在時] → `paramRef.parameterNotFoundAction: Deny`——量不到就拒，不是放行。
- [tenant 隔離那一列的 RBAC 讀權在舊叢集未到就先跑] → `record skip "tenant isolation" "no RBAC read permission"`——量不到要說量不到，不是 `ok`。
