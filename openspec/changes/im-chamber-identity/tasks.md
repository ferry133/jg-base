> 全部在 `jg-base`，除非該行另寫。root：`fleet-ops/openspec/changes/agent-delegation-envelope`（tasks 第 7 組）。請求：`jg-base#248`。姊妹：k8scc `im-chamber-client`（`k8scc#70`）。
>
> **停在哪裡**：合併到 `main` 一小時內套到每一座叢集。第 1、2 組的產物在「沒有任何路徑引用 component」的前提下不改變任何 pod，照 issue→驗收→合併走。**會讓某一座現有的 im pod 改變的每一步（把 component 接上、改公鑰清單）停下來由 ferry133 點頭。** 這份檔不是授權。
>
> 每一格寫下：量到什麼、沒量到什麼。三種結果——通過／失敗／量不到。

## 1. component 與守衛（不接上任何叢集）

- [ ] 1.1 `kubernetes/apps/base/claudecode/claude-code/im/chamber/`：`kind: Component`——patch（`chamber-bridge` container、`app` 的 `CHAMBER_URL`／`CHAMBER_ACCOUNT`／`CHAMBER_SIGNERS_DIR`、三個 volume）、replacement（橋接的 tag 取自 `app`）、公鑰清單的 `configMapGenerator`（兩個空檔，`disableNameSuffixHash`）
- [ ] 1.2 `scripts/check-chamber-component.sh`：(a) `im/enabled`、`im/netdev` 的渲染與 `main` 逐位元組相同；(b) 各自加上 component 後，扣掉新增的部分等於原渲染；(c) 橋接的 tag 等於 `app` 的 tag。對照：把 component 的 patch 多改 `app` 一個既有欄位 → (b) 變紅
- [ ] 1.3 `scripts/check-chamber-credential-isolation.sh`：Secret `im-chamber` 只出現在 `chamber-bridge` 的 mount 與 env；socket 的 `emptyDir` 恰好兩個 container 掛；`chamber-bridge` 沒有 port；公鑰清單的 mount 沒有 `subPath`、唯讀。變異各一：把憑證也掛進 `app`／多一個 container 掛 socket／加一個 port／加 `subPath` → 各自變紅；每個變異先確認真的套用了
- [ ] 1.4 兩支守衛接進 `.github/workflows/flux-local.yaml`；`check-substitution-vocabulary.sh` 仍綠（新增的只有 `CLUSTER_NAME`，已在表上）
- [ ] 1.5 `claude-code/README.md`：一節說明這個 component、怎麼打開、打開要誰點頭

## 2. 在拋棄式叢集接上一次（等 k8scc 的映像裡有 `chamber-bridge`）

- [ ] 2.1 確認要用的映像 pin 含 `chamber-bridge`（k8scc tasks 3.x）；沒有就停在這裡，不接
- [ ] 2.2 事前寫下預期，再做：手寫 patch 在拋棄式叢集的 `claude-code-im` 加 `spec.components`
- [ ] 2.3 Secret 還不存在時：pod Running 且 Ready、終端機照常、橋接 container 的 log 有一行說缺什麼（design D2 的那一格）
- [ ] 2.4 Flux 的 `spec.components` 真的照 design D1 渲染（讀叢集上的 HelmRelease，不讀本機的 kustomize）；量不過就改走兩個薄目錄並記下原因
- [ ] 2.5 Secret 到位後，在 pod 裡量：`app` 的 env 與掛載裡沒有憑證（對照：`chamber-bridge` 裡有）；節點上屬於橋接程式的 TCP listener 是 0（對照：同一份清單看得到 ttyd 的 port）；socket 目錄只在兩個 container 看得到
- [ ] 2.6 拆掉 patch 後 pod 回到原樣（container 數、volume 數與接上之前相同）

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

- [ ] 5.1 `jg-cluster-template` 的 issue：打開 component 的 `cluster.yaml` 欄位（root tasks 7.4）。**合併前要 ferry133 點頭**——客戶會繼承的行為
- [ ] 5.2 完成時在 `jg-base#248` 回報 commit，以及驗到什麼、沒驗到什麼；由開單者驗收
