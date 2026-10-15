## Context

`insideman`（2026-08-11 歸檔）給每座客戶叢集的 `im` pod 一個 `talos-mcp` sidecar：一把 Omni Reader-role SA 換來的 `os:reader` talosconfig、四個唯讀工具、憑證只掛在 sidecar。它刻意把 mutating 留在 Non-Goals：「remain the existing manual, ephemeral break-glass workflow with explicit per-use human authorization」。

2026-10-11 那條路走了一次，量到的形狀（全部 UTC）：

| 時間 | 事 | 誰 |
|---|---|---|
| 04:47 | `.23` SideroLink 最後一次 handshake | — |
| ~13:3x | im 用四個 `get_*` 診斷：節點健康、etcd 3 voter、管理通道斷、需 graceful reboot；`get_link_status(.23)` 本身 timeout（代理到不了） | im |
| 13:54 | `omnictl talosconfig --break-glass` 鑄 `os:operator`（fleet-ops 的分類器擋，由 ferry133 `!` 跑） | 人 |
| 13:56 | `kubectl exec -i … cat >` 塞進 `app` 容器 `~/.talos/config` | fleet-ops |
| 14:15–14:19 | im 驗證憑證、鎖基準、drain（manual mode 下逐條按） | im＋人 |
| 14:28 | `talosctl reboot` 被 im 的 auto-mode 分類器**無提示自動拒絕** | — |
| 14:29 | 人在 ttyd 打 `! talosctl … reboot --wait`，22 秒完成 | 人 |
| 14:30 | 節點 Ready、Omni `connected: true` | — |
| 14:36 | handshake 54 秒前、新 iface 收包零 drop；im 刪憑證 | im |

四個事實決定了這份設計：

1. **Omni 管的叢集，直連 LAN 的 Talos 憑證只有 break-glass 一種來源。** `talosctl config new` 要 `os:admin`，Omni 不給任何身分這個角色（insideman Decision 2 量過）；`--break-glass` 固定給 `os:operator`、沒有 TTL 旗標（10-11 量到：一年）。
2. **Omni 代理的路與 SideroLink 故障是同一條。** Reader 憑證再好，節點掉線時它就瞎了——而那正是需要它的時候。
3. **`app` 容器早已是 `cluster-admin`**（`rbac.yaml`，2026-07-26 裁定：Omni 掛了也要有救援路）。它本來就能建 hostPID 特權 pod 用 sysrq 硬重開。sidecar 裡一把只會 reboot／shutdown、不會 reset 的 `os:operator`，**沒有擴大既有的爆炸半徑**。
4. **Claude Code 的 Bash 分類器與 MCP 工具的 permission 規則是兩套東西。** 前者把 `talosctl` 整個當危險指令（連本機 `config info` 都擋）、auto mode 下對 reboot 無提示拒絕；後者可以逐工具寫 `allow`／`ask`，提示會停著等人按。（`ask` 在 auto mode 下的實際行為，root 5.6 量到互相矛盾的讀數——見 tasks 5.6；2026-10-15 裁定後 `reboot_node` 走 `allow`，那一格不再是門的一部分。）

## Goals / Non-Goals

**Goals：**
- im 在 SideroLink 斷線時仍看得到節點（直連 LAN 讀取退路）。
- im 能 graceful reboot 自己叢集的節點，**依自己的診斷執行、預設沒有人按**，事後向公司回報。登得進 im 的只有公司的人（factory Auth0 tenant），不是客戶——ferry133 2026-10-15 裁定；10-12 版寫的「由坐在 ttyd 前的人按一次確認」已撤。
- 憑證仍然只在 sidecar；`app` 容器拿不到；叢集外的節點碰不到。
- 憑證的鑄造、攜帶、撤銷、效期各有一個會跑的家（fleet-ops skill ＋ pipeline），不再是「操作員手動、臨時、每次授權」。
- 公司 → im 的交辦有一個不靠瀏覽器打字的通道。

**Non-Goals：**
- reset／apply-config／upgrade／shutdown——`os:operator` 做得到 shutdown，本 change 不開；reset 與 apply 角色就不允許。
- 把 `app` 容器的 `cluster-admin` 收窄——另一個 change。
- 讓 im 自己鑄或換憑證——鑄造是公司的動作（委付、taint 都是公司承擔的事）。
- Omni 不管的叢集（`provisioning_path: talos`，如 handover 後的 B）——那裡的憑證來源是叢集自己的 PKI，`talosctl config new` 可用；欄位相同、來源不同，**由 `cuc-handover` 的 build-repo 填**，本 change 只保證欄位存在。
- 週期性輪替——每次輪替要 re-mint ＋ `task configure` ＋ push，成本是一次 rollout；只在交接、疑似外洩、pod／映像失守時做。

## Decisions

**1. operator 憑證放進同一個 `talos-mcp` sidecar，當第二個檔案，不開第三個容器。**
隔離邊界是 `app` ↔ sidecar，它已經在；第二個 sidecar 不會多出任何邊界（loopback 對 `app` 一樣可達），只會把 probe、registration、secret mount 的管線加倍。
- *替代*：獨立 `talos-operator` 容器——拒絕，理由如上。
- *替代*：放進 `app` 容器（今天做的）——拒絕，這正是 insideman 要終結的反模式。

**2. 憑證來源＝每座叢集一次 Omni break-glass，交付時由 fleet-ops skill 鑄，走既有 secret 管線。**
`cluster.yaml` 的 `talos_operator_config`（多行 talosconfig）→ `TALOS_OPERATOR_CONFIG_B64`（與 `TALOS_MCP_CONFIG_B64` 同一個 b64 先例）→ `talos-mcp-secret.data.operatorConfig` → subPath 掛到 `/etc/talos-mcp/operator-talosconfig`。
- *替代*：Omni SA 給 Operator role——**在今天這種故障下沒有用**，它走代理。
- *替代*：`talosctl config new --crt-ttl 24h` 短效憑證——做不到，要 `os:admin`。
- *替代*：事故時才鑄——拒絕，那是今天的流程；人與公司又回到迴圈裡。
- 欄位不存在 → secret 鍵為空 → server 視為「沒有 operator 憑證」→ 工具不註冊、退路不啟用。**空字串與缺席必須同義**，否則 Flux 的 `${VAR:-}` 會留下一個 0 byte 的檔讓 `talosctl` 噴出看起來像壞憑證的錯。

**3. 撤銷＝`omnictl cluster -n <c> secret rotate talos-ca`，然後 re-mint、`task configure`、push、重啟 im pod。**
Omni 文件：Talos API CA 輪替不中斷叢集內連線、不重開節點；只有一個輪替能同時進行；用 Talos API 的 pod 要重啟才拿新 CA。**兩件事文件沒寫、本 fleet 沒量過，rollout 前要在拋棄式叢集量**：(a) 輪替後 `tainted-by-break-glass` 標籤是否消失（文件只提 `tainted-by-importing`）；(b) tainted 叢集上 Omni 自己的 template sync／upgrade 有沒有被限制。
- *替代*：不撤、靠 pod 重啟讓檔案消失——那是今天的做法；檔案消失不等於憑證失效。

**4. 門檻分四層，每層擋不同的錯。**

| 層 | 擋什麼 | 誰強制 |
|---|---|---|
| Talos 角色 `os:operator` | reset／apply／upgrade／鑄憑證 | 節點伺服端 |
| 工具面只有 `reboot_node` | 任何不是 graceful reboot 的動作 | MCP server 程式碼（k8scc） |
| 兩段式 confirm ＋ 呼叫時推導的 allowlist ＋ audit | 手滑、叢集外節點、不留痕 | MCP server 程式碼（契約 spec 在 k8scc `talos-operator-escalation`） |
| 伺服端守衛：另一台控制平面不 Ready 就拒、每節點冷卻時間（自身節點從它上次開機起算，sidecar 重啟抹不掉——k8scc#25／#26）、自身節點時回應明說「整個 im 隨之停擺」、audit 行要 agent 給 `reason` | 診斷錯的重開、連鎖重開、說不出理由的重開 | MCP server 程式碼（k8scc） |

insideman 的「工具不存在＋角色拒絕」雙保險在 reboot 這一格變成「工具存在但四層門檻」。這是有意識的降級，換來的是在地的 im 能自己走完。
**第四層的歷史**：10-12 版寫的是「Claude Code `permissions.ask`，由坐在 ttyd 前的人按」。2026-10-15 ferry133 裁定移除——im 是公司的工具，要自己走完，不等人；而且 5.6 量到的 `ask` 行為讀數互相矛盾（tasks 5.6），一道靠「人會看到提示」的門在沒有人坐著的 ttyd 上本來就不存在。兩段式 token 留著，但它是 agent 自己的第二眼，不是對 agent 的門——所以第四層改成伺服端守衛，而且**守衛要先落地，`ask` 才翻成 `allow`**。

**5. 讀取退路用 operator 憑證 `--endpoints <node>` 直連，Omni 路徑仍是主路。**
主路保留 Omni 的 `x-sidero-signature` 稽核；退路只在主路失敗（timeout／`Unavailable`／`no route`）且 operator 憑證在場時啟用，輸出第一行標 `[via direct LAN]`（有到期警告行時緊接在它之後——k8scc 2026-10-13 定稿）。
- *替代*：全部改直連——拒絕，平時少一份 Omni 稽核，而且 reader 憑證就沒用了。

**6. permission 規則由 `claude-session` 寫進 `settings.json`，合併不覆寫。**
映像層的預設可重現；PVC 上的 `settings.json` 是那座 im 自己的、會被手改。寫 `permissions.allow` 給五個 `mcp__talos__*` 工具；`reboot_node` 在守衛（Decision 4 第四層）落地前維持 `ask`，落地的同一個映像裡改 `allow`——10-12 版寫的「`permissions.ask: mcp__talos__reboot_node`」是過渡態，不是終態（2026-10-15 裁定）。

**7. 交辦信箱＝`~/workspace/inbox/`，`claude-session` 非空時印一行。**
最便宜的耐久通道：公司這側 `kubectl exec`／`cp` 放檔，im 讀完改名 `*.read`。不做 MCP、不做通知——先量它有沒有被用。

## Risks / Trade-offs

- **[Risk] tainted 的語意沒量過** → rollout 前在 FAC1 拋棄式叢集走一次：鑄 → 看標籤 → 做一次 template sync 與 Talos upgrade → `rotate talos-ca` → 看標籤 → 舊憑證被拒。**不在 jcom／jg-jiahd 先試。**
- **[Risk] 一年效期到了工具會默默變瞎** → server 啟動時讀 `talosctl config info` 的到期日，< 30 天在每個工具輸出前綴警告；fleet-ops skill 的 verify 子命令列出到期日；`docs/verification-status.md` 收一列。
- **[Risk] 單節點叢集 reboot 自己坐的那台，`--wait` 永遠回不來** → sidecar 是 hostNetwork，pod IP ＝ node IP；`node` 等於自己時明寫 `--wait=false`、回傳「已下令，本 pod 將隨節點重啟」；其他節點 `--wait=true --timeout=600s`。**k8scc 2026-10-13 量到 `talosctl reboot --wait` 預設是 true**（talosctl 1.12），「不帶 `--wait`」照字面做會等自己死掉——所以旗標要明寫。
- **[Risk] allowlist 靠 `kubectl get nodes`，API server 不可用時推不出來** → fail closed：拒絕並說明；不退回 `TALOS_NODES`。
- **[Risk] confirm token 被重放** → 單次有效、120 秒過期、綁 node。
- **[Risk] im 自作主張重開**（2026-10-15 裁定後，取代「agent 自作主張 → 人按提示」那一格）→ 伺服端守衛：另一台控制平面不 Ready 就拒、每節點冷卻時間（自身節點從它上次開機起算，sidecar 重啟抹不掉——k8scc#25／#26）、自身節點時明說整個 im 停擺、audit 行帶 `reason`；每一格在拋棄式叢集有負對照；事後向公司回報。**守衛未落地前 `reboot_node` 維持 `ask`。**
- **[Trade-off] 每座交付叢集永久 tainted** → 接受；它是標籤不是限制（待量）。代價是 Omni 無法再宣稱「所有 Talos 存取都經我」——本來 `app` 的 cluster-admin 就已讓這句話不成立。
- **[Trade-off] CA 輪替成本是一次完整 rollout** → 所以不週期做；交接時本來就要重新發憑證。

## Migration Plan

1. `k8scc` sub-change 先行：server 支援第二把憑證但缺席時行為不變；重建映像、bump tag 進 `jg-base` 與 `jg-cluster-template` 的 HelmRelease（兩邊都要，否則 user repo 一 render 就倒退）。
2. `jg-base`：`talos-mcp-secret` 新鍵（`${TALOS_OPERATOR_CONFIG_B64:-}`）、HelmRelease 的 env 與 subPath mount。值為空時純增量，無副作用。
3. `jg-cluster-template`：`cluster.schema.cue`、`cluster-secrets.sops.yaml.j2`、`instances/helmrelease.yaml.j2`、`cluster.sample.yaml` 引導段（**客戶照著填的註解，依 2026-09-16 裁定要 ferry133 點頭**）。
4. `fleet-ops`：skill `talos-operator-credential`（mint／verify／rotate）；在拋棄式叢集量 taint 與輪替；`docs/content.md` 加入口。
5. `jg-jiahd`（user repo，fleet-ops agent）：mint → `cluster.yaml` → `task configure` → push → 從 ttyd 驗證 `get_link_status` 直連路徑、`reboot_node` 的第一段（只拿 token，不重開）。真的重開只在拋棄式叢集驗。
6. 回滾：拿掉欄位 → render → 工具消失、退路關閉。**憑證本身要 `rotate talos-ca` 才失效**——回滾與撤銷是兩件事。
7. **2026-10-15 裁定後**（步驟 5 已在生產上走過一次：ferry133 坐在 ttyd 前、im 經 `reboot_node` 重開 `.23`）：`k8scc` 加伺服端守衛並在同一個映像把 `reboot_node` 改 `allow`、CLAUDE.md 寫明 im 的權限與事後回報 → k8scc CI 對 `jg-base` 開 pin-bump → 合併＝部署（兩座 im 各重啟一次）→ 守衛的負對照在拋棄式叢集量（tasks 7）。
