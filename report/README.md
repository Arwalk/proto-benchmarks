# report/

Aggregates the per-implementation result files produced by the harnesses into a single,
self-contained HTML page plus machine-readable summaries. Python 3 standard library only.

```
python3 report/aggregate.py results/                 # -> results/report.html, summary.json, summary.csv
python3 report/aggregate.py results/ --baseline rust/prost
python3 report/aggregate.py --validate-only results/*.json
```

* `aggregate.py` validates every file against `schema/benchmark-result.schema.json` (a small
  built-in validator covering the keywords the schema uses), merges repeats of the same
  implementation (all timed rounds are pooled), and computes median / mean / stddev / min / max
  ops/s, ns/op and MB/s.
* `template.html` is the page; the summary JSON and the vendored `vendor/chart.umd.js`
  (Chart.js 4.4.7, MIT) are inlined so the report works offline from a single file.
* `results/validation.json` (from `tools/validate_outputs.py`) is picked up automatically for the
  cross-validation table.
