> 全部在 `jg-base`。驗收由 root 的開單者（fleet-ops `fleet-ops-77 [af719f]`，或同目錄的繼承者）在 merge 之前收；
> 這張 sub-change 歸檔時由作者回頭更新 root（`fleet-ops/openspec/changes/standalone-app-repos`）。
> 每一格的量測要有負對照；量不到要記成量不到。

## 1. 量現狀（root 任務 1.3／1.4 的 jg-base 半邊）

- [x] 1.1 gateway：`network/envoy-gateway/app/envoy.yaml` 兩座 Gateway https `allowedRoutes.namespaces.from: All`、http `Same`；HTTPRoute 分佈 7 個 namespace（2026-10-17，jg-base-0a 與 fleet-ops-77 各量一次，`6f3c454`）。結論：gateway 不動，hostname 用 VAP 圈。
- [x] 1.2 （2026-10-20 08:0x，jg-base-0a [4e5e8d]，唯讀量活的物件；讀數交 fleet-ops 寫回 root design）**jg-jiahd：HelmRelease 17 支全部沒有 `serviceAccountName`，跨 namespace 的 `sourceRef`／`chartRef` 0；Kustomization 41 支全部沒有，跨 namespace 0。jcom：HelmRelease 20／20 沒有、跨 namespace 0；Kustomization 42／42 沒有、0。** 正對照：jcom 有 6 支 HelmRelease 的 ref 明寫 namespace（全部同 namespace，例 `omni/omni → omni/my-helm-repo`），捏造的跨 namespace 物件會被同一個判斷式抓到。沒有 `serviceAccountName` 的 HelmRelease 數、跨 namespace 的 `sourceRef`／`chartRef` 數（只量不改）——寫回 root design 的 Open Questions。

## 2. tenant-admin

- [x] 2.1 （jg-base#194 `b779ce1`，2026-10-18；兩座 production 讀回 18 條規則、禁列 0，#190 已關）`kubernetes/apps/base/flux-system/tenant-rbac/clusterrole.yaml` ＋ `kustomization.yaml`，收進 `flux-system/kustomization.yaml`。verbs 明列，無 `*`。
- [x] 2.2 （#194；14 個變異，CI run 39138419629 第 36 步 success）`scripts/check-tenant-admin-role.sh`：三類禁列斷言（apiGroups／cluster-scoped、verbs `escalate`／`bind`／`impersonate`、三欄通配）＋ 三份負對照各自要紅；接進 `.github/workflows/flux-local.yaml`。
- [x] 2.3 （#194 `+226/−0` 只多 ClusterRole；#196 只多 VAP＋binding＋ConfigMap；#197 只多 VAP＋binding、主池加 selector）`flux-local` diff 證明四座叢集只多 ClusterRole ＋ VAP ＋ binding 三個物件。

## 3. hostname 範圍（VAP）

- [x] 3.1 （jg-base#196 `ccfdeff`；**位置改在 `kubernetes/apps/base/tenant-admission/`**——放在 `flux-system/` 下時 kustomize 把 namespace 蓋到 VAP 上）`tenant-rbac/vap.yaml`：`matchConstraints` 選 `gateway.networking.k8s.io` HTTPRoute、operations **CREATE 與 UPDATE**；CEL：`has(object.spec.hostnames) && size(object.spec.hostnames) > 0 && object.spec.hostnames.all(h, h.endsWith('.' + namespaceObject.metadata.labels['jg.tenant'] + '.' + params.data.domain))`；`paramKind` ConfigMap。
- [x] 3.2 （#196；`flux-system` 那條 Kustomization 的代換由 fleet-ops-96 在 jg-jcc2 量到）`tenant-rbac/vap-binding.yaml`：`namespaceSelector` 只選 `jg.tenant` 存在；`paramRef` 指 **jg-base 自己渲染**的 `tenant-rbac/vap-params.yaml` ConfigMap（`domain: ${SECRET_DOMAIN}`，由這條 Kustomization 既有的 `postBuild.substituteFrom cluster-secrets` 代入——確認 `flux-system` 那條有 substituteFrom，沒有就加），`parameterNotFoundAction: Deny`；`validationActions: [Deny]`。
- [x] 3.3 （fleet-ops-96 [cde990] 在 jg-jcc2 跑完全部格子，#191 已關）拋棄式叢集：tenant namespace 掛 `im.<domain>` 被拒、**合規路由 UPDATE 成 `im.<domain>` 被拒且物件保持原 hostnames**、掛 `app.<tenant>.<domain>` Accepted、空 hostnames 被拒；`default` namespace 的 HTTPRoute 不被評估（負對照）；param 不在時被拒。

## 3b. tenant 的 LB Service 永遠拿不到主池位址

- [x] 3b.1 （fleet-ops-77 [af719f] 在 jg-jcc2 量過：Service 標籤 ✅、合成 namespace 標籤 ✅、namespace 標籤 ❌ → 選 (B)）**先量**這版 Cilium 的 `serviceSelector` 認什麼：Service 標籤、合成的 `io.kubernetes.service.namespace`／`name`、namespace 標籤——三格各一個 pool fixture 在拋棄式叢集上試。依讀數在 (A) 主池 `io.kubernetes.service.namespace notIn [tenant…]` 與 (B) VAP（`jg.tenant` namespace 的 `LoadBalancer` Service 必須 namespace 有 `jg.tenant-lan-ip=granted` 且 Service 帶 `jg.tenant=<自己>`）＋主池 `jg.tenant DoesNotExist`＋tenant 池 `jg.tenant=<name>` 之間選，偏好 (B)；寫進 PR 與 root design。
- [x] 3b.2 （jg-base#197 `fbe5a6d`；fleet-ops-96 在 jg-jcc2 跑完全部格子）拋棄式叢集：無 `lan_ip` grant 的 tenant 建 LB Service 拿不到位址（被拒或 pending）；有 grant 的拿到的位址在 tenant 池範圍內、不在主池 blocks 內；**兩個 `CiliumLoadBalancerIPPool` 都沒有 `PoolConflict` condition 且 tenant 池真的發得出位址**（2026-08-12 的事故是窄池 `cidr_overlap` 從未發出任何位址）；base 的 LB Service（例：envoy gateway）照常拿到 IP（負對照）。
- [x] 3b.3 （#197；production 兩座 0/34 個 Service 帶 `jg.tenant`；jg-jcc2 的 base LB 位址前後相同）若選 (B)：主池 selector 改動對既有 Service 零影響——`flux-local` diff ＋ 拋棄式叢集上既有 LB 位址不變。

## 4. daily-check 的 tenant 隔離列（下一個空號；號碼在實作時決定，spec 不預言——`check-row-numbers-resolve.sh` 掃全 repo 的 `row N` 引用）

- [x] 4.1 （第 28 列；本 PR）`configmap.yaml` 新列、取下一個空號（結構斷言；`skip`／`ok`／`warn`／`fail` 四種；`privileged` 有 `jg.tenant-privileged=granted` → `ok` 列名、無 → `fail`；缺讀權 → `skip` 附訊息）；`README.md` 圖例；`rbac.yaml` 讀權。
- [x] 4.2 （`check-row-numbers-resolve.sh` 綠；專列守衛 `check-tenant-isolation-row.sh`，15 格；本 PR）`check-row-numbers-resolve.sh` 綠；若有專列守衛慣例（如第 27 列的 `check-cilium-backend-row.sh`）照做一支。
- [x] 4.3 （fleet-ops-96 [cde990] 在 jg-jcc2，#198 留言 6253415218：A 無 tenant→skip、B 合規＋`t2` privileged granted→ok 列名、C 加 PVC→warn、D 綁 `admin`→fail、E 拿掉 granted→fail）拋棄式叢集上四種結果各出現一次（順序：無 tenant → 合規 tenant → 加 PVC → 加一個綁 `admin` 的 RoleBinding），再一組：namespace `privileged`＋granted 標籤 → `ok` 列名；手動拿掉標籤 → `fail`。原始輸出貼 PR。
- [x] 4.4 （2026-10-20 00:00Z Job `daily-check-29874240`，jg-base-0a 讀 log：兩座第 28 列都是 `➖ Tenant isolation — no tenants declared (no namespace labelled jg.tenant)`，`FAIL_COUNT=0`；讀數貼在 #199）排程讀數：合併後隔日 `00:00Z` 在 jg-jiahd／jcom 的這一列是 `skip`（沒有 tenant），不是 `ok`——這一格不能提前觸發取讀數。

## 5. 收尾

- [x] 5.1 （#198：內文署名、fleet-ops-96 在 `e3224dc` accept、merge 前後署名留言，merge `a7e38bc`）PR 內文署名、開單者驗收在 merge 之前；merge 後在 PR 留一行署名。
- [x] 5.2 （本 PR 歸檔；root 的 Sub-changes 表與 tasks §2 由 jg-base-0a 在合併後更新——`~/.claude/openspec-orchestration.md`：sub-change 的作者更新 root）歸檔本 sub-change，回更新 root 的 Sub-changes 表與 tasks §2。
