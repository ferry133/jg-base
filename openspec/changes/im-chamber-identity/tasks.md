> 全部在 `jg-base`，除非該行另寫。root：`fleet-ops/openspec/changes/agent-delegation-envelope`（tasks 第 7 組）。請求：`jg-base#248`。姊妹：k8scc `im-chamber-client`（`k8scc#70`）。
>
> **停在哪裡**：合併到 `main` 一小時內套到每一座叢集。第 1、2 組的產物在「沒有任何路徑引用 component」的前提下不改變任何 pod，照 issue→驗收→合併走。**會讓某一座現有的 im pod 改變的每一步（把 component 接上、改公鑰清單）停下來由 ferry133 點頭。** 這份檔不是授權。
>
> 每一格寫下：量到什麼、沒量到什麼。三種結果——通過／失敗／量不到。

## 1. component 與守衛（不接上任何叢集）

- [x] 1.1 `kubernetes/apps/base/claudecode/claude-code/im/chamber/`：`kind: Component`——patch（`chamber-bridge` container、`app` 的 `CHAMBER_URL`／`CHAMBER_ACCOUNT`／`CHAMBER_SIGNERS_DIR`、三個 volume）、replacement（橋接的 tag 取自 `app`）、公鑰清單的 `configMapGenerator`（兩個空檔，`disableNameSuffixHash`）
- [x] 1.2 `scripts/check-chamber-component.sh`：(a) `kubernetes/` 下除了 component 自己的目錄，沒有任何 YAML 引用 `im/chamber`（`im/enabled`、`im/netdev`、`im-ks.yaml`、任何 `ks.yaml`）——對照：在 `im-ks.yaml` 加一行引用 → 紅。（初稿寫「與 `main` 逐位元組相同」，合併後是自己比自己，永遠綠；`jg-base-56 [c30591]` 指出）；(b) `enabled`、`netdev` 各自加上 component 後，扣掉新增的部分等於原渲染——對照：patch 多改 `app` 一個既有欄位 → 紅；(c) 橋接的 tag 等於 `app` 的 tag
- [x] 1.3 同一支守衛（不另開一支）：Secret `im-chamber` 進得了 container 的**每一條路**都只通到 `chamber-bridge`——`persistence.*.advancedMounts`、`persistence.*.globalMounts`（會掛進每一個 container，這幾個 volume 一律不准用）、projected volume、`env.*.valueFrom.secretKeyRef`、`envFrom`，`initContainers` 也算；兩處 `optional` 都在；socket 的 `emptyDir` 恰好兩個 container 掛、同一個路徑、`app` 的位址在裡面；`chamber-bridge` 沒有 port、沒有 probe；公鑰清單只進 `app`、唯讀、沒有 `subPath`、ConfigMap 恰好兩個檔。變異每條斷言至少一個，含「整行刪掉 `optional: true`」；第 0 格不變異、期望綠；每個變異先確認真的套用了，而且要因為**說得出的那個理由**變紅
- [x] 1.4 守衛接進 `.github/workflows/flux-local.yaml`（它是這個 component 唯一的 CI 覆蓋）；`check-substitution-vocabulary.sh` 仍綠——新增的替換變數只有 `CHAMBER_MODE`（帶預設 `observe`），要登記進 `scripts/substitution-vocabulary.txt`，那是一個要被看過的決定；`CLUSTER_NAME` 已在表上
- [x] 1.5 `claude-code/README.md`：一節說明這個 component、怎麼打開、打開要誰點頭
  - **2026-11-19，`fleet-ops-98 [047e9c]`（第 1 組整組，`ferry133/jg-base#251`）**。第一版（`a9ae18c`）驗收不通過，`jg-base-56 [c30591]` 量到兩格：chart 的 schema 不收 `secretKeyRef.optional`（接上去會 upgrade 失敗，而守衛還把那個欄位釘成必須）；「沒有東西引用它」只認得一種 YAML 寫法。第二版量到的——守衛 rc=0；`--self-test` 44 格（第 0 格不變異＝綠；42 個變異各自因為說得出的理由變紅，每格印出改前改後的 cksum 與抓到它的那一行；讀取器瞎掉＝2）；新增斷言 10（對釘住的 chart 跑 `helm template`，對照是不加 component 的同一份 values）；`check-substitution-vocabulary.sh`、`check-netdev-overlay.sh`、`check-envsubst-parses.sh` 仍 rc=0。**沒量到的**——任何 pod 上的東西；叢集裡的 kustomize-controller 讀 `spec.components`、helm-controller 驗 schema（量的都是 CLI）；映像裡還沒有 `chamber-bridge`，這個 container 從來沒起過

## 2. 在拋棄式叢集接上一次（等 k8scc 的映像裡有 `chamber-bridge`）

- [x] 2.1 確認要用的映像 pin 含 `chamber-bridge`（k8scc tasks 3.x）；沒有就停在這裡，不接
- [x] 2.2 事前寫下預期，再做：手寫 patch 在拋棄式叢集的 `claude-code-im` 加 `spec.components`
- [x] 2.3 （前半 2026-11-20 量，後半 2026-11-24 量）Secret 還不存在時：pod Running 且 Ready、終端機照常、橋接 container 的 log 有一行說缺什麼（design D2 的那一格）。**接著量 Secret 晚到**（事前寫預期）：pod 不重啟，Secret 建立之後多久 `/etc/chamber/` 出現兩個檔、橋接程式多久自己啟動；位址與憑證分兩次到各量一次。量不到自己啟動，就把「Secret 到位後要重啟 pod」寫進 README
  - **前半（Secret 不存在）**：2026-11-20，`fleet-ops-98 [047e9c]` 量的，本 repo 未複量（同一則 issuecomment-7015427750）。
    - 橋接 container 印一行說位址檔不在，什麼都不開。之後每 20 秒印一行 `chamber-status … mode=unconfigured server=unmeasured rooms=unmeasured online=unmeasured`，不重啟。
    - 終端機照常回 302。`app` 每 20 秒印一行 `chamber-verify-status … signers=0 revoked=0 sshkeygen=ok`。
    - 同一顆映像上的 `talos-mcp`、`netdev-mcp` 正常起來。
  - **後半（Secret 晚到）**：2026-11-24，`fleet-ops-02 [e3795b]` 在 jg-jcc2 量的，本 repo 未複量（`ferry133/jg-base#248` issuecomment-7131020120）。預期是 `jg-base-d4 [a9cc43]` 在量之前寫的，四格都相符。
    - Secret 只帶 `url`：`/etc/chamber/url` 39 秒後出現，橋接程式改印 `incomplete — the credential file /etc/chamber/token is absent or unreadable`，沒有啟動。
    - 補上 `token`：`/etc/chamber/token` 39 秒後出現；再 19 秒橋接程式自己印 `started`，接著 `server=ok rooms=cust-jg-jcc2`。從 Secret 完整到啟動共 58 秒。
    - pod 沒有重啟：同一個 uid，五個 container 的 restartCount 都是 0。**所以 README 不需要寫「Secret 到位後要重啟 pod」。**
    - 做法：那座的 `im-chamber` 是手建的 Secret，直接刪掉再分兩次放回；沒有鑄造新憑證，結束時資料雜湊與開始時相同。
    - **沒量的**：只量一次；只在 `deliver`；只量「先 url、後 token」；Secret 由 Flux 渲染而晚到的情形（jcom、jg-jiahd 的形狀）。39 秒是那一座當下的延遲，不是上限。
- [x] 2.4 Flux 的 `spec.components` 真的照 design D1 渲染（讀叢集上的 HelmRelease，不讀本機的 kustomize）；量不過就改走兩個薄目錄並記下原因
  - **2026-11-20，`fleet-ops-98 [047e9c]` 量的，這個 repo 的 session 沒有複量**（`ferry133/jg-base#248` issuecomment-7015427750；在一座拋棄式叢集上，jg-base `de4479b`，映像 `9e1471f`；勾 2.1／2.2／2.4 由 `jg-base-5d [905a80]` 2026-11-22 照那則讀數打）。
    - **2.1**：tag `9e1471f` 在 registry 回 200，digest `sha256:27a4b2b7…845ea`；不存在的 tag 回 404 當對照。
    - **2.2**：預期事前寫下了，所有讀數都和預期相符。patch 寫在那座叢集自己 repo 的 `claude-code-im` 上：`spec.components: [../chamber]`，再把每一個用這顆映像的 container 的 tag 改掉。
    - **2.4**：叢集上的 `claude-code-im` Ready，`spec.components=["../chamber"]`（這次是叢集裡的 kustomize-controller，先前只量過 CLI）；helm-controller `Helm upgrade succeeded`，chart `app-template@4.6.2`（先前只量過 `helm template`）；pod 五個 container 全 ready、重啟 0，多了 `chamber-socket`、`chamber-token`、`chamber-signers` 三個 volume；ConfigMap `im-chamber-signers` 有兩個鍵，都是空的。
    - **2.4 的限定**：這一格要求讀叢集上的 HelmRelease。原讀數引的是 Kustomization 的 `spec.components`、helm-controller 的結果，以及 pod 的 container／volume，**沒有引 HelmRelease 物件本身的 values**。打勾是以 pod 這個下游證據接受的，那是驗收者 `fleet-ops-d5 [d1b006]` 的判斷（#259 issuecomment-7077860633）。
    - **量到的接線細節**：手動改 tag 時要改**每一個** container，含 `chamber-bridge`。原因是 component 的 replacement 在 patch 之前就抄了 `app` 的舊 tag。
- [x] 2.5 Secret 到位後，在 pod 裡量：`app` 的 env 與掛載裡沒有憑證（對照：`chamber-bridge` 裡有）；**`app` 以 pod 的 ServiceAccount 問 apiserver 讀得到那個 Secret**（預期：讀得到——design D3；只確認有沒有那個鍵，不印值）；節點上屬於橋接程式的 TCP listener 是 0（對照：同一份清單看得到 ttyd 的 port）；socket 目錄只在兩個 container 看得到
  - **2026-11-24 20:0x，`jg-base-d4 [a9cc43]`，jg-jcc2，pod `im-7cd65c5d48-44p6m`（映像 `ebdf226`，路徑 `im/netdev`＋`../chamber`，`mode=deliver`），只讀不寫。** 預期事前寫下，每一格都相符。
    - **`app` 裡沒有憑證**：`/etc/chamber` 底下只有 `signers`，`token`、`url` 都不存在；env 裡名字含 chamber 的有 5 個，沒有 `CHAMBER_TOKEN_FILE`／`CHAMBER_URL_FILE`。另外把 `app` 每一個 env 的值取 sha256，與橋接 container 裡憑證檔的 sha256 比：0 個相同。對照：同一段比對在橋接 container 裡對憑證檔自己跑，回報相同（比對的寫法沒有壞）。全程沒有印出任何值。
    - **`chamber-bridge` 裡有**：`/etc/chamber/token`、`/etc/chamber/url` 兩個檔，都非空。
    - **`app` 問得到 apiserver**：在 `app` 裡以 pod 的 ServiceAccount（`system:serviceaccount:claudecode:claude-code`）讀 Secret `im-chamber`，rc=0，鍵是 `token` 與 `url`（只印鍵名）。對照：不存在的 Secret 回 NotFound。**所以 design D3 那一句是量到的了：這一層擋不住 `app` 去讀憑證。**
    - **橋接程式的 TCP listener 是 0**：在橋接 container 裡 `ss -ltnp`，節點上 27 個 listener 沒有一個屬於它看得到的行程；它唯一的 listener 是 Unix socket `/run/chamber/bridge.sock`（`python3`，pid 1）。對照：同一個指令在 `app` 裡看得到 `127.0.0.1:7681` 屬於 `ttyd`。
    - **socket 目錄只有兩個 container 有**：`/run/chamber` 在 `app` 與 `chamber-bridge` 存在，在 `talos-mcp`、`netdev-mcp` 不存在。`oauth2-proxy` 的映像沒有 shell，進不去；它是從 pod spec 讀的（沒有任何 chamber 的 volumeMount）。
    - **沒量的**：只量了一座、一個 pod。`oauth2-proxy` 的檔案系統沒有實際看。jg-jcc2 的橋接 container 多了 `CHAMBER_SIGNERS_DIR`、`CHAMBER_TRANSCRIPTS` 兩個 env，`app` 多了 `CHAMBER_TRANSCRIPTS`，不在這個 repo 的 component 裡；來源沒有查。
- [ ] 2.6 拆掉 patch 後 pod 回到原樣（container 數、volume 數與接上之前相同）
  - **2026-11-24：沒做，等 ferry133。** `fleet-ops-02 [e3795b]` 判它是破壞性操作（預期的結果本身就包含刪掉 PVC `im-chamber-state`），已在自己的 console 問 ferry133。
- [ ] 2.7 事前寫下預期，再量：`components` 那一行還在而路徑切到 `im/disabled`——預期 `claude-code-im` BuildFailed、im 的 HelmRelease **沒有被 prune**（design D1 的限制）；拿掉那一行後才被 prune
  - **2026-11-24：沒做，等 ferry133。** `fleet-ops-02 [e3795b]` 在 jg-jcc2 讀到：Helm release `im` 的四個 PVC（`im-claude-config`、`im-claude-workspace`、`im-netdev-snapshots`、`im-chamber-state`）都是 `local-path`、reclaim `Delete`。HelmRelease 被 prune 時四個會一起被刪，包括 im 的登入狀態與 workspace。這一格的後半不是「im 停一下」。

## 3. 公鑰清單

- [x] 3.1 等裁定：正本住哪（design Open Question 1）。定了之後補「這裡的副本與正本相同」的比對，或寫明這裡就是正本
  - **裁定（ferry133，2026-11-24，在 `jg-base-d4 [a9cc43]` 的 console 選的選項）：正本在 `fleet-ops/chamber/`，這裡是副本。** 選項的原文是我寫的：「fleet-ops 是正本。jg-base 放副本給 im 用。因為 fleet-ops 是 private，jg-base 的 CI 讀不到它，所以『副本與正本相同』的比對放在 fleet-ops 那一側跑。」
  - **比對是現成的工具**：`chamber-signers check --copy kubernetes/apps/base/claudecode/claude-code/im/chamber/signers`，在同時有兩個 repo 的機器上跑。0＝副本的金鑰與正本完全相同，1＝不同（逐條印出），2＝量不到。它比的是金鑰，不是位元組。
  - **這個 repo 的 CI 量不到這一格**，也不假裝量得到：沒有任何步驟斷言副本與正本相同。誰定期跑、多久跑一次，歸 fleet-ops（見 3.2 的 PR 開的那張單）。
  - **更新副本的方式**：`chamber-signers install --copy <同一個目錄>`，不手改。手改的副本與正本只差一個字時，`check` 會說出來；沒有人跑 `check` 時不會有任何東西說。
- [x] 3.2 第一把人的金鑰進清單——**PR 合併前 ferry133 點頭**；PR 由誰開照 3.1 的裁定
  - **2026-11-24 19:03，`jg-base-d4 [a9cc43]`：已合併、已驗收。**
    - #264 由 ferry133 本人在 GitHub UI 合併（`3f4f231`，合併的 head 是 `5e0b823`）。我沒有按。
    - 驗收由開單者 `fleet-ops-02 [e3795b]` 在 #263 上給（留言 7129599247）：jcom、jg-jiahd、jg-jcc2 三座 im 的 `chamber-verify-status` 從 pod 起來之後每一行都是 `signers=1 revoked=0 sshkeygen=ok`。那一行在 `app` 容器的 log，不在 `chamber-bridge`。
    - **沒驗的**（照那則驗收）：沒有在任何 im 上驗過一份真的簽章。jg-jcc2 的清單來自該座 repo 自己的 patch，不是這裡的副本。
  - **2026-11-24，`jg-base-d4 [a9cc43]`：PR 已開，停在合併之前。** 副本由 `chamber-signers install --copy` 寫入，來源是 fleet-ops `80ab7b4` 的那兩個檔。
    - 事前：`check` 回 1，印出「副本缺 ferry133 的一把金鑰」。事後：回 0，`SAME`（正本 1 人 1 把、撤銷 0）。兩個檔與正本逐位元組相同（`cmp`）。
    - `check-chamber-component.sh` 仍 rc=0。
    - **合併會改到兩座現有的 im**（同日用 `kubeconfig-sa` 讀的）：jcom 與 jg-jiahd 的 `claude-code-im` 都是 `spec.components=["../chamber"]`，叢集上的 ConfigMap `im-chamber-signers` 兩個鍵都是 0 位元組。合併後一小時內，那兩座 im 的清單由空變成一把金鑰——也就是 im 開始有辦法驗 ferry133 簽的指令。
    - **已知的一個瑕疵，不在這裡修**：副本是逐位元組照抄的，所以檔頭那一行仍寫著「THE ORIGINAL」，而且有一行「2026-11-17: no key yet」已經不成立。兩行都是註解，`ssh-keygen` 不讀；改它們要改正本或改工具，那是 fleet-ops 的。
    - **沒量的**：任何 pod 裡的檔案（3.3）。
- [x] 3.3 量：改了 ConfigMap 之後，pod 裡 `/etc/chamber/signers` 的檔案多久跟上（不重建 pod）；撤銷一把測試金鑰，同一份指令在 pod 裡由 0 變 1。對照：`subPath` 掛的同一個檔不會變
  - **2026-11-24 20:05，`jg-base-d4 [a9cc43]`，jg-jcc2。量的是機制，不是 im 自己的清單。**
    - 做法：一個拋棄式 namespace，裡面一個 ConfigMap（`allowed_signers`、`revoked_signers`）和一個 pod，映像與 im 同一顆（`ebdf226`）。同一個 ConfigMap 掛兩次：整個目錄掛在 `/etc/chamber/signers`（與 component 相同），另外用 `subPath` 各掛一個檔。金鑰是當場產生、用完即丟的測試金鑰；測試訊息由它簽，內文寫明不授權任何事。**im 的清單與 ConfigMap `im-chamber-signers` 沒有被碰。** 量完 namespace 已刪，讀回 NotFound。
    - 預期（事前）：目錄掛載 1–2 分鐘內跟上；`subPath` 不會變；pod 裡 `directive-verify` 由 0 變 1。
    - 讀數：把測試金鑰加進 `revoked_signers`（12:05:19Z）。目錄掛載的檔在 **42 到 58 秒之間**換成新內容（每 5 秒讀一次；雜湊與叢集上 ConfigMap 的相同），同一次讀數 `directive-verify` 對同一份訊息由 **0 變 1**。pod 沒有重建。
    - 對照：`subPath` 掛的那一份在 213 秒後仍是舊內容，`directive-verify` 仍回 0。另一個對照：指向不存在的清單回 2（量不到），所以 1 不是「讀不到」。
    - **沒量的**：只量一次，58 秒不是上限（kubelet 的同步週期加快取）。沒有在 im 的 pod 上量；Flux 把 repo 的變更送到 ConfigMap 的那一段（最長 1 小時）不在這個數字裡。新增一把金鑰的方向沒有另外量，機制相同。

## 4. daily-check 的一列（等 k8scc 把狀態行的格式定稿並貼到 `jg-base#248`）

- [x] 4.1 格式定稿之前不寫。定稿後照 design D5 的表實作一列；預期的房間由 `CLUSTER_NAME` 推
  - **2026-11-24，`jg-base-d4 [a9cc43]`。** 格式由 `k8scc-bf [97703c]` 定稿並貼在 `ferry133/jg-base#248` issuecomment-7130894158（v1，讀自 k8scc `ebdf226`）。列是第 33 列「im chamber」。
    - 與 design D5 的表有三處不同，都寫回 D5 了：過期門檻是 `3 × interval + 300 秒`；`app` 沒有 `chamber-verify-status` 而 `chamber-watch` 自己說了沒起來時是 `warn`，不是 `skip`；預期的房間是 `cust-<CLUSTER_NAME>`，剛好一間。
    - **把同一段程式從這台 Mac 對三座叢集唯讀跑了一次**（不是 CronJob 跑的）：jcom `ok`（observe、`cust-jcom`）；jg-jiahd `skip`（`rooms=unmeasured`，橋接程式讀不到房間名）；jg-jcc2 `fail`（deliver 而 `online=no`，當時 pod 剛被換過、裡面沒有 session）。三個結果都與當下的事實相符。
    - daily-check 的 ServiceAccount 讀得到這兩份 log（`kubectl auth can-i get pods/log --as …`，jg-jcc2，yes）。
- [x] 4.2 `scripts/check-chamber-row.sh`：表上每一個情形各一份 fixture log，結果逐格相符；「狀態行太舊」與「欄位是 unmeasured」各自落在 `skip`，不落在 `ok`
  - 34 格 fixture，其中三格是 2026-11-24 在三座叢集讀到的原行（只換 `ts`）。「太舊」兩側各一格，另一格證明門檻跟著那一行自己的 `interval`。`--self-test` 13 格：第 0 格不變異＝綠；10 個變異各自先確認檔案真的變了，再確認是它瞄準的那一格變紅；ConfigMap 讀不到、列標頭不見各回 2。
- [x] 4.3 `daily-check/README.md` 的圖例加這一列；`check-row-numbers-resolve.sh` 仍綠
  - 守衛第一次跑是紅的：README 標題寫 34 項而表有 35 列。改成 35 後 rc=0。
- [ ] 4.4 在拋棄式叢集上各看到一次：沒接（`skip`）、接了沒設定（`warn`）、觀察模式（`ok`，在線不判）、送達模式且 session 在（`ok`）、送達模式而 session 不在（`fail`）
  - **2026-11-24：五種裡看到兩種，而且不是 CronJob 看到的**（見 4.1：從這台 Mac 跑同一段程式）。觀察模式 `ok`（jcom）與送達模式而 session 不在 `fail`（jg-jcc2）。
  - **還沒看到的**：沒接、接了沒設定、送達模式且 session 在。**CronJob 自己印出這一列一次都還沒有**——那要等這一列合併、Flux 套用、08:00 那一輪跑完。這一格在那之後才勾。

## 5. 範圍外的指標

- [x] 5.1 `jg-cluster-template` 的 issue：打開 component 的 `cluster.yaml` 欄位（root tasks 7.4）。**合併前要 ferry133 點頭**——客戶會繼承的行為。issue 要帶上 design D1 的限制：欄位打開而路徑是 `im/disabled` 時，渲染要拿掉 `components`，並且要有守衛
  - **2026-11-22**：`ferry133/jg-cluster-template#263` 已由 #270 squash 合併（`1b43f91`）。
    - 合併的依據是 ferry133 在 `fleet-ops-4c [50fff3]` 的 console 直接下的指示（保留類第 4 條），原話是「合併 #270，兩條額外拒絕也算在內」。所以點頭的範圍也涵蓋設計四點以外的兩條拒絕：`chamber_mode: off` 卻帶了憑證，以及兩把憑證只給一把。
    - 欄位是 `chamber_mode`（`off`／`observe`／`deliver`）、`chamber_token`、`chamber_url`。
    - D1 的限制由 plugin 擋：im 走 `im/disabled`（`claudecode_auth0: false`）時，只要 `chamber_mode` 是 `observe` 或 `deliver` 就拒絕渲染（`off` 照常）。路徑是 `disabled` 時，`ks.yaml.j2` 也不會輸出 `components`。守衛是 `scripts/check-chamber-render.py`，共 18 格。
    - **沒量的**：任何叢集上的 reconcile，以及 `im-chamber` 經 sops 解密之後的套用。
- [ ] 5.2 完成時在 `jg-base#248` 回報 commit，以及驗到什麼、沒驗到什麼；由開單者驗收
