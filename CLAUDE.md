# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

**`ferry133/jg-base`** — shared base repo for ~20 Kubernetes home-ops clusters managed by ferry133.
All deployments are operated by ferry133; end users only specify requirements.

**Architecture:**
- This repo (`jg-base`, public) — common system manifests, watched by all user clusters via Flux
- Per-user repo (private) — only `cluster-secrets.sops.yaml` + Kustomizations that reference this repo
- `ferry133/jg-jiahd` — ferry133's own primary cluster (jiahd.cc); per-user repo like other user clusters but ferry133-operated

> **修正原則：`jg-base` 與 `jg-cluster-template` 才是主要的 manifest sources。**
> 任何 bug fix 或功能變更都應套用回這兩個 repo，而非只改 per-user repo（如 jgu2）。
> Per-user repo 只存放 `cluster-secrets.sops.yaml`（per-cluster 機密）與 `ks.yaml`（extras 選擇），不應包含 manifest 邏輯。

## ⚠️ 在此 repo 新增 Extra App 時，必須同步更新另外兩個 repo

**此 repo（jg-base）異動**：`kubernetes/apps/extras/<ns>/<app>/` 新增 manifests

**`jg-cluster-template` 必須同步**（否則新叢集無法使用此 app）：
- `.taskfiles/template/resources/cluster.schema.cue` → 加 optional 欄位
- `templates/config/kubernetes/components/sops/cluster-secrets.sops.yaml.j2` → 加 `VAR_NAME` 行
- `cluster.sample.yaml` → 加 extras 說明 + config 範例

**各 User Repo（jgu4 等）最後**：`cluster.yaml` 填值 → `task configure --yes` → commit & push

完整 checklist 見 `jg-cluster-template/CLAUDE.md`。

**Two-layer variable strategy:**
- *Values* (IPs, domain, passwords) → Flux `${VARIABLE}` substituted at runtime from `cluster-secrets`
- *Structure* (which extras, how many instances) → ferry133 renders via `task configure`, commits to per-user repo

**Planned directory structure** (restructuring in progress):
```
kubernetes/apps/
  base/     ← installed on every cluster (cert-manager, kube-system, network, flux-system,
              storage, claudecode, monitoring)
  extras/   ← optional per-user selection (trello-notifier, freepbx, omni, ...)
```

**`base/claudecode/claude-code` is a base app** — every cluster ships one Claude Code
web terminal at `im.<domain>` (jg-jiahd pins its own to `cc.jiahd.cc` — the reference
deployment — via an explicit `claude_instances: ["cc"]`),
so ferry133 always has a remote support path into the cluster that does not depend on
Omni/SideroLink. Shared pieces (namespace, `cluster-admin` SA, OCIRepository, secrets)
live here in `jg-base`; the per-instance HelmReleases are still rendered into the
per-user repo from `claude_instances` (default `["im"]`) because the instance names and
the `oauth2-proxy` / `talos-mcp` sidecars are template-time *structure*.
`extras/claudecode/postgres` stays opt-in.

**Auth0 OIDC is the default gate** in front of every instance (`claudecode_auth0`,
default true, in `jg-cluster-template`). The shared Auth0 application's
domain/client_id/client_secret come from a gitignored `auth0.json` in each cluster
directory; the oauth2-proxy cookie secret is derived from `age.key` + `cluster_name`.
Two things this costs, both real: the instance is unreachable until that cluster's
`https://<instance>.<domain>/oauth2/callback` is registered in the Auth0 application
(OIDC mode binds ttyd to loopback — there is no fallback), and the rescue path now
depends on Auth0 being up. A cluster that cannot accept that sets
`claudecode_auth0: false` and supplies `ttyd_credential`.

**`base/monitoring/daily-check` is a base app** — every cluster runs its own daily
health-check CronJob (08:00 Asia/Taipei) that emails a report via Gmail SMTP and pings
healthchecks.io as a dead-man switch. Nothing is per-cluster *structure* here, so the
whole app lives in `jg-base`; only the destination (`daily_check_*` in `cluster.yaml`)
varies. A cluster with those fields unset runs the Job and exits 0 with a "not
configured" log line rather than failing daily — see the guard at the top of
`run-check.sh` in `app/configmap.yaml`.

**`base/default/echo` is a base app** (since 2026-08-23) — one `http-https-echo` pod
publishing two names, `echo-ext.<domain>` on `envoy-external` and `echo-int.<domain>` on
`envoy-internal`. Nothing per-cluster here either, so the whole app lives in `jg-base`.
It exists to separate the two ingress paths when something is unreachable: the external
name exercises Cloudflare DNS → tunnel → external gateway, the internal one exercises
LAN address → internal gateway, and one backend serves both, so a difference between
them is a statement about the path and not about the workload. The route *keys* are what
name the HTTPRoutes (`route.ext` → `HTTPRoute/echo-ext`), so don't rename them casually.

Config is generated from Jinja2 templates in `templates/` using [makejinja](https://github.com/mirkolenz/makejinja), driven by `cluster.yaml` and `nodes.yaml`.

See @cluster.yaml and @nodes.yaml for the primary config inputs.

## Tooling

All tools via [mise](https://mise.jdx.dev/) (`.mise.toml`). Workflow automation via [Task](https://taskfile.dev/) (`Taskfile.yaml`, `.taskfiles/`). Env vars (`KUBECONFIG`, `SOPS_AGE_KEY_FILE`, `TALOSCONFIG`) are auto-set by mise.

```sh
mise trust && mise install   # first time setup
```

## Key Task Commands

```sh
task                         # list all tasks
task configure               # validate schemas → render templates → encrypt secrets → validate configs
task reconcile               # force Flux to sync git → cluster

task bootstrap:talos         # bootstrap new Talos cluster
task bootstrap:apps          # install Flux and base apps

task talos:apply-node IP=<ip>   # apply Talos config to one node
task talos:upgrade-node IP=<ip> # upgrade Talos on one node
task talos:upgrade-k8s          # upgrade Kubernetes version
task talos:reset                # wipe cluster (DESTRUCTIVE)

task template:debug          # kubectl get on common resources
task template:reset          # remove all generated dirs (DESTRUCTIVE)
```

## Template System

`task configure` pipeline:
1. **Schema validation** — `cue vet` against `.taskfiles/template/resources/*.schema.cue`
2. **Rendering** — `makejinja` reads `cluster.yaml` + `nodes.yaml` → outputs `kubernetes/`, `talos/`, `bootstrap/`
3. **Encryption** — `sops` encrypts `*.sops.*` files not yet encrypted
4. **Validation** — `kubeconform` (k8s manifests) + `talhelper validate` (Talos config)

**Non-standard Jinja2 delimiters** (to avoid YAML conflicts): `#{…}#` for variables, `#%…%#` for blocks.

## Secrets Management

[SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age). Age key at `./age.key` — local only, never committed. Rules in `.sops.yaml`:
- `talos/*.sops.yaml` — full file encrypted
- `bootstrap/*.sops.yaml` and `kubernetes/*.sops.yaml` — only `data`/`stringData` keys encrypted

Flux decrypts at runtime via `kubernetes/components/sops/` (referenced in Kustomizations).

## NAS / NFS Storage 慣例

⚠️ **掛 NAS NFS 的 pod 必須以 root 執行**(`runAsUser: 0` / `runAsGroup: 0` / `runAsNonRoot: false`)。

Synology NAS 的 NFS export 只授權給 **root (uid 0)**。非 root UID(例如 `runAsUser: 1000`)掛載後,目錄會顯示成 `d---------`(mode **000**)並 **Permission denied** —— 即使 root 看同一個目錄是 `drwxrwxrwx` (777)、資料都在。

- **成因**:不是 NFS squash(DSM squash「no mapping」也一樣)。是資料夾上的 **Synology ACL** 只授權 admin,NFSv4 server 依「請求端 UID」逐一計算有效權限。`fsGroup` / client 端 `chmod` 都繞不過(root 本來就看到 777),**只有以 uid 0 執行**才能存取。
- **慣例**:`mariadb`、`claude-code`(掛 `coding` NFS share 的 ttyd 終端機)、`postgres` + `postgres-backup` 都跑 root。新增任何掛 NAS export 的 app/pod 時務必比照,否則上線即 Permission denied。
- **案例**:`linebot`(`linebot-admin`、`customer-service-agent`)原本跑 `uid 1000`,2026-06-20 NAS 遷移後 `jia.homedesign`、`knowledge` 變 admin-only ACL → 讀不到;改跑 root 後修復(commit `ab2eb39`,fix 處留有 inline 註解)。
- **替代解**:若不想跑 root,可在 NAS 端把該共用資料夾的 ACL/權限開放給 users(對齊舊 NAS),pod 即可維持非 root。

**DB 備份**:每個 DB app(`extras/default/postgres`、`extras/claudecode/postgres`、`extras/freepbx/freepbx`)各自帶 `backup.yaml`(`pg_dump` / `mariadb-dump` CronJob),輸出到獨立的 `backup1` 共用資料夾(與 live-DB share 分開,才能單獨 ShareSync 異地)。備份 PV 用 `${NAS_SERVER}` 模板化,目的地子目錄用 `${CLUSTER_NAME}-<ns>-<db>` 命名。

---

*Flux GitOps structure and cluster network addresses: see `.claude/rules/flux-network.md` (auto-loaded when editing `kubernetes/`).*
*Claude Code docker app details: see `.claude/rules/claude-app.md` (auto-loaded when editing `docker/`).*
