## Context

root：`fleet-ops/openspec/changes/agent-delegation-envelope`（tasks 第 7 組）。姊妹：k8scc `openspec/changes/im-chamber-client`（橋接程式、用戶端、驗章工具、環境變數表）。這裡只決定 pod spec 與 daily-check。

下面每一條標明它是**讀數**（附日期與版本）、**裁定**（附誰、哪天）、還是**提案**（起草者的判斷，等驗收的人改）。

```
 ┌──────────────── im pod（hostNetwork，uid 0）────────────────┐
 │  app ──── /run/chamber/bridge.sock ──── chamber-bridge ─────┼──▶ chamber 伺服器
 │   │            （emptyDir，只有這兩個掛）        │           │
 │   └─ /etc/chamber/signers（ConfigMap，唯讀）     └─ /etc/chamber/token（Secret，唯讀，optional）
 └─────────────────────────────────────────────────────────────┘
```

## Decisions

### D1 形狀是 kustomize component，不是第三條路徑（提案；本機量過）

`im/netdev` 的先例是「`im/enabled` 加一個 container」的 overlay，`jg-cluster-template` 選路徑。chamber 若照做，就要 `im/chamber` 與 `im/netdev-chamber` 兩個目錄，下一個選項再翻倍。

改用 `kind: Component`（這個 repo 已有一個：`kubernetes/components/sops`）。打開的方式是 Flux `Kustomization` 的 `spec.components`，與 `spec.path` 互不相干：路徑選 `enabled` 或 `netdev`，component 加不加 chamber。

**讀數（2026-11-19，本機 `kubectl kustomize`，Kustomize v5.7.1，`origin/main c557d7a` 的 `im/` 複本）**：一個帶 patch 與 replacement 的 component，分別疊在 `enabled` 與 `netdev` 上——

| 渲染 | container | 橋接的 tag＝`app` 的 tag | `app` 原有的 env 還在 |
|---|---|---|---|
| `enabled` | app, oauth2-proxy, talos-mcp | — | 是 |
| `netdev` | app, netdev-mcp, oauth2-proxy, talos-mcp | — | 是 |
| `enabled`＋component | 上列＋chamber-bridge | 是 | 是 |
| `netdev`＋component | 上列＋chamber-bridge | 是 | 是 |

兩個疊過的渲染扣掉新增的三處（container、`app` 的一個 env、一個 volume）之後，與原本的渲染相等；對照：不扣的時候不相等。

`jg-base-56 [c30591]` 驗收時用自己另寫的 component 獨立重現了這張表（同一天、同一版 kustomize）。

**讀數（同日稍後，flux CLI v2.7.4，`flux build kustomization --dry-run`，Kustomization 檔加上 `spec.components: [../chamber]`）**：`enabled` 與 `netdev` 都 rc=0，渲染裡有 `chamber-bridge`；路徑是相對於 `spec.path`。對照：不加那一行，渲染裡沒有它。

**限制（`jg-base-56 [c30591]` 量到，我以 flux CLI 複量，兩邊都 rc=1）：component 不能與 `im/disabled` 並存。** `disabled` 沒有 `app` container，複製 pin 的 replacement 找不到來源，build 失敗。build 失敗＝`claude-code-im` 不 reconcile＝**不 prune**；`im-ks.yaml` 的「開過之後關掉」靠的正是空路徑去 prune。所以一座接著 chamber 的叢集把 im 關掉、而 `components` 那一行還在，HelmRelease 會被留在原地，那個物件只顯示 BuildFailed。對照：`disabled` 不加 component，rc=0。component 只能與 `enabled`／`netdev` 並存；設定 `components` 的那一方（`jg-cluster-template` 的渲染，D6）在路徑是 `disabled` 時要拿掉它，並且要有守衛。

**沒量到的**：叢集裡的 kustomize-controller 讀 `spec.components` 的結果——量到的是 CLI。tasks 2.4 在拋棄式叢集上量。量不過的退路是兩個薄目錄（`im/chamber`、`im/netdev-chamber`，各自 `resources: ../x` ＋ `components: ../_chamber`），component 本身不必重寫。

### D2 登入憑證：Secret 由 user repo 帶來，這裡只引用名字，而且 `optional`（提案）

- 值是每座叢集一把、由 ferry133 鑄造（root 2.11）。這個 repo 是 public，不持有它，也不持有伺服器位址——位址放在同一個 Secret 的另一個鍵，只進橋接 container 的 env。
- 名字 `im-chamber`，鍵 `token` 與 `url`，**兩個都是同一個 optional volume 裡的檔**（`/etc/chamber/token`、`/etc/chamber/url`，唯讀，mode 0400）；橋接程式以 `CHAMBER_TOKEN_FILE`、`CHAMBER_URL_FILE` 讀。**沒有任何 container 經 env 讀這個 Secret**。
  - 初稿讓 `url` 走 env 的 `secretKeyRef`＋`optional: true`。**量到它裝不上去**（`jg-base-56 [c30591]`，2026-11-19，本機 `helm template` v3.17.2 對 repo 釘的 chart app-template 4.6.2）：schema 回 `Additional property optional is not allowed`，`enabled`／`netdev` 加 component 都 rc=1；對照「不加 component」與「只刪那一行」都 rc=0。拿掉 `optional` 則 Secret 不在時 container 起不來。chart 收的是 volume 那邊的 `optional`，所以兩個鍵都走 volume。k8scc 同日加了 `CHAMBER_URL_FILE`（`ferry133/k8scc#76`）。**沒量到**：叢集裡 helm-controller 的行為——量的是本機 `helm template`。
  - **Secret 晚到**：optional 的 Secret volume 在 Secret 出現後由 kubelet 補上檔案，但橋接程式（k8scc#76 當時的版本）位址與憑證只在啟動時讀一次——Secret 晚到它不會自己發現，而這個 container 沒有 probe 會重啟它。已請 k8scc 在「未設定」的閒置狀態定期重讀；在那之前，Secret 到位後要重啟 pod。
  - **2026-11-19 稍後**：k8scc 改了（`ferry133/k8scc#77`，已合併，merge `d69ff92`；我量的是 head `ad2e8d7`）——閒置時每個 beat 重讀，齊了自己啟動。`fleet-ops-98 [047e9c]` 在本機測試伺服器上量到：以 0 位元組的位址檔啟動，寫入位址後 16 秒內（beat 5 秒）socket 出現。**沒量到**：憑證檔單獨晚到；kubelet 把晚到的 Secret 補進 optional volume 這一步；任何 pod。所以「要不要重啟 pod」在 tasks 2.3 量了才算數。與 `ha-im-token`、`im-apps-write-key` 同一條路：sops → Secret → pod 裡的一個檔，不經 `cluster-secrets`。
- **`optional: true`**。不 optional 的話，component 接上而 Secret 還沒到的那一段時間，pod 會卡在 ContainerCreating——im 的終端機跟著沒了。k8scc 那一側的對應行為（2026-11-19 與 `k8scc-0f [7c5b85]` 對過）：橋接 container 在未設定或設定不全時**留著不退出**，印一行原因後閒置；0 位元組與不存在同一件事。chamber 的毛病不該把終端機帶下來。
- 帳號名不需要新欄位：`im-${CLUSTER_NAME}`，`CLUSTER_NAME` 已在 `cluster-secrets`（`scripts/substitution-vocabulary.txt:29`）。

### D3 socket：`emptyDir` 掛在 `/run/chamber`，只有兩個 container（讀數＋對過的提案）

im 的 pod 是 `hostNetwork: true`（`im/enabled/helmrelease.yaml` 的 `defaultPodOptions`），所以 loopback 是節點的 loopback。k8scc 的 spec 因此規定橋接程式只開 Unix socket、不開 TCP。pod spec 這一側：

- `emptyDir`（`medium: Memory`），`advancedMounts` 只列 `app` 與 `chamber-bridge`。路徑 `/run/chamber`，socket `/run/chamber/bridge.sock`，`app` 的 `CHAMBER_URL=unix:/run/chamber/bridge.sock`（2026-11-19 與 k8scc 對過；用戶端的 `unix:` 形式是 k8scc tasks 2.5，尚未實作）。
- `chamber-bridge` 不宣告任何 port；`allowPrivilegeEscalation: false`、drop ALL，與 `talos-mcp` 相同。
- **這一層擋得住什麼，擋不住什麼**（2026-11-19 `jg-base-56 [c30591]` 驗收後改寫；初稿寫「擋的是憑證被帶走」，不成立）：
  - 擋得住：憑證不躺在 `app` 的檔案系統與 env 裡——`env`、`ps`、狀態封存、transcript 不會意外帶出它。守衛檢查的是這一件，而且只檢查 pod spec 的文字。
  - **橋接 container 看得到什麼**（`jg-base-56 [c30591]` 讀渲染出的 pod）：除了這個 component 給它的三樣，它還掛著 `claude-config`（`/home/claude/.claude`、keyrings）與 `claude-workspace`——底下的 HelmRelease 用 `globalMounts`，新 container 自動繼承。與 `talos-mcp` 相同，不是這個 change 帶進來的；意思是橋接程式讀得到 agent 的設定與工作區，反過來 `app` 讀不到 `/etc/chamber`。
  - 擋不住 `app` 內的冒用：能打開 socket 的行程都能以 im 的名義收發（k8scc design D-b 明寫）。
  - **擋不住 `app` 去讀憑證**：整個 pod 用 ServiceAccount `claude-code`（`im/enabled/helmrelease.yaml` 的 `serviceAccount`），`app/rbac.yaml` 把它綁到 `cluster-admin`。`app` 是 root shell、帶著那個 SA 的 token，不需要掛載，問 apiserver 就讀得到 `im-chamber` 的每一個鍵。（讀的是來源檔；沒有在叢集上從 `app` 實讀一次——tasks 2.5 加一格。）`talos-mcp` 既有的隔離是同一個形狀，不是這個 change 帶進來的。
  - 所以保留類的依據不能是這把憑證，也不是它——root 的設計本來就是「伺服器記的寄件人對保留類沒有效力，只認人的簽章」。這把憑證被 `app` 拿到，後果是以 im 的名義說一般類的話，在 `app` 本來就能經 socket 做到的範圍內；多出來的是**可以帶到 pod 外面去用**。

### D4 公鑰清單：這個 repo 渲染的 ConfigMap，掛成目錄（提案；有一格等裁定）

- 兩個檔：`allowed_signers`、`revoked_signers`，放在 component 目錄裡，`configMapGenerator` ＋ `disableNameSuffixHash`（名字固定，內容更新不重建 pod）。掛成整個目錄 `/etc/chamber/signers`，**不用 `subPath`**——`subPath` 掛載不會跟著 ConfigMap 更新，而撤銷只在被更新的副本上生效。
- 為什麼放這裡：Flux 每小時把它送到每一座叢集，kubelet 再同步進 pod。這是現有的路裡唯一不需要人逐座去更新的。內容只有公鑰與人的代號，沒有客戶名單。
- 初始是空的。空清單下 `directive-verify` 回 2（量不到），不是 0。
- **CI 覆蓋只有一支守衛**：這個 repo 裡沒有任何東西引用這個 component，所以 flux-local 永遠不會建到它；合併後它唯一的 CI 覆蓋是 tasks 1.2 那支守衛（`jg-base-56 [c30591]` 指出）。
- **等裁定**：清單的正本住哪（root 的未決項）。這裡持有的若是副本，更新它的 PR 由誰開、怎麼證明與正本相同，要在正本的位置定了之後補一個比對。**不論正本在哪，改這兩個檔的 PR 合併前要 ferry133 點頭**——那是在改「誰的話算指令」，而 agent 不得增加簽章者（root 的裁定）。
- **沒量到的**：ConfigMap 更新到 pod 裡的檔案實際要多久（tasks 3.3）。

### D5 daily-check：讀 pod log，不加 `exec`（提案）

daily-check 在 `claudecode` 只有 `pods/log`（`daily-check/claudecode/rbac.yaml`）。往一個握有叢集管理權的 agent pod 裡 `exec` 是比這一列大得多的權限，不加。`netdev-mcp sidecar` 那一列已經是這個形狀。

所以四個讀數來自兩行定期印出的狀態（格式是 k8scc 的草案，2026-11-19；**定稿前這一列不實作**）。**哪一行由哪個 container 印要先定**（`jg-base-56 [c30591]` 指出）：公鑰清單只掛進 `app`（D4），所以 `chamber-verify-status` 只能由 `app` 裡的行程印（k8scc 的草案是 `chamber-watch`），`chamber-status` 由橋接 container 印——這一列因此要讀兩個 container 的 log，而 `app` 的 stdout 目前是誰在寫、會不會被別的輸出淹掉，要在 k8scc 定稿時先看。**間隔不寫死在 daily-check 裡**：請狀態行自己帶 `interval=<秒>`，「太舊」＝比 3 個它自己說的間隔還舊。這兩件是給 k8scc 定稿的輸入。

```
chamber-status ts=<epoch> mode=observe|deliver|unconfigured server=ok|unreachable|refused rooms=<排序、逗號分隔，沒有是 -> online=yes|no|unmeasured
chamber-verify-status ts=<epoch> signers=<n> revoked=<n> sshkeygen=ok|missing
```

一列四個讀數，結果取最壞的：

| 情形 | 結果 |
|---|---|
| 沒有 im／im 沒有 `chamber-bridge` container | `skip`，說「這座沒有接 chamber」 |
| container 宣告了但沒在跑 | `fail` |
| log 讀不到、狀態行不在、或 `ts` 比 3 個間隔還舊 | `skip`（量不到，說是哪一個） |
| `mode=unconfigured` | `warn`：接上了但沒設定好 |
| `server` 不是 `ok` | `fail` |
| `rooms` 不等於預期的那一間 | `fail`，印出兩邊 |
| `sshkeygen=missing` | `fail` |
| `signers=0` | `warn`：驗章工具在，但沒有任何人的金鑰——每一份指令都會回量不到 |
| `mode=deliver` 且 `online=no` | `fail`（R20） |
| `mode=observe` | 在線那一格不判，訊息寫「觀察模式，不上線是設計」 |
| 任何欄位是 `unmeasured` | 那一格 `skip` |

- 預期的房間由 daily-check 自己從 `CLUSTER_NAME` 推，不讀橋接程式的說法——拿被量的東西的自述當預期，等於沒有比。房間的命名規則以 root 為準。
- **這一列量不到的**：沒有 `chamber-bridge` container 時回 `skip`，分不出「從來沒接」與「接過、掉了」——「這座應該接著」的預期住在 user repo，daily-check 讀不到。現在接受。
- **這一列量不到的**：`signers=<n>` 只說清單讀得到，不說驗章真的驗得過（k8scc 提醒；映像裡沒有測試向量）。「驗章可用」目前只到「工具與清單都在」。要更硬得另想，列為未決。

### D6 誰打開它（範圍外，寫下來以免被當成漏做）

打開＝某座叢集的 `claude-code-im` Kustomization 多一行 `components`。那一行由 user repo 的 patch 帶，而 patch 由 `jg-cluster-template` 渲染——所以是一個 `cluster.yaml` 欄位，屬該 repo 的 issue，**合併前要 ferry133 點頭**（root tasks 7.4）。拋棄式叢集的第一次走通用手寫的 patch，不等模板。

### D7 模式由一個帶預設的替換變數決定：`CHAMBER_MODE`（提案；回答了 Open Question 3 的一半）

`app` 與橋接 container 的 `CHAMBER_MODE` 都寫成 `${CHAMBER_MODE:=observe}`。

- 不給這個鍵的叢集＝觀察模式（k8scc 那一側的預設也是 `observe`，兩邊一致）。所以把 component 接上不會讓 im 開始上線或開始被宣告訊息——那是第二個、分開的決定。
- 切到送達模式＝那座叢集的 `cluster-secrets` 多一個鍵 `CHAMBER_MODE=deliver`，由 `jg-cluster-template` 渲染（tasks 5.1 的欄位）。生產的兩座要 ferry133 點頭（root tasks 9.6）。
- 它登記在 `scripts/substitution-vocabulary.txt`。那份檔的規矩是「登記＝承諾某座叢集會帶這個鍵」；這裡的承諾是「**可以**帶」，不帶時有預設。這是那份表上第一個純粹可選的鍵之外的又一個（`HA_MCP_URL`、`IM_APPS_REPO` 是同一種），不是新形狀。
- **沒有放進來的**：`SESSION_KEEP`。它改變的不只是 chamber（session 常駐之後，舊的 inbox 通道也會在沒人看著時被處理——k8scc design 寫明），所以不跟著 component 走，留給 Open Question 3 的另一半。
- 橋接 container 多一個 `CHAMBER_SOCKET`（它聽的路徑）。**這個變數名是起草者取的，k8scc 的環境變數表還沒有它**——路徑兩邊對過，名字沒有；k8scc 定了別的名字就改這裡，守衛檢查的是「橋接聽的路徑＝`app` 連的路徑」。

## Risks / Trade-offs

- **[多一個 container 等於多一個讓 pod NotReady 的東西]** 橋接 container 不設 readiness probe（提案）：它的健康由 daily-check 那一列說，不由 Service 的流量說。代價是它掛了 pod 仍然 Ready——那正是要的。
- **[component 接上而映像裡還沒有橋接程式]** container 起不來，pod NotReady，終端機斷。所以 tasks 把「接上」排在 k8scc 的映像之後，而且只在拋棄式叢集。守衛擋不到這一格，因為它是兩個 repo 的版本關係。
- **[守衛檢查的是渲染出來的 values，不是 pod]** 它用 `flux build` 讀 values，另外對釘住的 chart 跑一次 `helm template`（斷言 10）——第一版沒有這一格，結果把一個 chart 不收的欄位釘成了必須，是驗收的人量出來的。渲染成 pod 之後的那一半（`app` 的檔案與 env 裡真的沒有憑證；以及 `app` 經 apiserver 讀得到它）在拋棄式叢集量一次（tasks 2.5）。
- **[flux-local 建不到它]** 沒有任何路徑引用 component，所以整個 CI 對它的覆蓋只有那一支守衛。
- **[公鑰清單是公開的]** 人的公鑰與代號進 public repo。它們不是秘密；但清單的每一次變動都會公開可見。

## Open Questions（等 ferry133 或驗收的人）

0. **給 ferry133：登入憑證要不要做到 `app` 真的讀不到。** 現在的形狀只讓它不躺在 `app` 的檔案與 env 裡；`app` 的 ServiceAccount 是 `cluster-admin`，讀得到（D3）。在 `cluster-admin` 之下，Secret 放在同一座叢集的任何地方都讀得到，所以做硬的路只有：(a) 縮小 im 的 SA 權限（那是 im 的整個設計，不是這個 change）；(b) 憑證不放在這座叢集的 Secret 裡（例如橋接程式不在 im 的 pod 裡）；(c) 接受——這把憑證只能說一般類的話，保留類只認人的簽章，而且撤銷一把憑證是量過的（root tasks 3.5）。起草者的看法是 (c)，這是我的判斷不是裁定。
1. 公鑰清單的正本住哪；這裡是正本還是副本（D4）。
2. 「驗章可用」要不要量到「真的驗過一份」（D5）。
3. `cluster.yaml` 的欄位長什麼樣（D6）——一個布林，還是連模式（observe／deliver）與 `SESSION_KEEP` 一起。
4. 橋接 container 要不要 liveness probe（卡死的橋接程式會讓 im 一直顯示不在線，daily-check 一天才看一次）。
