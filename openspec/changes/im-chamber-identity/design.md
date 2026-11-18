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

**沒量到的**：Flux 自己的 `spec.components`（kustomize-controller 讀它的方式、路徑相對於誰）。只量了本機的 kustomize。tasks 2.4 在拋棄式叢集上量。量不過的退路是兩個薄目錄（`im/chamber`、`im/netdev-chamber`，各自 `resources: ../x` ＋ `components: ../_chamber`），component 本身不必重寫。

### D2 登入憑證：Secret 由 user repo 帶來，這裡只引用名字，而且 `optional`（提案）

- 值是每座叢集一把、由 ferry133 鑄造（root 2.11）。這個 repo 是 public，不持有它，也不持有伺服器位址——位址放在同一個 Secret 的另一個鍵，只進橋接 container 的 env。
- 名字 `im-chamber`，鍵 `token`（掛成 `/etc/chamber/token`，唯讀，mode 0400）與 `url`（`secretKeyRef`，`optional: true`）。與 `ha-im-token`、`im-apps-write-key` 同一條路：sops → Secret → pod 裡的一個檔，不經 `cluster-secrets`。
- **`optional: true`**。不 optional 的話，component 接上而 Secret 還沒到的那一段時間，pod 會卡在 ContainerCreating——im 的終端機跟著沒了。k8scc 那一側的對應行為（2026-11-19 與 `k8scc-0f [7c5b85]` 對過）：橋接 container 在未設定或設定不全時**留著不退出**，印一行原因後閒置；0 位元組與不存在同一件事。chamber 的毛病不該把終端機帶下來。
- 帳號名不需要新欄位：`im-${CLUSTER_NAME}`，`CLUSTER_NAME` 已在 `cluster-secrets`（`scripts/substitution-vocabulary.txt:29`）。

### D3 socket：`emptyDir` 掛在 `/run/chamber`，只有兩個 container（讀數＋對過的提案）

im 的 pod 是 `hostNetwork: true`（`im/enabled/helmrelease.yaml` 的 `defaultPodOptions`），所以 loopback 是節點的 loopback。k8scc 的 spec 因此規定橋接程式只開 Unix socket、不開 TCP。pod spec 這一側：

- `emptyDir`（`medium: Memory`），`advancedMounts` 只列 `app` 與 `chamber-bridge`。路徑 `/run/chamber`，socket `/run/chamber/bridge.sock`，`app` 的 `CHAMBER_URL=unix:/run/chamber/bridge.sock`（2026-11-19 與 k8scc 對過；用戶端的 `unix:` 形式是 k8scc tasks 2.5，尚未實作）。
- `chamber-bridge` 不宣告任何 port；`allowPrivilegeEscalation: false`、drop ALL，與 `talos-mcp` 相同。
- **這擋的是憑證被帶走，不是 `app` 內的冒用**：能打開 socket 的行程都能以 im 的名義收發（k8scc design D-b 明寫）。守衛檢查的是前者。

### D4 公鑰清單：這個 repo 渲染的 ConfigMap，掛成目錄（提案；有一格等裁定）

- 兩個檔：`allowed_signers`、`revoked_signers`，放在 component 目錄裡，`configMapGenerator` ＋ `disableNameSuffixHash`（名字固定，內容更新不重建 pod）。掛成整個目錄 `/etc/chamber/signers`，**不用 `subPath`**——`subPath` 掛載不會跟著 ConfigMap 更新，而撤銷只在被更新的副本上生效。
- 為什麼放這裡：Flux 每小時把它送到每一座叢集，kubelet 再同步進 pod。這是現有的路裡唯一不需要人逐座去更新的。內容只有公鑰與人的代號，沒有客戶名單。
- 初始是空的。空清單下 `directive-verify` 回 2（量不到），不是 0。
- **等裁定**：清單的正本住哪（root 的未決項）。這裡持有的若是副本，更新它的 PR 由誰開、怎麼證明與正本相同，要在正本的位置定了之後補一個比對。**不論正本在哪，改這兩個檔的 PR 合併前要 ferry133 點頭**——那是在改「誰的話算指令」，而 agent 不得增加簽章者（root 的裁定）。
- **沒量到的**：ConfigMap 更新到 pod 裡的檔案實際要多久（tasks 3.3）。

### D5 daily-check：讀 pod log，不加 `exec`（提案）

daily-check 在 `claudecode` 只有 `pods/log`（`daily-check/claudecode/rbac.yaml`）。往一個握有叢集管理權的 agent pod 裡 `exec` 是比這一列大得多的權限，不加。`netdev-mcp sidecar` 那一列已經是這個形狀。

所以四個讀數來自兩行定期印出的狀態（格式是 k8scc 的草案，2026-11-19；**定稿前這一列不實作**）：

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
- **這一列量不到的**：`signers=<n>` 只說清單讀得到，不說驗章真的驗得過（k8scc 提醒；映像裡沒有測試向量）。「驗章可用」目前只到「工具與清單都在」。要更硬得另想，列為未決。

### D6 誰打開它（範圍外，寫下來以免被當成漏做）

打開＝某座叢集的 `claude-code-im` Kustomization 多一行 `components`。那一行由 user repo 的 patch 帶，而 patch 由 `jg-cluster-template` 渲染——所以是一個 `cluster.yaml` 欄位，屬該 repo 的 issue，**合併前要 ferry133 點頭**（root tasks 7.4）。拋棄式叢集的第一次走通用手寫的 patch，不等模板。

## Risks / Trade-offs

- **[多一個 container 等於多一個讓 pod NotReady 的東西]** 橋接 container 不設 readiness probe（提案）：它的健康由 daily-check 那一列說，不由 Service 的流量說。代價是它掛了 pod 仍然 Ready——那正是要的。
- **[component 接上而映像裡還沒有橋接程式]** container 起不來，pod NotReady，終端機斷。所以 tasks 把「接上」排在 k8scc 的映像之後，而且只在拋棄式叢集。守衛擋不到這一格，因為它是兩個 repo 的版本關係。
- **[兩道守衛都是文字檢查]** 與 `check-operator-credential-isolation.sh` 同一個取捨：需要 helm 的守衛在 CI 上每次都量不到。渲染成 pod 之後的那一半（`app` 裡真的看不到憑證）在拋棄式叢集量一次（tasks 2.5）。
- **[公鑰清單是公開的]** 人的公鑰與代號進 public repo。它們不是秘密；但清單的每一次變動都會公開可見。

## Open Questions（等 ferry133 或驗收的人）

1. 公鑰清單的正本住哪；這裡是正本還是副本（D4）。
2. 「驗章可用」要不要量到「真的驗過一份」（D5）。
3. `cluster.yaml` 的欄位長什麼樣（D6）——一個布林，還是連模式（observe／deliver）與 `SESSION_KEEP` 一起。
4. 橋接 container 要不要 liveness probe（卡死的橋接程式會讓 im 一直顯示不在線，daily-check 一天才看一次）。
