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
- [ ] 2.3 （**前半已量，後半未量**）Secret 還不存在時：pod Running 且 Ready、終端機照常、橋接 container 的 log 有一行說缺什麼（design D2 的那一格）。**接著量 Secret 晚到**（事前寫預期）：pod 不重啟，Secret 建立之後多久 `/etc/chamber/` 出現兩個檔、橋接程式多久自己啟動；位址與憑證分兩次到各量一次。量不到自己啟動，就把「Secret 到位後要重啟 pod」寫進 README
  - **前半（Secret 不存在）**：2026-11-20，`fleet-ops-98 [047e9c]` 量的，本 repo 未複量（同一則 issuecomment-7015427750）。
    - 橋接 container 印一行說位址檔不在，什麼都不開。之後每 20 秒印一行 `chamber-status … mode=unconfigured server=unmeasured rooms=unmeasured online=unmeasured`，不重啟。
    - 終端機照常回 302。`app` 每 20 秒印一行 `chamber-verify-status … signers=0 revoked=0 sshkeygen=ok`。
    - 同一顆映像上的 `talos-mcp`、`netdev-mcp` 正常起來。
  - **後半（Secret 晚到）沒量**：Secret 還不存在。鑄造登入憑證要 ferry133 點頭（保留類第 5 條）。
- [x] 2.4 Flux 的 `spec.components` 真的照 design D1 渲染（讀叢集上的 HelmRelease，不讀本機的 kustomize）；量不過就改走兩個薄目錄並記下原因
  - **2026-11-20，`fleet-ops-98 [047e9c]` 量的，這個 repo 的 session 沒有複量**（`ferry133/jg-base#248` issuecomment-7015427750；在一座拋棄式叢集上，jg-base `de4479b`，映像 `9e1471f`；勾 2.1／2.2／2.4 由 `jg-base-5d [905a80]` 2026-11-22 照那則讀數打）。
    - **2.1**：tag `9e1471f` 在 registry 回 200，digest `sha256:27a4b2b7…845ea`；不存在的 tag 回 404 當對照。
    - **2.2**：預期事前寫下了，所有讀數都和預期相符。patch 寫在那座叢集自己 repo 的 `claude-code-im` 上：`spec.components: [../chamber]`，再把每一個用這顆映像的 container 的 tag 改掉。
    - **2.4**：叢集上的 `claude-code-im` Ready，`spec.components=["../chamber"]`（這次是叢集裡的 kustomize-controller，先前只量過 CLI）；helm-controller `Helm upgrade succeeded`，chart `app-template@4.6.2`（先前只量過 `helm template`）；pod 五個 container 全 ready、重啟 0，多了 `chamber-socket`、`chamber-token`、`chamber-signers` 三個 volume；ConfigMap `im-chamber-signers` 有兩個鍵，都是空的。
    - **量到的接線細節**：手動改 tag 時要改**每一個** container，含 `chamber-bridge`。原因是 component 的 replacement 在 patch 之前就抄了 `app` 的舊 tag。
- [ ] 2.5 Secret 到位後，在 pod 裡量：`app` 的 env 與掛載裡沒有憑證（對照：`chamber-bridge` 裡有）；**`app` 以 pod 的 ServiceAccount 問 apiserver 讀得到那個 Secret**（預期：讀得到——design D3；只確認有沒有那個鍵，不印值）；節點上屬於橋接程式的 TCP listener 是 0（對照：同一份清單看得到 ttyd 的 port）；socket 目錄只在兩個 container 看得到
- [ ] 2.6 拆掉 patch 後 pod 回到原樣（container 數、volume 數與接上之前相同）
- [ ] 2.7 事前寫下預期，再量：`components` 那一行還在而路徑切到 `im/disabled`——預期 `claude-code-im` BuildFailed、im 的 HelmRelease **沒有被 prune**（design D1 的限制）；拿掉那一行後才被 prune

## 3. 公鑰清單

- [ ] 3.1 等裁定：正本住哪（design Open Question 1）。定了之後補「這裡的副本與正本相同」的比對，或寫明這裡就是正本
- [ ] 3.2 第一把人的金鑰進清單——**PR 合併前 ferry133 點頭**；PR 由誰開照 3.1 的裁定
- [ ] 3.3 量：改了 ConfigMap 之後，pod 裡 `/etc/chamber/signers` 的檔案多久跟上（不重建 pod）；撤銷一把測試金鑰，同一份指令在 pod 裡由 0 變 1。對照：`subPath` 掛的同一個檔不會變

## 4. daily-check 的一列（等 k8scc 把狀態行的格式定稿並貼到 `jg-base#248`）

- [ ] 4.1 格式定稿之前不寫。定稿後照 design D5 的表實作一列；預期的房間由 `CLUSTER_NAME` 推
- [ ] 4.2 `scripts/check-chamber-row.sh`：表上每一個情形各一份 fixture log，結果逐格相符；「狀態行太舊」與「欄位是 unmeasured」各自落在 `skip`，不落在 `ok`
- [ ] 4.3 `daily-check/README.md` 的圖例加這一列；`check-row-numbers-resolve.sh` 仍綠
- [ ] 4.4 在拋棄式叢集上各看到一次：沒接（`skip`）、接了沒設定（`warn`）、觀察模式（`ok`，在線不判）、送達模式且 session 在（`ok`）、送達模式而 session 不在（`fail`）

## 5. 範圍外的指標

- [x] 5.1 `jg-cluster-template` 的 issue：打開 component 的 `cluster.yaml` 欄位（root tasks 7.4）。**合併前要 ferry133 點頭**——客戶會繼承的行為。issue 要帶上 design D1 的限制：欄位打開而路徑是 `im/disabled` 時，渲染要拿掉 `components`，並且要有守衛
  - **2026-11-22**：`ferry133/jg-cluster-template#263` 已由 #270 squash 合併（`1b43f91`）。
    - 合併的依據是 ferry133 在 `fleet-ops-4c [50fff3]` 的 console 直接下的指示（保留類第 4 條）。
    - 欄位是 `chamber_mode`（`off`／`observe`／`deliver`）、`chamber_token`、`chamber_url`。
    - D1 的限制由 plugin 擋：im 走 `im/disabled`（`claudecode_auth0: false`）時，只要 `chamber_mode` 是 `observe` 或 `deliver` 就拒絕渲染（`off` 照常）。路徑是 `disabled` 時，`ks.yaml.j2` 也不會輸出 `components`。守衛是 `scripts/check-chamber-render.py`，共 18 格。
    - **沒量的**：任何叢集上的 reconcile，以及 `im-chamber` 經 sops 解密之後的套用。
- [ ] 5.2 完成時在 `jg-base#248` 回報 commit，以及驗到什麼、沒驗到什麼；由開單者驗收
