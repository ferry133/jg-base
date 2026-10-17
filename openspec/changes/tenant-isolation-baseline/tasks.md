> 全部在 `jg-base`。驗收由 root 的開單者（fleet-ops `fleet-ops-77 [af719f]`，或同目錄的繼承者）在 merge 之前收；
> 這張 sub-change 歸檔時由作者回頭更新 root（`fleet-ops/openspec/changes/standalone-app-repos`）。
> 每一格的量測要有負對照；量不到要記成量不到。

## 1. 量現狀（root 任務 1.3／1.4 的 jg-base 半邊）

- [ ] 1.1 gateway 物件的檔案路徑、`allowedRoutes.namespaces.from` 現值、既有 HTTPRoute 所在的 namespace 清單——寫回 root design 的 Open Questions。
- [ ] 1.2 沒有 `serviceAccountName` 的 HelmRelease 數、跨 namespace 的 `sourceRef`／`chartRef` 數（只量不改）。

## 2. tenant-admin

- [ ] 2.1 `kubernetes/apps/base/flux-system/tenant-rbac/clusterrole.yaml` ＋ `kustomization.yaml`，收進 `flux-system/kustomization.yaml`。
- [ ] 2.2 `scripts/check-tenant-admin-role.sh`：禁列斷言 ＋ 負對照（臨時加一行 `kustomize.toolkit.fluxcd.io` 要紅）；接進 `.github/workflows/flux-local.yaml`。
- [ ] 2.3 `flux-local` diff 證明四座叢集只多一個 ClusterRole。

## 3. gateway

- [ ] 3.1 依 1.1 的讀數改 `allowedRoutes.namespaces`：selector 涵蓋現狀 ＋ `jg.tenant`；不用 `from: All`。
- [ ] 3.2 拋棄式叢集：tenant namespace 的 HTTPRoute `Accepted=True`；無標籤 namespace 的 `Accepted=False`（負對照）。

## 4. daily-check 第 28 列

- [ ] 4.1 `configmap.yaml` 第 28 列（結構斷言；`skip`／`ok`／`warn`／`fail` 四種；缺讀權 → `skip` 附訊息）；`README.md` 圖例；`rbac.yaml` 讀權。
- [ ] 4.2 `check-row-numbers-resolve.sh` 綠；若有專列守衛慣例（如第 27 列的 `check-cilium-backend-row.sh`）照做一支。
- [ ] 4.3 拋棄式叢集上四種結果各出現一次（順序：無 tenant → 合規 tenant → 加 PVC → 加一個綁 `admin` 的 RoleBinding），原始輸出貼 PR。
- [ ] 4.4 排程讀數：合併後隔日 `00:00Z` 在 jg-jiahd／jcom 的第 28 列是 `skip`（沒有 tenant），不是 `ok`——這一格不能提前觸發取讀數。

## 5. 收尾

- [ ] 5.1 PR 內文署名、開單者驗收在 merge 之前；merge 後在 PR 留一行署名。
- [ ] 5.2 歸檔本 sub-change，回更新 root 的 Sub-changes 表與 tasks §2。
