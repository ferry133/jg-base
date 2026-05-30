# monitoring/daily-check

Daily cluster health check CronJob. Runs once per day, checks ~15 things,
emails a report via Gmail SMTP, and pings healthchecks.io for dead-man-switch
coverage (so missing email is also noticed).

## Architecture

```
                ┌─────────────────────────┐
   08:00 Taipei │ K8s CronJob (alpine)    │
   (00:00 UTC)  │  alpine + bash + msmtp  │
   ─────────────│  + kubectl + curl + jq  │
                └────────┬──────────┬─────┘
                         │          │
       Gmail SMTP STARTTLS 587      │ HTTPS GET
                         │          │
                         ▼          ▼
            jiahdadm@gmail.com   hc-ping.com/<uuid>
            ferry133@gmail.com    (3-day grace; if no ping
                                   arrives, hc emails you)
```

Per cluster:
- One CronJob runs in the cluster against itself (in-cluster `ServiceAccount`)
- Email goes to a comma-separated list (`NOTIFY_EMAIL_TO`)
- A healthchecks.io ping URL acts as the dead-man switch — its absence is itself an alert

No cross-cluster checks. Each cluster is self-contained for operability.

## What it checks (15 items)

| # | Check | FAIL condition |
|---|---|---|
| 1 | Nodes Ready | Any node not in `Ready` |
| 2 | Flux Kustomizations | Any non-`Ready=True` |
| 3 | HelmReleases | Any non-`Ready=True` |
| 4 | Pod state | Any pod not in `Running`/`Completed`/`Succeeded` |
| 5 | Pod restarts | Pods with >5 total restarts (warning) |
| 6 | PVCs | Any not `Bound` |
| 7 | Postgres backup | Last `postgres-backup-*` Job status not `Complete` (if `db` ns exists) |
| 8 | Postgres pod | Deployment `postgres` not ReadyReplicas=1 (if exists) |
| 9 | TLS certificates | Any cert <14 days from expiry (warning) |
| 10 | Warning events | >20 Warning events in last hour (warning) |
| 11 | Cloudflare tunnel pods | Any not `Running` |
| 12 | External endpoint probes | Optional; any non-2xx/3xx (if `ENDPOINTS_TO_PROBE` set) |
| 13 | NAS reachability | NFS port 2049 not reachable (if `NAS_SERVER` set) |
| 14 | Node resource pressure | CPU >80% or Memory >85% (warning) |
| 15 | Flux GitRepository sources | Any non-`Ready=True` + DiskPressure conditions |

Three severity levels:
- `❌ FAIL` — broken state needing investigation
- `⚠️ WARN` — degraded or trending toward failure
- `✅ OK` — all clear

## Email format

**Subject**: `[<cluster_name>] Daily Health Check — YYYY-MM-DD <status>`

Status tag examples:
- `✅ OK` — no issues
- `⚠️ 2 WARN` — only warnings
- `❌ 1 FAIL` — one failure
- `❌ 3 FAIL, 1 WARN` — mixed

**Body** (plain text):
```
Cluster:  <cluster_name>
Time:     2026-05-30 08:00 CST
Result:   <status>
Counts:   <N> FAIL, <N> WARN, <N> OK

=== Summary ===
  ✅ Nodes Ready
  ✅ Flux Kustomizations all Ready
  ❌ Postgres backup — Last job status: Failed, time: 2026-05-29T18:00:00Z
  ...

=== Issue Details ===
  [FAIL] Postgres backup: ...
  [WARN] Pods with >5 restarts (lifetime): ...
```

## Enable on a new cluster

Standard three-repo workflow (see top-level `CLAUDE.md`):

1. **jg-base** — already provides the extra (this directory)

2. **jg-cluster-template** — already declares the fields in `cluster.schema.cue`
   and `cluster-secrets.sops.yaml.j2`

3. **Per-user repo** (`cluster.yaml`):
   ```yaml
   extras:
     - monitoring/daily-check
     # ... other extras

   # ── monitoring/daily-check ────────────────────────────────────────────────
   daily_check_smtp_username: "you@gmail.com"
   daily_check_smtp_password: "16char-gmail-app-password"  # no spaces
   daily_check_smtp_from: "you@gmail.com"
   daily_check_notify_email_to: "you@gmail.com,backup@gmail.com"  # comma list
   daily_check_healthchecks_ping_url: "https://hc-ping.com/<uuid>"
   # Optional:
   # daily_check_endpoints: "https://app1.example.com https://app2.example.com"
   ```

4. Run `task configure --yes`, commit (per-user repo), push.

5. Manually trigger to verify (see [Operations](#operations) below).

## Secret provisioning

### Gmail App Password

1. Enable 2-Step Verification on the sending Gmail account.
2. Generate at https://myaccount.google.com/apppasswords
   - Choose **Mail** as app, name it (e.g. `k8s-daily-check`).
3. The 16-character output is displayed with spaces every 4 chars; either form
   works for Gmail SMTP, but **store without spaces** in `cluster.yaml` for
   cleanliness.
4. The password ends up in the encrypted `cluster-secrets.sops.yaml` as
   `DAILY_CHECK_SMTP_PASSWORD` → Flux substitutes it into the `daily-check-config`
   Secret → CronJob reads it as env `SMTP_PASSWORD` → script writes it into
   `/tmp/msmtp/msmtprc`.

### Healthchecks.io ping URL

1. Free tier at https://healthchecks.io (up to 20 checks per project).
2. Create one check **per cluster**:
   - Name: e.g. `jg-jiahd-daily`
   - Schedule: **Simple** → period `1 day`, grace `6 hours`
3. Copy the ping URL: `https://hc-ping.com/<uuid>`
4. Optional: configure healthchecks.io notification to email/Slack/Telegram when
   pings are missed.

The CronJob pings:
- `<url>/fail` when any FAIL detected → healthchecks.io shows as **Down**
- `<url>` (root) on full OK → healthchecks.io shows as **Up**

If neither arrives within grace, healthchecks.io itself sends a notification.

## Operations

### Manual trigger (testing)

```sh
# jg-jiahd
KUBECONFIG=~/coding/jg-jiahd/kubeconfig-sa \
  kubectl -n monitoring create job daily-check-manual-$(date +%s) \
    --from=cronjob/daily-check

# jcom
KUBECONFIG=~/coding/jcom/kubeconfig \
  kubectl -n monitoring create job daily-check-manual-$(date +%s) \
    --from=cronjob/daily-check
```

Watch:
```sh
kubectl -n monitoring get pods -l job-name=daily-check-manual-<id> -w
kubectl -n monitoring logs -l job-name=daily-check-manual-<id> --tail=80
```

A run takes ~30–60 seconds (10 s for `apk add` + tool download + ~20 s for
checks + SMTP).

### Change schedule

Edit `cronjob.yaml` `spec.schedule`. The current value `0 0 * * *` UTC =
08:00 Asia/Taipei. Common alternatives:
- Twice daily: `0 0,12 * * *` (08:00 and 20:00 Taipei)
- Every 6h: `0 */6 * * *`

The CronJob `spec.timeZone` is set to `Etc/UTC`; change if you want the cron
expression interpreted in your local TZ instead.

### Disable temporarily

Suspend without removing manifests:
```sh
kubectl -n monitoring patch cronjob daily-check --type merge -p '{"spec":{"suspend":true}}'
```

To re-enable: `"suspend":false` (or remove the field; Flux will reset on next sync).

### Remove from a cluster

In per-user `cluster.yaml`, delete `- monitoring/daily-check` from `extras:`,
run `task configure --yes`, commit, push. Flux will prune the namespace and
all resources (the `monitoring` namespace was created by this extra).

## Troubleshooting

### "exec /scripts/run-check.sh: no such file or directory"

Alpine has no `bash` by default; the script needs it. The CronJob `command`
wrapper installs bash via `apk` then `exec`s the script. If you customized the
command and dropped this, restore from `cronjob.yaml`.

### "envsubst error: variable substitution failed: bad substitution"

The `daily-check-script` ConfigMap contains shell `${VAR:-default}` patterns
that look like Flux postBuild substitution targets. The ConfigMap has the
annotation `kustomize.toolkit.fluxcd.io/substitute: disabled` which tells Flux
to skip envsubst on this resource. Don't remove that annotation.

### `.stringData.SMTP_PORT: expected string, got int`

Kustomize strips outer quotes from string-valued `stringData` fields containing
`${VAR}` placeholders. After Flux substitution, `587` parses as int.

`SMTP_PORT` is hardcoded to `"587"` in `secret.yaml` to avoid this. If you
add other numeric-looking fields, hardcode them or use a non-numeric prefix.

### Email not arriving

1. Check pod logs: look for `smtpstatus=250` (success) vs. error messages.
2. Common Gmail SMTP failures:
   - `535 5.7.8 Username and Password not accepted` — wrong App Password or
     2FA disabled. Regenerate the App Password.
   - `534 5.7.14` — Google blocked the sign-in. Check the security alert in
     the Gmail account and approve.
3. Check the receiving inbox's spam folder.
4. SPF/DKIM: Gmail SMTP signs outgoing mail; should not be filtered.

### Healthchecks.io not receiving pings

1. Verify the URL is correct in `cluster-secrets` (decrypt to check):
   ```sh
   SOPS_AGE_KEY_FILE=./age.key sops -d kubernetes/components/sops/cluster-secrets.sops.yaml | \
     grep HEALTHCHECKS
   ```
2. Check pod log — script prints `Pinged /fail`, `Ping OK`, or `Ping failed`.
3. Cluster egress firewall — `hc-ping.com` resolves to Cloudflare; the cluster
   must allow HTTPS egress to general internet.

### Pod stuck in `Pending`

PodSecurity warnings about `allowPrivilegeEscalation`, `capabilities`, and
`runAsNonRoot` are **warnings only** — they don't block scheduling. If the
namespace's `pod-security.kubernetes.io/enforce` label is `restricted`, the
pod would fail. To run with `apk add` you need root, so the namespace can't
use `restricted enforce`. Default `monitoring` namespace has no PSA label,
which inherits the cluster default (usually `baseline` or `restricted` only as
warning).

## Customization

### Add a new check

In `configmap.yaml`, inside `run-check.sh`, add a new block following the
existing pattern:

```bash
# 16. Your check name
RESULT=$(your-check-command 2>/dev/null || echo "")
if [[ -z "$RESULT" ]]; then
  record ok "Your check name"
else
  record fail "Your check name" "<details>"
  # or:  record warn "..." "..."
fi
```

The `record` function takes 3 args: severity (`ok|warn|fail`), name, detail.
It appends to both `SUMMARY` (one-line per check) and `DETAILS` (only for
warn/fail) and increments `FAIL_COUNT`/`WARN_COUNT`.

If your check needs new RBAC, extend `rbac.yaml` `ClusterRole.rules`.

If your check needs a new env var, add to:
1. `cluster.schema.cue` in `jg-cluster-template` (optional field)
2. `cluster-secrets.sops.yaml.j2` in `jg-cluster-template` (Jinja2 var)
3. `secret.yaml` in this extra (Flux substitution placeholder)
4. The script (read from env)

Per-cluster value goes into per-user `cluster.yaml` + `task configure --yes`.

### Add external endpoint probes

Set `daily_check_endpoints` in per-user `cluster.yaml`:
```yaml
daily_check_endpoints: "https://app1.example.com https://app2.example.com"
```
Space-separated. Each URL is HEAD-probed with `curl -ksI -w '%{http_code}'`,
fails on non-2xx/3xx codes.

## File layout

```
monitoring/
├── daily-check/
│   ├── README.md                  (this file)
│   ├── ks.yaml                    (inner Flux Kustomization, targetNamespace=monitoring)
│   ├── kustomization.yaml         (kustomize wrapper for ks.yaml)
│   └── app/
│       ├── kustomization.yaml     (resource list)
│       ├── namespace.yaml         (monitoring namespace)
│       ├── rbac.yaml              (SA + ClusterRole + ClusterRoleBinding)
│       ├── secret.yaml            (daily-check-config; Flux substitutes vars)
│       ├── configmap.yaml         (run-check.sh + msmtprc.template)
│       └── cronjob.yaml           (the CronJob itself)
```

## Security notes

- **Gmail App Password** is stored encrypted via SOPS in `cluster-secrets`;
  Flux decrypts in-cluster and substitutes into the `daily-check-config`
  Secret. Rotate via per-user `cluster.yaml` → `task configure` → push.
- **ServiceAccount RBAC** is read-only across the listed resource kinds.
  No write/delete verbs. The CronJob cannot modify cluster state.
- The container does `apk add` at runtime (alpine package install). This
  requires root inside the container but does not affect the host (Talos +
  unprivileged container). If you prefer no-runtime-install, build a custom
  image with bash, msmtp, kubectl, curl, jq baked in and point `image:` at it.
- `msmtp` config is written to `/tmp/msmtp/msmtprc` with mode `0600`; the
  pod is single-purpose and ephemeral, so leak surface is minimal.
- Endpoint probes use `curl -k` (skip TLS verify) since they may target
  internal hostnames with private CAs. Externally-only endpoints are still
  safe to probe; remove `-k` in the script if you need strict verification.
