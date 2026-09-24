#!/usr/bin/env bash
# Assert that no CronJob declares a history limit its TTL cannot deliver.
#
# ferry133/jg-base#143: daily-check and offsite-backup each set
# `failedJobsHistoryLimit: 3` AND a `ttlSecondsAfterFinished` shorter than
# three of their own intervals. Under a daily schedule the TTL collects each
# Job about when the next one finishes, so one survived where three were
# declared -- and **the stricter knob wins silently**. Nothing in Kubernetes,
# in this repo, or in the report said the two settings contradicted each other.
#
# ⚠️ Why that is worth a guard rather than a shrug: on a cluster with no
# `daily_check_healthchecks_ping_url` the Failed Job is the ONLY alerting
# channel (jg-jcc1 today). There the difference between "3 days of history"
# and "1 day" is the difference between a failure someone can still find and
# one that has already been collected. Declared retention that the cluster
# will not honour reads exactly like retention.
#
# The interval is RECOMPUTED from the schedule here, not taken from a comment:
# a comment that says "daily" survives an edit that makes it hourly.
#
# Usage: scripts/check-cronjob-retention.sh
#   exit 0 every declared limit is reachable, 1 one is not, 2 cannot measure
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "cannot measure: cannot enter $ROOT"; exit 2; }
command -v yq      >/dev/null 2>&1 || { echo "cannot measure: yq is missing (CI installs it)"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "cannot measure: python3 is missing"; exit 2; }

FILES="$(grep -rl 'kind: CronJob' kubernetes --include='*.yaml' 2>/dev/null || true)"
[[ -n "$FILES" ]] || { echo "cannot measure: found no CronJob manifests, so 'none contradict' would be vacuous"; exit 2; }

ROWS="$(for f in $FILES; do
  yq -r 'select(.kind == "CronJob")
         | [.metadata.name, .spec.schedule,
            (.spec.failedJobsHistoryLimit // "unset"),
            (.spec.jobTemplate.spec.ttlSecondsAfterFinished // "unset")]
         | @tsv' "$f" 2>/dev/null \
    | grep -v '^[[:space:]]*$' \
    | sed "s|^|$f\t|"    # drop the blank line yq emits per non-matching document
done)"
[[ -n "$ROWS" ]] || { echo "cannot measure: the reader returned no CronJob rows from ${FILES//$'\n'/, }"; exit 2; }

python3 - <<PY
import sys, re
from datetime import datetime, timedelta

raw = [r for r in """$ROWS""".strip().split("\n") if r.strip()]
rows = []
for r in raw:
    f = r.split("\t")
    if len(f) != 5:
        # A short row means the reader produced something this script cannot
        # interpret -- say so instead of crashing with a tuple-unpack error,
        # which reads like a bug in the manifests rather than in the harness.
        print(f"cannot measure: unreadable row from the CronJob reader: {r!r}")
        sys.exit(2)
    rows.append(f)

def field(spec, lo, hi):
    """Expand one cron field into the set of values it matches."""
    out = set()
    for part in spec.split(","):
        step = 1
        if "/" in part:
            part, s = part.split("/", 1)
            step = int(s)
        if part in ("*", "?"):
            a, b = lo, hi
        elif "-" in part:
            a, b = (int(x) for x in part.split("-", 1))
        else:
            a = b = int(part)
            if step == 1:
                out.add(a); continue
        out |= set(range(a, b + 1, step))
    return out

def min_gap_seconds(sched):
    """Smallest interval between consecutive fires, by simulation.

    Simulated rather than pattern-matched: '0 8 * * 0-5' is daily on weekdays
    and three days apart across a weekend, and no amount of staring at the
    string says which number matters. Returns None when the schedule cannot be
    parsed -- three outcomes, not two.
    """
    parts = sched.split()
    if len(parts) != 5:
        return None
    try:
        mi, ho, dm, mo, dw = (field(p, *r) for p, r in
                              zip(parts, [(0,59),(0,23),(1,31),(1,12),(0,6)]))
    except ValueError:
        return None
    t = datetime(2026, 1, 1)
    end = t + timedelta(days=40)
    fires, step = [], timedelta(minutes=1)
    while t < end:
        if (t.minute in mi and t.hour in ho and t.month in mo
                and (t.day in dm and (t.weekday() + 1) % 7 in dw)):
            fires.append(t)
        t += step
    if len(fires) < 2:
        return None
    return min((b - a).total_seconds() for a, b in zip(fires, fires[1:]))

rc = 0
checked = skipped = 0
for path, name, sched, limit, ttl in rows:
    if limit == "unset" or ttl == "unset":
        skipped += 1
        continue
    gap = min_gap_seconds(sched)
    if gap is None:
        print(f"cannot measure: could not work out the interval of '{sched}' for {name} ({path})")
        sys.exit(2)
    checked += 1
    # limit*gap, not (limit-1)*gap. The arithmetic says (N-1)*G is enough to
    # have N alive at an instant -- but at exactly that value the oldest is
    # collected as the newest finishes, and what a cluster retains is N-1.
    # Measured, not reasoned: offsite-backup ran ttl=172800 against a daily
    # schedule, which is exactly (3-1)*G, and #143 found TWO retained where
    # three were declared. The first version of this guard used the
    # arithmetic bound and passed that manifest -- the very boundary the
    # issue was opened about. When the reading and the derivation disagree,
    # the reading wins.
    need = int(limit) * gap
    if int(ttl) < need:
        rc = 1
        print(f"FAIL — {name} ({path}) declares failedJobsHistoryLimit={limit} but "
              f"ttlSecondsAfterFinished={ttl} collects each Job after {int(ttl)//3600}h, "
              f"and its schedule '{sched}' fires every {int(gap)//3600}h. Holding {limit} "
              f"needs at least {int(need)}s (limit*interval: at one interval less the "
              f"oldest is collected as the newest finishes). The stricter knob wins silently, so the "
              f"manifest promises history the cluster will not keep.")

if checked == 0:
    print(f"cannot measure: {skipped} CronJob(s) seen, none sets BOTH knobs, so nothing was compared")
    sys.exit(2)

if rc == 0:
    print(f"PASS — {checked} CronJob(s) set both knobs and every declared limit is reachable "
          f"from its own schedule; {skipped} set only one knob and cannot contradict themselves")
sys.exit(rc)
PY
