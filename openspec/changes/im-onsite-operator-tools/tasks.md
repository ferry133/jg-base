## 1. 先在拋棄式叢集量，再碰生產（`fleet-ops`）

> 1.1–1.4：fleet-ops main `dbcef0b`（fleet-ops-77 [af719f]，2026-10-13 15:22–15:50Z，拋棄式叢集 `throwaway-opcred`／bench `.108`，用後即刪）。讀數正本在 fleet-ops `.claude/skills/talos-operator-credential/SKILL.md §Readings`；jg-base-0a [4e5e8d] 2026-10-13 23:5x 以該 commit 的檔案驗收（讀數本身是 fleet-ops 量的，這裡只指過去，不複製）。

- [x] 1.1 `fleet-ops`：用 `node-ship-prep` 已備好的 bench 節點（`.62`／`.91`／`.108`，2026-10-11 皆為 Omni 出貨態）在 FAC1 建一座拋棄式 Omni 叢集；對它 `omnictl talosconfig --cluster <c> --break-glass`，只記 roles／endpoints／`notAfter` 與叢集上出現的 `tainted-by-break-glass` 標籤及其 timestamp。
  - 量到的（fleet-ops-77，15:44:09Z）：roles `os:operator`、endpoints `10.9.9.108`、notAfter 2027-10-13（364 天）；`tainted-by-break-glass` 標籤＋timestamp 於 mint 後 2 秒出現（之前沒有＝負對照；jg-jiahd 自 10-11 有＝正對照）。另：叢集成員的 apid 在 LAN 上 `:50000` 會答，10-11 的「refused」只是 maintenance 態。
- [ ] 1.2 `fleet-ops`：在 tainted 叢集上做一次 `omnictl cluster template sync`（改一個無害欄位）與一次 Talos `upgrade --stage`（同版本），記每一步是接受還是被拒——這回答 root design 的 Open Question (b)。
  - **半格**（2026-10-13）：`template sync`（惰性 `machine.sysctls` patch）、`cluster lock`／`unlock`、`kubernetes manifest-sync --dry-run` 全部接受；`machine lock` 被拒是單 CP 的規則不是 taint。**Talos `upgrade --stage` 沒做**（叢集已刪）——(b) 對 Omni 自己的操作已答「不受限」，upgrade 那一半仍未量；補量要再建一座，由 ferry133 決定值不值。
- [x] 1.3 `fleet-ops`：`omnictl cluster -n <c> secret rotate talos-ca`：記耗時、節點有沒有重開（console／uptime）、舊 break-glass 憑證之後是否被拒、標籤有沒有消失（Open Question (a)）；再 mint 一次確認新憑證可用。
  - 量到的（15:45:19Z）：PRE→ROTATE→POST 1 秒完成；uptime 186071→186076 連續（**不重開**）；舊 break-glass 之後 `x509: certificate signed by unknown authority`（Omni 代理的 admin 仍答＝正對照）；**標籤仍在、timestamp 不變**→ Open Question (a)：**輪替不清 taint**；re-mint 15:49:38Z 新憑證在 LAN 上可用、timestamp 變成最後一次 mint。⚠️ jgct cell 14 的訊息與 docstring 仍寫「unmeasured」，要更新（jgct issue 另開）。
- [x] 1.4 `fleet-ops`：把 1.1–1.3 寫成 skill `talos-operator-credential`（子命令 `mint`／`verify`／`rotate`；dry-run 預設；值 file-to-file 寫進 `<cluster>/cluster.yaml` 的 `talos_operator_config`；輸出只含 roles／endpoints／`notAfter`；`mint` 在已有未過期憑證時拒絕）；`docs/content.md` 加一列入口；`docs/verification-status.md` 加「operator 憑證到期日」一列。
  - 驗到的（jg-base-0a，fleet-ops `dbcef0b`）：`scripts/opcred.py` 有 `mint`／`verify`／`rotate`、`--apply` 才動（dry-run 預設）、`KEY = "talos_operator_config"` file-to-file 寫塊、已有未過期憑證時拒絕除非 `--rotating`、`--self-test`（本機跑 rc=0，含壞 talosconfig 負對照）；`docs/content.md` 一列；`docs/verification-status.md` 一則（是走過的紀錄，不是逐叢集到期日表——到期日逐叢集看 `cuc-credential-inventory`／delivery-check cell 14）；runbook Step 5 第 14 列（fleet-ops#20，驗收通過）。

## 2. `k8scc` sub-change（指標，不複製）

- [ ] 2.1 `k8scc`：完成 `openspec/changes/im-onsite-operator-tools`（server 的第二把憑證、直連退路、`reboot_node`、`claude-session` 的 permission 合併與 inbox 提示、`CLAUDE.md`、映像）；把新 image tag 回報到本檔 3.2。
  - 實作：ferry133/k8scc#20（k8scc-0c [4dc61c]，head `27746a6`）；jg-base-0a [4e5e8d] 2026-10-13 23:58 驗收通過（22＋24 項測試、四個突變各紅；root 引用的 19 個字面值逐一命中）。**映像那一半未完**：k8scc 的 workflow 只在 push main 跑，合併要 ferry133 點頭；合併後 CI 對本 repo 開的 pin-bump PR 就是 3.2b 的輸入。
  - root 跟著 k8scc 量到的改字（本 PR）：`--wait=false` 取代「不帶 `--wait`」（talosctl 1.12 的 `--wait` 預設 true）；spec 的「non-empty」加「readable and unexpired」；「first line」加「到期警告行之後」。
  - 裁定（jg-base）：talos-mcp 容器**不設** `CLAUDE_USER_ID`，audit 的 `user` 留空——sidecar 不知道 ttyd 的身分，填常數會讀起來像身分。

## 3. `jg-base`

> 3.1／3.2／3.3：ferry133/jg-base#154（jg-base-0a [4e5e8d]，2026-10-13，草稿、停在合併前等 ferry133 點頭）。

- [x] 3.1 `jg-base`：`kubernetes/apps/base/claudecode/claude-code/app/talos-mcp-secret.yaml` 加 `data.operatorConfig: "${TALOS_OPERATOR_CONFIG_B64:-}"`（與 `talosconfig` 鍵同一個 b64 先例）。
- [x] 3.2 `jg-base`：`im/enabled/helmrelease.yaml` 的 `talos-mcp` 容器加 env `TALOS_OPERATOR_CONFIG=/etc/talos-mcp/operator-talosconfig`、`POD_IP`（downward API `status.podIP`）、subPath mount `operatorConfig` → `/etc/talos-mcp/operator-talosconfig`（readOnly）。
- [ ] 3.2b `jg-base`：`app` 與 `talos-mcp` 兩個容器一起 bump 到 2.1 的 tag。**等 2.1 回報**——2026-10-13 時 open 的 jg-base#153 是 k8scc CI 對只含提案的 commit `871d2db` 開的自動 pin-bump，不是 2.1 的映像；在那之前現行映像不讀 `TALOS_OPERATOR_CONFIG`，3.1／3.2 落地後叢集上沒有任何行為改變。
- [x] 3.3 `jg-base`：在本 repo 的 render 守衛（kustomize build／flux build，若有）確認空值時 Secret 鍵為空、mount 存在但檔案 0 byte——這是 root spec「空字串與缺席同義」的前提，server 那側要把它當缺席。
  - 量到的（2026-10-13，jg-base-0a [4e5e8d]）：(a) `kustomize build app | flux envsubst`、變數未設 → `operatorConfig: `（空，與 `talosconfig: ` 同形）；設值 → 原樣帶入。(b) `helm template app-template 4.6.2` 以 HelmRelease 的 values 渲染 → 只有 `talos-mcp` 容器有 `/etc/talos-mcp/operator-talosconfig`（subPath `operatorConfig`、readOnly）與 env `TALOS_OPERATOR_CONFIG`／`POD_IP=status.podIP`；`app`、`oauth2-proxy`、init container 都沒有 talos-mcp 掛載、沒有指向 `talos-mcp-secret` 的 secretKeyRef。(c) **0 byte 那一半在 jcom 上量**（它沒有 Omni，三個鍵在 live Secret 裡長度都是 0）：`kubectl exec -c talos-mcp -- stat /etc/talos-mcp/talosconfig` → `0 bytes`、`-rw-r--r--`——同一個 Secret、同一種 subPath 掛法，新鍵會得到同樣的 0 byte 檔。(d) 新守衛 `scripts/check-operator-credential-isolation.sh`（文字檢查，接進 flux-local.yaml 的 scripts job）釘住 `data:` 鍵、env 路徑＝掛載路徑、readOnly、只有 talos-mcp 掛、沒有別的容器 env 讀該 Secret、`POD_IP` fieldRef；`--self-test` 13 格（未變異綠、12 種變異各紅、reader 瞎掉回 2）。

## 4. `jg-cluster-template`

> 4.1–4.5：ferry133/jg-cluster-template#204（jg-base-0a [4e5e8d]，2026-10-13，草稿；4.4 是客戶據以行動的註解、4.3 動 `templates/`，合併前要 ferry133 點頭）。

- [x] 4.1 `jg-cluster-template`：`.taskfiles/template/resources/cluster.schema.cue` 加 `talos_operator_config?: string & !=""`。
- [x] 4.2 `jg-cluster-template`：`templates/config/kubernetes/components/sops/cluster-secrets.sops.yaml.j2` 加 `TALOS_OPERATOR_CONFIG_B64: "#{ talos_operator_config | default('') | b64encode }#"`。
- [x] 4.3 `jg-cluster-template`：`templates/config/kubernetes/apps/base/claudecode/claude-code/instances/helmrelease.yaml.j2` 的 `talos-mcp` 區塊同步 3.2（subPath mount 以 `#% if talos_operator_config is defined %#` gate；env 可不 gate）。
- [x] 4.4 `jg-cluster-template`：`cluster.sample.yaml` 的 `claudecode/claude-code` 引導段加 `talos_operator_config` 與「由 fleet-ops `talos-operator-credential mint` 填、不要手貼」——**客戶據以行動的註解，合併前 ferry133 點頭**（2026-09-16 裁定）。
- [x] 4.5 `jg-cluster-template`：`scripts/delivery-check.py` 加一格：Omni `tainted-by-break-glass` 為 informational（顯示 mint 日期），不是 FAIL。
  - 做成 handover cell 14（2026-10-13，jg-base-0a [4e5e8d]）：mint 日期＝憑證的 notBefore，由 `openssl x509` 從 `cluster.yaml` 的 `talos_operator_config` 讀（只讀 crt、不碰 key、輸出只有 roles／日期／標籤名）；**過期是 FAIL**（過期後 sidecar 讀作缺席、`reboot_node` 無聲消失）；Omni 標籤讀自 `--cluster-json` capture 或 `omnictl get clusters`，**只進說明不進結論**；唯一交給人的組合是「Omni 說 tainted、repo 沒有憑證」（10-11 那個形狀，或輪替後殘留的標籤——1.3 還沒量）。11 個單元測試含負對照與不洩漏控制。順帶：`credential-inventory.py` 把 `talos_operator_config` 列進 KNOWN（否則它不含 token／key 字樣，連 UNCLASSIFIED 都不會印），並把「Talos client certificate 不按交付簽發」那條排除改寫成現況。**要路由出去的**：fleet-ops runbook 的 Step 5 表只有 13 列，第 14 列由 fleet-ops 加。

## 5. `jg-jiahd` rollout（user repo，由 fleet-ops agent 執行；驗證不等於擁有權）

- [ ] 5.1 `jg-jiahd`：sync 4.1–4.3 的三個模板檔（drift 先例 `feedback_per_user_template_drift`）；在**沒有**欄位的狀態下 `task configure`，確認 render 除 image tag 外無差異。
- [ ] 5.2 `fleet-ops`：**ferry133 裁定**——2026-10-11 那把 break-glass 仍然有效（im 刪了檔，憑證沒撤）；要先 `rotate talos-ca`（生產叢集、文件稱不中斷）再 mint，還是接受兩把並存到第一次輪替。裁定寫進 `routing-log.md`。
- [ ] 5.3 `jg-jiahd`：依 5.2 的裁定 `talos-operator-credential mint`（或 `rotate` 後 mint）→ `task configure` → 停在 push 前由人點頭 → push → Flux reconcile → 重啟 `im` pod。
- [ ] 5.4 `jg-jiahd`：從 `im.jiahd.cc` 的 ttyd 驗證（agent 自己的 MCP client，不是 kubectl）：`get_link_status(.23)` 首行 `[via Omni]`；`app` 容器內 `find / -name '*talosconfig*'` 與 `env` 皆無 operator 憑證；`reboot_node(node)` 第一段回 token 且 `kubectl logs -c talos-mcp` 出現 `phase: token`；**不執行第二段**。
- [ ] 5.5 `fleet-ops`：在 1.1 的拋棄式叢集驗 `reboot_node` 第二段真的重開（含「自己坐的節點」情境帶 `--wait=false`）、allowlist 拒叢集外 IP、token 過期與重放被拒——每一格要有負對照。
- [ ] 5.6 `jg-jiahd`：量 `permissions.ask` 在 auto mode 下的實際行為（提示停住 vs 倒數自動拒絕），寫回 root `design.md` Risks 的那一格；若會自動拒絕，`k8scc` 的 `CLAUDE.md` 要寫「reboot 時請切 manual mode」。

## 6. 收尾

- [ ] 6.1 `fleet-ops`：`escrow-refresh jg-jiahd`（`cluster.yaml` 變了）；`docs/verification-status.md` 重算。
- [ ] 6.2 `fleet-ops`：`routing-log.md` 條目（本 change 建在 `jg-base` 的理由：它改的 spec 在那裡；fleet-ops 只持有 skill 與指標）；memory `jg-jiahd-break-glass-2026-10-11` 更新成 5.2 的結果。
- [ ] 6.3 `jg-base`：`k8scc` sub-change archive 後，依四條規則更新本 root；本 root 在 sub 仍 active 時不可 archive。
