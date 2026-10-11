## 1. 先在拋棄式叢集量，再碰生產（`fleet-ops`）

- [ ] 1.1 `fleet-ops`：用 `node-ship-prep` 已備好的 bench 節點（`.62`／`.91`／`.108`，2026-10-11 皆為 Omni 出貨態）在 FAC1 建一座拋棄式 Omni 叢集；對它 `omnictl talosconfig --cluster <c> --break-glass`，只記 roles／endpoints／`notAfter` 與叢集上出現的 `tainted-by-break-glass` 標籤及其 timestamp。
- [ ] 1.2 `fleet-ops`：在 tainted 叢集上做一次 `omnictl cluster template sync`（改一個無害欄位）與一次 Talos `upgrade --stage`（同版本），記每一步是接受還是被拒——這回答 root design 的 Open Question (b)。
- [ ] 1.3 `fleet-ops`：`omnictl cluster -n <c> secret rotate talos-ca`：記耗時、節點有沒有重開（console／uptime）、舊 break-glass 憑證之後是否被拒、標籤有沒有消失（Open Question (a)）；再 mint 一次確認新憑證可用。
- [ ] 1.4 `fleet-ops`：把 1.1–1.3 寫成 skill `talos-operator-credential`（子命令 `mint`／`verify`／`rotate`；dry-run 預設；值 file-to-file 寫進 `<cluster>/cluster.yaml` 的 `talos_operator_config`；輸出只含 roles／endpoints／`notAfter`；`mint` 在已有未過期憑證時拒絕）；`docs/content.md` 加一列入口；`docs/verification-status.md` 加「operator 憑證到期日」一列。

## 2. `k8scc` sub-change（指標，不複製）

- [ ] 2.1 `k8scc`：完成 `openspec/changes/im-onsite-operator-tools`（server 的第二把憑證、直連退路、`reboot_node`、`claude-session` 的 permission 合併與 inbox 提示、`CLAUDE.md`、映像）；把新 image tag 回報到本檔 3.2。

## 3. `jg-base`

- [ ] 3.1 `jg-base`：`kubernetes/apps/base/claudecode/claude-code/app/talos-mcp-secret.yaml` 加 `data.operatorConfig: "${TALOS_OPERATOR_CONFIG_B64:-}"`（與 `talosconfig` 鍵同一個 b64 先例）。
- [ ] 3.2 `jg-base`：`im/enabled/helmrelease.yaml` 的 `talos-mcp` 容器加 env `TALOS_OPERATOR_CONFIG=/etc/talos-mcp/operator-talosconfig`、`POD_IP`（downward API `status.podIP`）、subPath mount `operatorConfig` → `/etc/talos-mcp/operator-talosconfig`（readOnly）；`app` 與 `talos-mcp` 兩個容器一起 bump 到 2.1 的 tag。
- [ ] 3.3 `jg-base`：在本 repo 的 render 守衛（kustomize build／flux build，若有）確認空值時 Secret 鍵為空、mount 存在但檔案 0 byte——這是 root spec「空字串與缺席同義」的前提，server 那側要把它當缺席。

## 4. `jg-cluster-template`

- [ ] 4.1 `jg-cluster-template`：`.taskfiles/template/resources/cluster.schema.cue` 加 `talos_operator_config?: string & !=""`。
- [ ] 4.2 `jg-cluster-template`：`templates/config/kubernetes/components/sops/cluster-secrets.sops.yaml.j2` 加 `TALOS_OPERATOR_CONFIG_B64: "#{ talos_operator_config | default('') | b64encode }#"`。
- [ ] 4.3 `jg-cluster-template`：`templates/config/kubernetes/apps/base/claudecode/claude-code/instances/helmrelease.yaml.j2` 的 `talos-mcp` 區塊同步 3.2（subPath mount 以 `#% if talos_operator_config is defined %#` gate；env 可不 gate）。
- [ ] 4.4 `jg-cluster-template`：`cluster.sample.yaml` 的 `claudecode/claude-code` 引導段加 `talos_operator_config` 與「由 fleet-ops `talos-operator-credential mint` 填、不要手貼」——**客戶據以行動的註解，合併前 ferry133 點頭**（2026-09-16 裁定）。
- [ ] 4.5 `jg-cluster-template`：`scripts/delivery-check.py` 加一格：Omni `tainted-by-break-glass` 為 informational（顯示 mint 日期），不是 FAIL。

## 5. `jg-jiahd` rollout（user repo，由 fleet-ops agent 執行；驗證不等於擁有權）

- [ ] 5.1 `jg-jiahd`：sync 4.1–4.3 的三個模板檔（drift 先例 `feedback_per_user_template_drift`）；在**沒有**欄位的狀態下 `task configure`，確認 render 除 image tag 外無差異。
- [ ] 5.2 `fleet-ops`：**ferry133 裁定**——2026-10-11 那把 break-glass 仍然有效（im 刪了檔，憑證沒撤）；要先 `rotate talos-ca`（生產叢集、文件稱不中斷）再 mint，還是接受兩把並存到第一次輪替。裁定寫進 `routing-log.md`。
- [ ] 5.3 `jg-jiahd`：依 5.2 的裁定 `talos-operator-credential mint`（或 `rotate` 後 mint）→ `task configure` → 停在 push 前由人點頭 → push → Flux reconcile → 重啟 `im` pod。
- [ ] 5.4 `jg-jiahd`：從 `im.jiahd.cc` 的 ttyd 驗證（agent 自己的 MCP client，不是 kubectl）：`get_link_status(.23)` 首行 `[via Omni]`；`app` 容器內 `find / -name '*talosconfig*'` 與 `env` 皆無 operator 憑證；`reboot_node(node)` 第一段回 token 且 `kubectl logs -c talos-mcp` 出現 `phase: token`；**不執行第二段**。
- [ ] 5.5 `fleet-ops`：在 1.1 的拋棄式叢集驗 `reboot_node` 第二段真的重開（含「自己坐的節點」情境不帶 `--wait`）、allowlist 拒叢集外 IP、token 過期與重放被拒——每一格要有負對照。
- [ ] 5.6 `jg-jiahd`：量 `permissions.ask` 在 auto mode 下的實際行為（提示停住 vs 倒數自動拒絕），寫回 root `design.md` Risks 的那一格；若會自動拒絕，`k8scc` 的 `CLAUDE.md` 要寫「reboot 時請切 manual mode」。

## 6. 收尾

- [ ] 6.1 `fleet-ops`：`escrow-refresh jg-jiahd`（`cluster.yaml` 變了）；`docs/verification-status.md` 重算。
- [ ] 6.2 `fleet-ops`：`routing-log.md` 條目（本 change 建在 `jg-base` 的理由：它改的 spec 在那裡；fleet-ops 只持有 skill 與指標）；memory `jg-jiahd-break-glass-2026-10-11` 更新成 5.2 的結果。
- [ ] 6.3 `jg-base`：`k8scc` sub-change archive 後，依四條規則更新本 root；本 root 在 sub 仍 active 時不可 archive。
