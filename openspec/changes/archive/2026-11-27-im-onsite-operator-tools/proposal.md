**Owning repo**：`jg-base` —— 本 change 修改的 spec 是 `openspec/specs/talos-mcp-sidecar`（`insideman` 2026-08-11 歸檔後的基準），而 sidecar 的 Secret 與 HelmRelease 容器區塊都住在這裡。

**Implementation lands in**：`jg-base`（`talos-mcp-secret` 新鍵、`im/enabled/helmrelease.yaml` 的 sidecar env/mount、spec delta）、`k8scc`（MCP server 的工具面、`claude-session` 的權限規則與 inbox 提示、映像；見下表的 sub-change）、`jg-cluster-template`（`cluster.yaml` 欄位、`cluster.schema.cue`、`cluster-secrets.sops.yaml.j2`、`instances/helmrelease.yaml.j2`——與 jg-base 同一個 agent 擁有，任務在本 change 的 tasks.md 內逐條標 repo）、`fleet-ops`（鑄造／輪替 operator 憑證的 skill，與 `routing-log.md` 指標）。各 user repo（`jg-jiahd` 先行）只做 rollout 與驗證，不擁有任何設計。

**Sub-changes**：

| repo | change | 負責什麼 |
|---|---|---|
| `k8scc` | `im-onsite-operator-tools`（**已封存** 2026-10-15，k8scc#27 merge `4e9aaaa`：`openspec/changes/archive/2026-10-15-im-onsite-operator-tools`；三個 capability 的 spec 現住 k8scc `openspec/specs/{talos-operator-escalation,im-permission-profile,operator-inbox}`） | `talos_mcp_server.py`：第二把（operator）憑證、讀取工具的直連 LAN 退路、`reboot_node` 工具的 confirm／allowlist／audit 契約；`claude-session`：MCP 工具的 permission 規則、`inbox/` 非空時的提示；映像重建 |

## Why

2026-10-11，`jg-jiahd` 的節點 `.23` SideroLink 斷了 9.5 小時。`im.jiahd.cc` 用 `insideman` 給它的四個唯讀工具**正確診斷**出「節點健康、管理通道斷、需要 graceful reboot」，然後停在那裡——因為它手上**只有**一把 `os:reader` 憑證，而且那把憑證走 Omni 代理：代理到不了 SideroLink 已斷的節點，**診斷工具的路與故障是同一條**。接下來 3 個小時是公司這邊在補：操作員親手鑄 break-glass、用 `kubectl exec` 塞進 `app` 容器（`insideman` 當初就是為了終結這個反模式而建的）、im 的權限層把 `talosctl` 整個擋掉並**無提示自動拒絕** reboot、最後由人在 ttyd 打 `!` 執行。量到的時間線：13:54Z 鑄憑證 → 14:28Z reboot 被自動拒絕 → 14:29Z 人打 reboot → 14:30Z 節點回來 → 14:36Z handshake 54 秒。**一個 22 秒的重開，在地的 im 什麼都做不了，公司端花了 3 小時。**

`insideman` 的 Non-Goals 明寫「mutating Talos operations… remain the existing manual, ephemeral break-glass workflow」——那條路今天走了一次，代價就是上面那段。這個 change 把它補成**公司的在地 agent（im）**能自己走完的路。

## What Changes

- **sidecar 多一把憑證**：一份直連 LAN 的 `os:operator` talosconfig（Omni `--break-glass` 產出的那種）以新鍵進 `talos-mcp-secret`，**只掛進 `talos-mcp` 容器**；`app` 容器仍然什麼都看不到。`os:reader` 那把照舊，不被取代。
- **讀取工具有直連退路**：既有四個 `get_*` 先走 Omni 代理（reader 憑證）；代理失敗且 operator 憑證在場時改走 LAN 直連，輸出標明走的是哪條路。這修掉今天的盲點——SideroLink 斷了就看不到 SideroLink。
- **新增 `reboot_node(node, confirm)`**：graceful only；`node` 必須在**呼叫當下**從叢集自己的 node 清單推導出的 allowlist 裡；`confirm` 必須等於工具回給呼叫者的一次性字串；每次呼叫寫一行 audit 到 sidecar stdout。**不提供** reset／apply-config／upgrade／shutdown。
- **BREAKING（spec）**：`talos-mcp-sidecar` 的 requirement「No mutating Talos capability introduced」**被替換**為「mutating capability 只經由受門檻的工具、只在 operator 憑證在場時存在」。`os:reader` 憑證本身仍不能 mutate，那一條不變。
- **權限層跟著工具走，而門在伺服端，不在提示**：`claude-session` 在 `settings.json` 寫 `permissions.allow` 給全部五個 `mcp__talos__*` 工具——`reboot_node` 那一條**在伺服端守衛（下一點）落地的同一個映像裡才從 `ask` 改成 `allow`**。**im 是公司維護客戶叢集的工具，登得進 im 的只有公司的人，不是客戶**（ferry133 2026-10-15 裁定，原話 "im is company's tool to maintain customer's cluster by his own. if someone wanna reach im, only company's employee can, not customer."；推翻 10-12 寫的「在迴圈裡的人是坐在 ttyd 前的客戶，reboot 永遠要有人按」）。reboot 由 im 依自己的診斷執行，**預設沒有人按**，事後向公司回報（inbox／health mail）；Auth0 那層本來就是這樣——base `im` 走 factory tenant。
- **伺服端守衛取代人按的提示**（2026-10-15 裁定後新增，住在 k8scc sub-change）：另一台控制平面不 Ready 就拒（quorum）、每節點冷卻時間（連鎖重開）、自身節點時回應明說「整個 im 隨之停擺」、audit 行記 agent 給的 `reason`。**順序是裁定的一部分**：先守衛、再翻 `ask`→`allow`，不能有一個「無人、無守衛」的映像在艦隊上跑。兩段式 token 留著，但它是 agent 自己的第二眼（同一個 agent 發、同一個 agent 確認），不是對 agent 的門。
- **憑證生命週期有家**：鑄造（`omnictl talosconfig --cluster <c> --break-glass`）、寫進 `cluster.yaml` → `task configure`、撤銷／輪替（`omnictl cluster -n <c> secret rotate talos-ca`，文件稱不中斷、不重開）全部收進 fleet-ops 一支 skill。**`tainted-by-break-glass` 從此是每座交付叢集的常態**，不是事故。
- **公司 → im 的交辦通道**：workspace PVC 下的 `inbox/`；`claude-session` 在它非空時印一行提示。今天的交辦是靠瀏覽器打字進 ttyd，中間三次被分類器擋，最後靠人轉述。

## Capabilities

### New Capabilities
- `operator-credential-lifecycle`：每座叢集那把 `os:operator` 直連憑證從哪裡來、住在哪、怎麼撤、`tainted` 對 fleet 的意義，以及它的效期與 Omni 撤不掉這件事怎麼被補償。

### Modified Capabilities
- `talos-mcp-sidecar`：(1) 「Isolated Talos credential per client」擴成兩把憑證、同一個隔離邊界；(2) 「Read-only Talos diagnostic tools」加上直連 LAN 退路的要求；(3) 「No mutating Talos capability introduced」**替換**為「Gated mutating capability」——工具契約本身（confirm／allowlist／audit）的 spec 住在 `k8scc` 的 sub-change（`talos-operator-escalation`），本 spec 只規定 sidecar 層的條件：operator 憑證不在場時工具不存在、`app` 容器拿不到憑證、叢集外節點被拒、**不以任何人類提示為門**（2026-10-15 裁定）。

（`talos-operator-escalation`、`im-permission-profile`、`operator-inbox` 三個新 capability 的 spec **住在 `k8scc` 的 sub-change**，因為它們描述的是那個 repo 的檔案的行為；本 change 不複製。）（sub-change 封存後它們在 k8scc 的 `openspec/specs/` 底下，路徑同上表。）

## Impact

- `jg-base`：`kubernetes/apps/base/claudecode/claude-code/app/talos-mcp-secret.yaml`（新鍵 `operatorConfig`）、`im/enabled/helmrelease.yaml`（`talos-mcp` 容器新增 env `TALOS_OPERATOR_CONFIG` 與 subPath mount）、`openspec/specs/talos-mcp-sidecar`。
- `k8scc`：`talos_mcp_server.py`（含 2026-10-15 裁定後的伺服端守衛）、`claude-session`（`reboot_node` 的規則 `ask`→`allow`，與守衛同一個映像）、`CLAUDE.md`（im 的權限與事後回報）、映像 tag。
- `jg-cluster-template`：`cluster.schema.cue`（`talos_operator_config?`）、`cluster-secrets.sops.yaml.j2`（`TALOS_OPERATOR_CONFIG_B64`）、`instances/helmrelease.yaml.j2`、`cluster.sample.yaml` 的引導段。
- `fleet-ops`：新 skill（鑄造／輪替／驗證）、`docs/content.md` 入口表一列、`routing-log.md`。
- **安全面**：`app` 容器早已持有 `cluster-admin` 的 kubeconfig（`rbac.yaml`，2026-07-26 裁定），能建 hostPID 特權 pod 做 ungraceful reset——所以 sidecar 裡一把只能 reboot／shutdown、不能 reset 的 `os:operator` 憑證**不擴大既有的爆炸半徑**，它把一條本來就走得到、但不優雅的路換成優雅的。
- **Omni 面**：每座叢集會帶 `tainted-by-break-glass` 標籤；Omni 自己的操作（template sync、upgrade）在 tainted 叢集上是否受限，**本 change 要先在拋棄式叢集量過才 rollout**（`never-test-on-production-clusters`）。
- 依賴：Omni ≥ 目前 v1.8.1 的 `--break-glass`（需在 Omni 啟動旗標 `--enable-break-glass-configs` 打開，`omni.janncot.com` 已開——2026-10-11 實鑄成功）；`omnictl cluster secret rotate talos-ca` 的實際行為未在本 fleet 量過。
