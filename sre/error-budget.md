# Error Budget — Mini Streaming Platform

## What is an Error Budget?

An error budget is the maximum acceptable amount of unreliability permitted by an SLO. It inverts the SLO: instead of asking "how reliable must we be?", it asks "how much can we afford to fail?"

The error budget quantifies risk tolerance as a *resource to spend* — on deployments, experiments, and risky changes — rather than a rule to never break.

---

## The Math

### Availability SLO: 99.9%

| Window       | Total minutes | Allowed downtime (0.1%) |
|-------------|--------------|------------------------|
| 30 days     | 43,200 min   | **43.2 minutes**       |
| 7 days      | 10,080 min   | **10.08 minutes**      |
| 1 day       | 1,440 min    | **1.44 minutes**       |

A 30-day error budget of **43.2 minutes** means: if all four services combined produce more than 0.1% of requests as 5xx errors in any rolling 30-day window, the SLO is violated.

### Burn Rate

Burn rate = how fast we're consuming the budget relative to the sustainable rate.

- **1× burn rate** = consuming budget at exactly the allowed pace (budget runs out at exactly 30 days)
- **5× burn rate** = consuming 5× faster → budget exhausted in 6 days
- **14.4× burn rate** = consuming 14.4× faster → budget exhausted in ~50 hours (1-hour burn window alert threshold)

The `ErrorBudgetBurn` alert fires when **both** the 1-hour and 5-minute windows show a burn rate above **5×**. This multi-window approach reduces false positives from brief spikes.

---

## The ErrorBudgetBurn Alert — How It Works

```yaml
expr: |
  (5m error rate > 5 × (1 - 0.999))   # short window: confirms current spike
  AND
  (1h error rate > 5 × (1 - 0.999))   # long window: confirms sustained trend
for: 2m
severity: critical
```

Both conditions must be true for 2 minutes:
- The 1-hour window catches sustained elevated error rates
- The 5-minute window confirms it's currently happening (not just a historical blip)
- The 2-minute `for` duration prevents single-request anomalies from paging

---

## Error Budget Policy

### Green (> 20% remaining → > 8.6 minutes left of 43.2)
- Normal operations. Deploy freely.
- Canary deployments proceed automatically via CI/CD.

### Yellow (10–20% remaining → ~4.3–8.6 minutes left)
- Increased caution. Review all non-critical deployments.
- On-call eng reviews change queue before merging.
- Run smoke tests manually before any deploy.

### Red (< 10% remaining → < 4.3 minutes left)
- **Freeze all non-critical deployments immediately.**
- Only security patches and active incident remediation may deploy.
- SRE team holds an emergency review: identify root cause of budget burn.
- Deploy-freeze lifted only after budget recovers to > 20% **and** a postmortem is filed.

### Budget Exhausted (0% remaining)
- Automatic: `ErrorBudgetBurn` alert fires → pages on-call.
- All deployments blocked via CI/CD gate check.
- Incident declared. Postmortem required within 48 hours.

---

## Tracking Budget Consumption

The Grafana dashboard panel **"Error Rate 5xx (by service)"** shows the current error rate per service. The `ErrorBudgetBurn` alert in `infra/prometheus/alerts.yaml` implements the burn rate calculation.

To calculate remaining budget manually:

```
current_error_rate = sum(rate(http_requests_total{status=~"5.."}[30d])) 
                     / sum(rate(http_requests_total[30d]))

consumed_minutes = current_error_rate × 43200  (minutes in 30d)
remaining_budget = 43.2 - consumed_minutes
remaining_pct    = remaining_budget / 43.2 × 100
```

---

## Linking to Deployments

Each deployment in CI/CD queries the Prometheus error rate before promoting a canary. If `error_rate >= 0.01` during the 5-minute canary bake window, the deployment automatically rolls back and pauses the error budget clock.

This ensures the error budget is a real forcing function, not just a metric to observe.
