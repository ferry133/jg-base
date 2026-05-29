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
  base/     ← installed on every cluster (cert-manager, kube-system, network, flux-system, storage ns)
  extras/   ← optional per-user selection (claude-code, trello-notifier, storage/nfs-subdir, ...)
```

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

---

*Flux GitOps structure and cluster network addresses: see `.claude/rules/flux-network.md` (auto-loaded when editing `kubernetes/`).*
*Claude Code docker app details: see `.claude/rules/claude-app.md` (auto-loaded when editing `docker/`).*
