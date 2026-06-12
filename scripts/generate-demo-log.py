#!/usr/bin/env python3
"""
Generate a synthetic logfmt log file designed to make `snout hunt` look great
in screenshots.

It produces a 12-hour window with realistic noise plus three deliberate
phenomena:

  1. Steady INFO baseline that gives the timeline a calm "background".
  2. A WARN ramp between 14:00 and 15:00 (rate-limit pressure building).
  3. A tight ERROR burst around 16:32 (simulated DB outage) — the burst
     boost in Hunt will pick this up and the sparkline will spike sharply.
  4. A small CRITICAL cluster at 17:45 (post-mortem ammunition).

Templates include UUIDs, IPs, numbers, and URLs so the templatizer has
plenty to normalize. Run:

    python3 scripts/generate-demo-log.py > demo.log
    ./snout hunt demo.log --logformat logfmt --verbose
"""

import datetime
import random
import sys
import uuid


random.seed(7)

START = datetime.datetime(2026, 6, 12, 9, 0, 0)
END   = datetime.datetime(2026, 6, 12, 21, 0, 0)


def rand_uuid():
    return str(uuid.UUID(int=random.getrandbits(128)))


def rand_ip():
    return f"10.0.{random.randint(0, 200)}.{random.randint(1, 254)}"


def rand_user_id():
    return random.randint(1000, 9999)


def rand_latency():
    return random.randint(2, 300)


# ── Templates ──────────────────────────────────────────────────────────────
# Each template is a callable so we can inject variables at emission time.
# The hunt templatizer normalizes UUIDs, IPs, integers, and URLs, so the
# emitted variability collapses to a small set of clusters.

INFO_TEMPLATES = [
    lambda: f"request handled session={rand_uuid()} latency_ms={rand_latency()}",
    lambda: f"user signed in user_id={rand_user_id()} ip={rand_ip()}",
    lambda: f"cache hit key=user:{rand_user_id()}:profile",
    lambda: f"background job completed job_id={rand_uuid()} duration_ms={rand_latency()}",
    lambda: f"scheduled task fired name=cleanup pending={random.randint(0, 50)}",
    lambda: f"metric exported endpoint=https://metrics.internal/api/v2/push status=200",
]

WARN_TEMPLATES = [
    lambda: f"rate limit approaching client_id={rand_uuid()} remaining={random.randint(1, 25)}",
    lambda: f"slow query detected duration_ms={random.randint(1500, 4500)} table=orders",
    lambda: f"auth token refreshed user_id={rand_user_id()} grace_seconds={random.randint(5, 30)}",
    lambda: f"retry scheduled attempt={random.randint(2, 5)} endpoint=https://api.partner.com/v1/sync",
]

ERROR_TEMPLATES = [
    lambda: f"database connection timeout host=db-{random.randint(1, 4)}.prod after_ms={random.randint(5000, 9000)}",
    lambda: f"cache miss key=session:{rand_uuid()} downstream=true",
    lambda: f"upstream request failed url=https://payments.internal/charge code={random.choice([502, 503, 504])}",
    lambda: f"queue dead letter job_id={rand_uuid()} reason=max_retries",
]

CRITICAL_TEMPLATES = [
    lambda: f"primary db unreachable replica=db-replica-{random.randint(1, 3)} since_ms={random.randint(45000, 90000)}",
    lambda: f"disk space exhausted volume=/var/data free_mb={random.randint(0, 80)}",
]

DEBUG_TEMPLATES = [
    lambda: f"worker idle pool={random.choice(['default', 'priority'])} workers={random.randint(2, 8)}",
    lambda: f"heartbeat sent shard={random.randint(0, 7)}",
]


# ── Schedule ───────────────────────────────────────────────────────────────

def emit(events, when, level, msg):
    events.append((when, level, msg))


def add_steady(events, level, templates, every_sec, jitter_sec=0):
    t = START
    while t < END:
        msg = random.choice(templates)()
        emit(events, t, level, msg)
        delta = every_sec + random.randint(-jitter_sec, jitter_sec)
        t += datetime.timedelta(seconds=max(1, delta))


def add_window(events, level, templates, start_h, start_m, duration_min, every_sec):
    """Concentrated activity inside a fixed window."""
    base = datetime.datetime(START.year, START.month, START.day, start_h, start_m, 0)
    end_t = base + datetime.timedelta(minutes=duration_min)
    t = base
    while t < end_t:
        msg = random.choice(templates)()
        emit(events, t, level, msg)
        t += datetime.timedelta(seconds=every_sec + random.randint(-1, 2))


def main():
    events = []

    # 1. Baseline traffic.
    add_steady(events, "info",  INFO_TEMPLATES,  every_sec=18, jitter_sec=6)
    add_steady(events, "debug", DEBUG_TEMPLATES, every_sec=90, jitter_sec=20)

    # 2. WARN ramp 14:00 – 15:00 — rate-limit pressure.
    add_window(events, "warn", WARN_TEMPLATES,
               start_h=14, start_m=0, duration_min=60, every_sec=40)

    # 3. ERROR burst 16:30 – 16:45 — DB outage.
    add_window(events, "error", ERROR_TEMPLATES,
               start_h=16, start_m=30, duration_min=15, every_sec=8)

    # 4. CRITICAL cluster 17:45 – 17:50 — primary db down.
    add_window(events, "critical", CRITICAL_TEMPLATES,
               start_h=17, start_m=45, duration_min=5, every_sec=20)

    # 5. Sporadic errors throughout for histogram texture.
    for _ in range(20):
        t = START + datetime.timedelta(
            seconds=random.randint(0, int((END - START).total_seconds())))
        emit(events, t, "error", random.choice(ERROR_TEMPLATES)())

    # 6. Late-night WARN tail.
    add_window(events, "warn", WARN_TEMPLATES,
               start_h=19, start_m=30, duration_min=45, every_sec=80)

    events.sort(key=lambda e: e[0])

    out = sys.stdout
    for when, level, msg in events:
        out.write(
            f'time={when.strftime("%Y-%m-%dT%H:%M:%SZ")} '
            f'level={level} '
            f'msg="{msg}"\n'
        )


if __name__ == "__main__":
    main()
