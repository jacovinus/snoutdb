# Real-World Use Cases

Practical workflows showing how SnoutDB solves common data problems. Each case starts from raw files and ends with an actionable answer.

---

## 1. Diagnose a slow API

**Situation:** Users are reporting that your API is slow. You have Nginx access logs. You don't know which endpoints are the problem.

```bash
# Step 1 — import the log
./snout log-import nginx_access.log api.snout
```
```
written: api.snout
table: api
rows: 48312
columns: 8
```

```bash
# Step 2 — find the slowest endpoints at p95
./snout -f api.snout group=path -- p95=bytes p50=bytes count=rows \
  --sort p95=bytes desc \
  --limit 10
```
```
path                   p95_bytes  p50_bytes  count
---------------------  ---------  ---------  -----
/api/v1/export            982341      48291    312
/api/v1/upload            721834      24182    891
/api/v1/reports           312481       8192    421
/api/v1/data              124821       4821   2134
/api/v1/search             48291       2048   3821
/api/v1/users              24182       1024   1203
/api/v1/health              1024        512   4823
```

**What you learn:** which endpoints are delivering the largest responses to the worst 5% of requests. A high gap between `p50` and `p95` means inconsistent behavior — some requests are outliers, not average load.

```bash
# Step 3 — drill into one endpoint across HTTP methods
./snout -f api.snout group=method -- count=rows p95=bytes \
  --where path eq /api/v1/export
```
```
method  count  p95_bytes
------  -----  ---------
GET       289     821934
POST       23     982341
```

```bash
# Step 4 — check if errors spike at the same paths
./snout -f api.snout group=path -- count=rows \
  --where status ge 500 \
  --sort count=rows desc \
  --limit 10
```
```
path                   count
---------------------  -----
/api/v1/export           182
/api/v1/upload           130
/api/v1/reports           84
/api/v1/data              31
```

---

## 2. Detect anomalous traffic (bot or attack)

**Situation:** You suspect a spike in traffic from a small number of IPs. You want to know which IPs are responsible and what they're hitting.

```bash
./snout log-import access.log access.snout
```
```
written: access.snout
table: access
rows: 12847
columns: 8
```

```bash
# How many distinct IPs are hitting each endpoint?
./snout -f access.snout group=path -- count_distinct=ip count=rows \
  --sort count=rows desc \
  --limit 10
```
```
path                   count_distinct_ip  count
---------------------  -----------------  -----
/api/v1/health                      8231   4823
/api/v1/search                      3214   3821
/api/v1/data                        1821   2134
/api/v1/users                       1102   1203
/api/v1/export                        18    891
/api/v1/upload                         6    312
```

`/api/v1/export` has 891 requests but only 18 unique IPs — potential crawl.

```bash
# Which IPs sent the most requests overall?
./snout -f access.snout group=ip -- count=rows \
  --sort count=rows desc \
  --limit 10
```
```
ip               count
---------------  -----
203.0.113.42       421
198.51.100.7       312
203.0.113.18       289
10.0.0.5           314
10.0.0.12          271
...
```

```bash
# What is a suspicious IP actually requesting?
./snout -f access.snout group=path,status -- count=rows \
  --where ip eq 203.0.113.42 \
  --sort count=rows desc
```
```
path                   status  count
---------------------  ------  -----
/api/v1/export           200    389
/api/v1/export           429     32
```

**What you learn:** if one IP accounts for a large share of requests to specific paths, you have a targeted crawl or attack. `count_distinct=ip` per endpoint tells you whether traffic is organic (many IPs) or concentrated (few IPs, high count).

---

## 3. Daily access log pipeline (automated reporting)

**Situation:** You collect one log file per day. You want a weekly summary without storing all raw logs forever.

```bash
# Day 1–7: import each day as it arrives
for day in 2026-06-05 2026-06-06 2026-06-07 2026-06-08 2026-06-09 2026-06-10 2026-06-11; do
  ./snout log-import "access_${day}.log" "access_${day}.snout"
done
```
```
written: access_2026-06-05.snout  table: access  rows: 12847  columns: 8
written: access_2026-06-06.snout  table: access  rows: 13201  columns: 8
written: access_2026-06-07.snout  table: access  rows: 11983  columns: 8
written: access_2026-06-08.snout  table: access  rows: 12493  columns: 8
written: access_2026-06-09.snout  table: access  rows: 14821  columns: 8
written: access_2026-06-10.snout  table: access  rows: 13892  columns: 8
written: access_2026-06-11.snout  table: access  rows: 12341  columns: 8
```

```bash
# Build a weekly rollup — one row per (status, path) combination
./snout rollup access_2026-06-05.snout access_2026-06-06.snout \
               access_2026-06-07.snout access_2026-06-08.snout \
               access_2026-06-09.snout access_2026-06-10.snout \
               access_2026-06-11.snout \
               week_2026-w24.snout \
               group=status,path -- count=rows p95=bytes
```
```
written: week_2026-w24.snout
table: week_2026-w24
rows: 2341
columns: 4
```

```bash
# Query the summary: top error paths for the week
./snout -f week_2026-w24.snout group=path -- sum=count \
  --where status ge 500 \
  --sort sum=count desc \
  --limit 10
```
```
path                   sum_count
---------------------  ---------
/api/v1/export              1274
/api/v1/upload               910
/api/v1/reports              588
/api/v1/data                 217
```

```bash
# Export to JSON for a dashboard
./snout -f week_2026-w24.snout group=status -- sum=count \
  --sort sum=count desc \
  --format json > weekly_status_breakdown.json
```
```json
[
  {"status": "200", "sum_count": 91578},
  {"status": "404", "sum_count": 12817},
  {"status": "301", "sum_count":  6244},
  {"status": "403", "sum_count":  2947},
  {"status": "304", "sum_count":  2065},
  {"status": "500", "sum_count":  6551}
]
```

**What you get:** a compact weekly `.snout` file (~KB instead of GB of raw logs) that you can query repeatedly. The raw `.snout` day files can be archived or deleted.

---

## 4. Investigate an application error spike

**Situation:** Your error monitoring shows a spike in errors at 14:32. You have logfmt app logs with `level`, `service`, `error`, and `latency_ms` fields.

```bash
./snout log-import app.log app.snout
```
```
written: app.snout
table: app
rows: 4593
columns: 6
```

```bash
# Step 1 — which services had the highest error rate?
./snout -f app.snout group=service -- error_rate=error count=rows \
  --sort error_rate=error desc
```
```
service    error_rate_error  count
---------  ----------------  -----
payments              0.410    744
inventory             0.120    321
auth                  0.020   1187
gateway               0.010   2341
```

```bash
# Step 2 — enrich with hourly buckets to see the spike
./snout transform app.snout app_hourly.snout date_trunc=timestamp:hour
```
```
written: app_hourly.snout
table: app_hourly
rows: 4593
columns: 6
```

```bash
./snout -f app_hourly.snout group=timestamp,service -- error_rate=error count=rows \
  --sort timestamp asc
```
```
timestamp             service    error_rate_error  count
--------------------  ---------  ----------------  -----
2026-06-11T14:00:00Z  payments              0.030    821
2026-06-11T14:00:00Z  auth                  0.010   1203
2026-06-11T15:00:00Z  payments              0.410    744   ← spike
2026-06-11T15:00:00Z  auth                  0.020   1187
2026-06-11T16:00:00Z  payments              0.050    312
2026-06-11T16:00:00Z  auth                  0.010    982
```

```bash
# Step 3 — what exactly was failing at 15:00 in payments?
./snout -f app.snout group=msg -- count=rows \
  --where service eq payments \
  --where error eq true \
  --sort count=rows desc \
  --limit 10
```
```
msg                                  count
-----------------------------------  -----
connection pool exhausted              312
upstream timeout after 30s             184
database write rejected: deadlock       89
invalid auth token                      21
```

---

## 5. Analyze a CSV export from a SaaS tool

**Situation:** You exported call records from your telecom platform as a CSV. You need to find which regions have the most dropped calls and worst jitter.

```bash
# Step 1 — understand the data before writing a single query
./snout sniff -f calls.csv
```
```
column      type     role       nulls  distinct  details
----------  -------  ---------  -----  --------  ------------------------------------------
region      String   Dimension      0         6  top: us-east (89), us-west (79), eu-west (87)
carrier     String   Dimension      0         4  top: AT&T (121), Verizon (118), T-Mobile (142)
jitter_ms   Float64  Metric        12       487  min=0.5 mean=56.3 max=99.8 σ=28.4 outliers=3
roaming     Bool     Metric        22         2  true=68, false=410
result      String   Dimension      0         3  top: completed (320), failed (110), dropped (70)

suggested queries
-----------------
1. compare jitter_ms across region
   ./snout -f calls.csv group=region -- avg=jitter_ms count=rows --sort avg=jitter_ms desc
2. error rate (roaming) across region
   ./snout -f calls.csv group=region -- error_rate=roaming count=rows
```

```bash
# Step 2 — import once, query many times
./snout csv-import calls.csv calls.snout
```
```
written: calls.snout
table: calls
rows: 500
columns: 5
```

```bash
# Step 3 — dropped calls by region
./snout -f calls.snout group=region -- count=rows \
  --where result eq dropped \
  --sort count=rows desc
```
```
region    count
--------  -----
ap-south     21
us-west      18
eu-east      15
ap-north     11
us-east       3
eu-west       2
```

```bash
# Step 4 — jitter p95 per carrier, only completed calls
./snout -f calls.snout group=carrier -- p95=jitter_ms p50=jitter_ms count=rows \
  --where result eq completed \
  --sort p95=jitter_ms desc
```
```
carrier    p95_jitter_ms  p50_jitter_ms  count
---------  -------------  -------------  -----
AT&T               96.80          61.20    102
Verizon            94.10          58.40     97
Sprint             91.20          55.10     82
T-Mobile           88.40          49.30    121
```

```bash
# Step 5 — how many distinct carriers serve each region?
./snout -f calls.snout group=region -- count_distinct=carrier count=rows \
  --sort count=rows desc
```
```
region    count_distinct_carrier  count
--------  ----------------------  -----
ap-north                       3    110
eu-west                        3     87
us-east                        4     89
us-west                        4     79
eu-east                        3     64
ap-south                       2     71
```

---

## 6. Compare two CSV exports before and after a deploy

**Situation:** You took a sample of calls before a deploy (monday.csv) and after (tuesday.csv). You want to know if latency improved.

```bash
./snout csv-import monday.csv monday.snout
./snout csv-import tuesday.csv tuesday.snout
```
```
written: monday.snout   table: monday   rows: 500  columns: 5
written: tuesday.snout  table: tuesday  rows: 500  columns: 5
```

```bash
# Stats on jitter before and after (compare manually)
./snout stats monday.snout jitter_ms
```
```
column: jitter_ms
type: Float64
count: 488
nulls: 12
sum: 27431.200000
avg: 56.210000
min: 0.500000
max: 99.800000
p50: 55.400000
p95: 93.100000
p99: 98.400000
```

```bash
./snout stats tuesday.snout jitter_ms
```
```
column: jitter_ms
type: Float64
count: 491
nulls: 9
sum: 24812.100000
avg: 50.330000
min: 0.200000
max: 99.100000
p50: 49.800000
p95: 87.200000
p99: 94.100000
```

`avg` dropped from 56.2 → 50.3 ms and `p95` dropped from 93.1 → 87.2 ms — the deploy improved latency.

```bash
# p95 by region for each day
./snout -f monday.snout  group=region -- p95=jitter_ms count=rows --sort p95=jitter_ms desc
```
```
region    p95_jitter_ms  count
--------  -------------  -----
ap-south          97.10     71
us-west           93.80     79
eu-east           91.20     64
ap-north          89.40    110
eu-west           88.20     87
us-east           86.10     89
```

```bash
./snout -f tuesday.snout group=region -- p95=jitter_ms count=rows --sort p95=jitter_ms desc
```
```
region    p95_jitter_ms  count
--------  -------------  -----
ap-south          90.30     71
us-west           88.10     79
eu-east           84.20     64
ap-north          82.70    110
eu-west           79.80     87
us-east           74.10     89
```

---

## 7. Profile a JSONL event stream you've never seen before

**Situation:** A colleague hands you a `events.jsonl` file. You have no idea what's in it.

```bash
# One command to understand everything
./snout sniff -f events.jsonl
```
```
column       type       role        nulls   distinct  details
-----------  ---------  ----------  ------  --------  ------------------------------------------
event_type   String     Dimension       0        12  top: page_view (4821), click (2103), submit (891)
user_id      String     Identifier      0      9843  (high cardinality — 9843 unique values)
session_id   String     Identifier      0      3201  (high cardinality — 3201 unique values)
duration_ms  Int64      Metric        241      8821  min=1 mean=843 max=92341 σ=2147 outliers=23
timestamp    Timestamp  Timestamp       0     14821  2026-06-01T00:00:01Z → 2026-06-11T23:59:58Z

suggested queries
-----------------
1. compare duration_ms across event_type
   ./snout -f events.snout group=event_type -- avg=duration_ms count=rows
2. find outlier duration_ms values (23 detected beyond 3σ)
   ./snout -f events.snout group=event_type -- count=rows --where duration_ms gt 7284 --sort count=rows desc
```

```bash
# Follow the suggestion
./snout jsonl-import events.jsonl events.snout
```
```
written: events.snout
table: events
rows: 14821
columns: 5
```

```bash
./snout -f events.snout group=event_type -- avg=duration_ms p95=duration_ms count=rows \
  --sort p95=duration_ms desc
```
```
event_type  avg_duration_ms  p95_duration_ms  count
----------  ---------------  ---------------  -----
export              4821.00         82341.00    312
upload              2134.00         21834.00    891
submit               891.00          8921.00   2341
search               421.00          4821.00   3812
page_view            284.00          1824.00   4821
click                 48.00           412.00   2644
```

The 23 outliers in `duration_ms` (σ=2147) are worth investigating:

```bash
./snout -f events.snout group=event_type -- count=rows \
  --where duration_ms gt 10000 \
  --sort count=rows desc
```
```
event_type  count
----------  -----
export         18
upload          5
```

---

## 8. Build a weekly SLA report from multiple data sources

**Situation:** You have call records in CSV and API logs in JSONL. You need a combined SLA report: error rate and p99 latency per region, per week.

```bash
# Import each source
./snout csv-import  calls.csv       calls.snout
./snout jsonl-import api_logs.jsonl api.snout
```
```
written: calls.snout  table: calls   rows:  500  columns: 5
written: api.snout    table: api     rows: 4821  columns: 6
```

```bash
# The two files have different schemas — consolidate fills missing columns with null
./snout consolidate calls.snout api.snout combined.snout
```
```
written: combined.snout
table: combined
rows: 5321
columns: 8
```

```bash
# Build weekly rollup: error rate + p99 latency per region
./snout rollup combined.snout sla_week.snout \
  group=region -- count=rows error_rate=failed p99=latency_ms
```
```
written: sla_week.snout
table: sla_week
rows: 6
columns: 4
```

```bash
# Query the report
./snout -f sla_week.snout group=region -- \
  sum=count avg=avg_error_rate_failed avg=avg_p99_latency_ms \
  --sort avg=avg_error_rate_failed desc \
  --format json > sla_report.json
```
```json
[
  {"region": "ap-south", "sum_count": 892,  "avg_avg_error_rate_failed": 0.18, "avg_avg_p99_latency_ms": 94.10},
  {"region": "us-west",  "sum_count": 984,  "avg_avg_error_rate_failed": 0.14, "avg_avg_p99_latency_ms": 88.40},
  {"region": "eu-east",  "sum_count": 801,  "avg_avg_error_rate_failed": 0.11, "avg_avg_p99_latency_ms": 82.10},
  {"region": "ap-north", "sum_count": 1387, "avg_avg_error_rate_failed": 0.08, "avg_avg_p99_latency_ms": 79.30},
  {"region": "eu-west",  "sum_count": 1092, "avg_avg_error_rate_failed": 0.06, "avg_avg_p99_latency_ms": 74.20},
  {"region": "us-east",  "sum_count": 1114, "avg_avg_error_rate_failed": 0.04, "avg_avg_p99_latency_ms": 68.90}
]
```

---

## 9. Pipe log data from a remote server without saving locally

**Situation:** You're SSH'd into a server and want to profile logs without copying them to your machine.

```bash
# Sniff directly from stdin
ssh user@server "cat /var/log/nginx/access.log" | ./snout sniff -f -
```
```
column       type       role        nulls   distinct  details
-----------  ---------  ----------  ------  --------  --------------------------------------------------------
ip           String     Identifier      0      8231  (high cardinality — 8231 unique values)
timestamp    Timestamp  Timestamp       0     12847  2026-06-11T00:00:03Z → 2026-06-11T23:59:58Z
method       String     Dimension       0         5  top: GET (9115), POST (894), PUT (990)
path         String     Identifier      0      2341  (high cardinality — 2341 unique values)
status       Int64      Metric          0         6  min=200 mean=231 max=504 σ=82 outliers=0
bytes        Int64      Metric          0      4821  min=0 mean=3723 max=982341 σ=14821 outliers=23

suggested queries
-----------------
1. compare bytes across method
   ./snout -f access.snout group=method -- avg=bytes p95=bytes count=rows
2. compare bytes across status
   ./snout -f access.snout group=status -- avg=bytes p95=bytes count=rows
```

```bash
# Or import and query on the remote side
ssh user@server "cat /var/log/app.log" | \
  ./snout log-import - /tmp/app_tmp.snout && \
  ./snout -f /tmp/app_tmp.snout group=service -- error_rate=error count=rows
```
```
written: /tmp/app_tmp.snout
table: app_tmp
rows: 4593
columns: 6

service    error_rate_error  count
---------  ----------------  -----
payments              0.410    744
inventory             0.120    321
auth                  0.020   1187
gateway               0.010   2341
```

---

## 10. Embed SnoutDB in a Go service to analyze uploaded files

**Situation:** Your Go service receives CSV uploads and needs to return a data quality report (column types, null rates, outliers) without a database.

The v0.1.0 C ABI is experimental. It exposes table loading, schema/value
access, and grouped queries. Full sniff reports are currently produced by the
CLI.

```go
// In your HTTP handler
import "C"
// #include "snoutdb.h"
// #cgo LDFLAGS: -lsnout

func handleUpload(path string) map[string]interface{} {
    t := C.snout_import_csv(C.CString(path))
    defer C.snout_close(t)

    // Inspect the table through the C ABI.
    rows   := int(C.snout_row_count(t))
    cols   := int(C.snout_column_count(t))
    report := map[string]interface{}{"rows": rows, "columns": cols}
    return report
}
```

Run the CLI as a subprocess when you need the complete sniff report:

```go
out, _ := exec.Command("./snout", "sniff", "-f", uploadedFilePath, "--format", "json").Output()
// parse out as JSON
```

**Example JSON output from sniff --format json:**
```json
{
  "table": "upload",
  "rows": 14821,
  "columns": [
    {
      "name": "event_type",
      "type": "String",
      "role": "Dimension",
      "null_count": 0,
      "distinct_count": 12,
      "top_values": [
        {"value": "page_view", "count": 4821},
        {"value": "click",     "count": 2644}
      ]
    },
    {
      "name": "duration_ms",
      "type": "Int64",
      "role": "Metric",
      "null_count": 241,
      "distinct_count": 8821,
      "min": 1,
      "mean": 843.0,
      "max": 92341,
      "std_dev": 2147.0,
      "outlier_count": 23
    }
  ]
}
```

Full ctypes and cgo examples: [`examples/`](../examples/README.md).
