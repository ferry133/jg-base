# design — tenant-isolation-baseline（jg-base 份額）

Root 的設計決策在 `fleet-ops/openspec/changes/standalone-app-repos/design.md`；這裡只寫 jg-base 要落實的三條，與各自在 jg-base 裡的形狀。

## Context

- `ClusterRole admin` 經 aggregation 吸收 Flux 的 `flux-edit`，所以 tenant 綁 `admin` 就能建 Kustomization／HelmRelease，而那些物件沒有 `serviceAccountName` 時 controller 以 cluster-admin 套用——這是 root D3 要關的唯一提權路。明列的 `tenant-admin` 是關法。
- daily-check 的列是 `# N. <title>` ＋ probe ＋ `record <ok|warn|fail|skip>`（`configmap.yaml:119-127`）；最後一列是 27（`:1793`）；`check-row-numbers-resolve.sh` 要求圖例同步、不釘總數。
- gateway：`allowedRoutes.namespaces` 現值未量（root 1.3）。

## Decisions

- **D-a 明列而非扣除**：RBAC 沒有「`admin` 減某些 group」。`tenant-admin` 是一份 verbs×resources 的白名單；守衛釘的是**禁列**（不含什麼），不是允列——漏給比多給安全。
- **D-b 第 28 列用結構不用 impersonation**：讀 CRB／RoleBinding／Namespace 標籤／PVC 四種物件就夠；`can-i --as` 在 Omni 代理下回的是呼叫者自己的權限（2026-09 量到），而且要給 daily-check `impersonate` 權才跑得動，本身就是提權。
- **D-c `warn` 不 `fail` tenant PVC**：缺口是設計上的（root 把 tenant 資料排除在備份外），`fail` 會每天打 `/fail` ping 讓 dead-man switch 哭；`warn` 進 DETAILS 讓人看得到。
- **D-d gateway 用 label selector 不用 `from: All`**：放行 `jg.tenant` 標籤的 namespace，而不是放行全部——否則任何 namespace 都能掛路由到客戶的網域。

## Risks

- [`tenant-admin` 漏了廠商需要的資源] → 廠商回來要，加一行、過守衛、合併；方向是對的。
- [gateway selector 改動影響既有路由] → 既有 HTTPRoute 全在 base／extras 的 namespace，selector 要同時涵蓋現狀；1.3 量完才改，PR 附 `flux-local` diff。
- [第 28 列的 RBAC 讀權在舊叢集未到就先跑] → `record skip "tenant isolation" "no RBAC read permission"`——量不到要說量不到，不是 `ok`。
