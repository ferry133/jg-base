Part of: `fleet-ops` / `agent-delegation-envelope`

**Owning repo**：`jg-base` —— 本 sub-change 改的檔案（`kubernetes/apps/base/claudecode/claude-code/im/` 下新增的一個 component、`monitoring/daily-check/app/configmap.yaml` 的新列、`scripts/` 的守衛、`.github/workflows/flux-local.yaml`）全在這裡。root change 住在 private 的 `fleet-ops`，持有跨 repo 的契約（房間與成員、指令格式、收件方流程、裁定表）；**設計不在這裡複述，以那裡為準**。橋接程式與 `app` 內的用戶端、驗章工具屬 k8scc 的姊妹 sub-change `im-chamber-client`（`k8scc#70`，已在該 repo 的 main）。請求在 `jg-base#248`。

> 起草：`fleet-ops-98 [047e9c]`，2026-11-19，依 ferry133 當日在該 session 的指示（「go ahead with section 7」）。**起草的人不是這個 repo 的擁有者，也不自己驗收**——驗收與合併歸工作目錄在 `jg-base` 的 session。

## Why

root 的 Why 不在這裡複述。jg-base 的份額是 pod 這一層：im 要以一個成員的身分連上 chamber（agent 之間的聊天室），需要三樣東西住在 pod spec 裡，而 pod spec 在這個 repo。

1. **登入憑證放在哪個 container。** k8scc 那一側把連線拆成兩支：握憑證的 `chamber-bridge`，以及 `app` 裡不帶憑證的用戶端。那個拆法只有在憑證真的只掛進橋接 container 時才有意義——`app` 是一個有人打字、有 agent 在跑的 root shell。
2. **人的公鑰清單。** `app` 裡的 `directive-verify` 靠它判斷「這段話是不是人簽的」。撤銷只在副本被更新的地方生效（root tasks 3.7 量到：沒更新的副本上，被撤銷的金鑰簽的指令照樣回 0），所以清單要走一條會自己更新的路。
3. **每天量一次。** 「連得上嗎／在對的房間嗎／驗章工具可用嗎／在線嗎」沒有人看就不會有人知道它壞了；im 不在線照 root 的裁定（R20）是故障。

讀到的現況（2026-11-19，`origin/main c557d7a`）：im 的 pod 是 `hostNetwork: true`、全部 container 以 uid 0 跑；`im/netdev` 已經是「`im/enabled` 加一個 container」的 overlay，由 `jg-cluster-template` 選路徑；daily-check 在 `claudecode` 只有 `pods/log`，沒有 `exec`。

## What Changes

- **新增 kustomize component `im/chamber`**：在 im 的 HelmRelease 上加一個 container `chamber-bridge`（映像與 `app` 同一個 pin，用 replacement 複製，不另寫一份）、一個只給 `app` 與它兩個掛的 `emptyDir`（Unix socket 住在裡面）、一個只掛進它的登入憑證 Secret（`optional`）、以及掛進 `app` 的公鑰清單 ConfigMap。橋接 container 不開任何 TCP port。
- **它是 component 不是第三條路徑**：`im/enabled` 與 `im/netdev` 各自都能加上它，不必為每一種組合開一個目錄。本機量過（design D1）。
- **預設不接**：沒有任何現有路徑引用這個 component，所以合併之後每一座叢集的渲染結果逐位元組不變。守衛 `scripts/check-chamber-component.sh` 守兩個方向：不接時不變；接上之後扣掉新增的部分等於原本的渲染。
- **守衛 `scripts/check-chamber-credential-isolation.sh`**：登入憑證的 Secret 只出現在 `chamber-bridge` 的掛載裡，不在 `app`、不在任何其他 container 的 env 或 volume；socket 的 `emptyDir` 只有兩個 container 掛；`chamber-bridge` 沒有 port。
- **公鑰清單的 ConfigMap** 由這個 repo 渲染（兩個檔：`allowed_signers`、`revoked_signers`，掛成一個目錄、不用 `subPath`）。初始內容是空的——還沒有人的簽章金鑰（root tasks 4.2）。**改這兩個檔等於改「誰的話算指令」，合併前要 ferry133 點頭**，不走一般的 issue→驗收→合併。
- **daily-check 新增一列**（四個讀數合成一列）：伺服器連得上、所屬房間與預期一致、驗章工具可用、im 在線。來源是 pod log 裡的狀態行。三種結果；狀態行太舊或讀不到＝量不到，不算綠。
- **不動**：`im/enabled`、`im/netdev` 的任何檔；`claude-code-im` 這個 Kustomization 的預設；`cluster-secrets` 的鍵。
- **不在本 sub-change**：哪一座叢集把它打開（那是 user repo 的一行，以及 `jg-cluster-template` 的一個欄位——root tasks 7.4，另開該 repo 的 issue，合併前要 ferry133 點頭）；登入憑證的鑄造（root 2.11：只有 ferry133）；伺服器本身。

## Capabilities

### New Capabilities

- `im-chamber-identity`: im 的 pod 以什麼形狀帶著 chamber 的身分——憑證只在橋接 container、socket 只有兩個 container 看得到、公鑰清單會自己更新、每天量一次、沒打開的叢集什麼都不變。

### Modified Capabilities

（無。既有的 `talos-mcp-sidecar` spec 不變。）

## Impact

- **合併本身**：不改變任何叢集的 im pod（守衛守住這一句）。daily-check 多一列，在沒接 component 的叢集上是 `skip`，並說出原因。
- **打開之後**（每座叢集各自的決定，不是這個 PR）：im pod 多一個 container、多掛一個 Secret 與一個 ConfigMap，pod 會重建一次。**這會改變現有 im pod，要 ferry133 點頭**；生產的兩座先跑觀察模式（root tasks 9.6）。
- **依賴**：橋接程式還不在映像裡（k8scc tasks 3.x）。在那之前 component 可以渲染、可以被守衛檢查，但接上去的 pod 起不來那個 container——所以第一次接上只在拋棄式叢集做。
- **狀態行的格式還是草案**（k8scc 定稿後貼到 `jg-base#248`）；daily-check 那一列在定稿前不實作。
