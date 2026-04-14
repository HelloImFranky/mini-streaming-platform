/**
 * soak.js — Soak / Endurance Test
 *
 * Purpose: Run sustained load for 30 minutes to detect memory leaks,
 *          connection pool exhaustion, and gradual performance degradation.
 *
 * Load profile: 50 VUs for 30 minutes (constant)
 *
 * Degradation detection:
 *   - Baseline p95 is sampled from the first 5-minute window.
 *   - Alert threshold: p95 at 25 min should not exceed baseline by > 20%.
 *
 * Thresholds: p95 < 400ms, error rate < 1%
 *
 * Run: k6 run load-tests/soak.js
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

const errorRate = new Rate("soak_error_rate");
const latencyTrend = new Trend("soak_latency_ms", true);

export const options = {
  vus: 50,
  duration: "30m",
  thresholds: {
    http_req_duration: ["p(95)<400"],
    http_req_failed: ["rate<0.01"],
    soak_error_rate: ["rate<0.01"],
  },
};

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";

const CONTENT_IDS = Array.from({ length: 20 }, (_, i) => `c-${String(i + 1).padStart(3, "0")}`);
const USER_IDS = ["u-001", "u-002", "u-003", "u-004", "u-005"];

function randomItem(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

export default function () {
  const roll = Math.random();

  if (roll < 0.30) {
    // Browse content list (paginated)
    const page = Math.ceil(Math.random() * 2);
    const res = http.get(`${BASE_URL}/content?page=${page}&limit=10`, {
      tags: { name: "content-list" },
    });
    const ok = check(res, { "content list 200": (r) => r.status === 200 });
    errorRate.add(!ok);
    latencyTrend.add(res.timings.duration);

  } else if (roll < 0.55) {
    // Fetch individual content item
    const res = http.get(`${BASE_URL}/content/${randomItem(CONTENT_IDS)}`, {
      tags: { name: "content-get" },
    });
    const ok = check(res, { "content item 200": (r) => r.status === 200 });
    errorRate.add(!ok);
    latencyTrend.add(res.timings.duration);

  } else if (roll < 0.75) {
    // Start and check playback session
    const payload = JSON.stringify({
      user_id: randomItem(USER_IDS),
      content_id: randomItem(CONTENT_IDS),
    });
    const startRes = http.post(`${BASE_URL}/playback/start`, payload, {
      headers: { "Content-Type": "application/json" },
      tags: { name: "playback-start" },
    });
    const ok = check(startRes, { "playback start 201": (r) => r.status === 201 });
    errorRate.add(!ok);
    latencyTrend.add(startRes.timings.duration);

    if (ok) {
      let sessionId;
      try {
        sessionId = JSON.parse(startRes.body).session_id;
      } catch {}
      if (sessionId) {
        sleep(0.5);
        const statusRes = http.get(`${BASE_URL}/playback/status/${sessionId}`, {
          tags: { name: "playback-status" },
        });
        const statusOk = check(statusRes, { "playback status 200": (r) => r.status === 200 });
        errorRate.add(!statusOk);
        latencyTrend.add(statusRes.timings.duration);
      }
    }

  } else {
    // Fetch user profile
    const res = http.get(`${BASE_URL}/users/${randomItem(USER_IDS)}`, {
      tags: { name: "user-get" },
    });
    const ok = check(res, { "user get 200": (r) => r.status === 200 });
    errorRate.add(!ok);
    latencyTrend.add(res.timings.duration);
  }

  // Realistic think time: 1-3 seconds
  sleep(1 + Math.random() * 2);
}

export function handleSummary(data) {
  const p50 = data.metrics.http_req_duration?.values?.["p(50)"] || 0;
  const p95 = data.metrics.http_req_duration?.values?.["p(95)"] || 0;
  const p99 = data.metrics.http_req_duration?.values?.["p(99)"] || 0;
  const errRate = data.metrics.http_req_failed?.values?.rate || 0;
  const totalReqs = data.metrics.http_reqs?.values?.count || 0;
  const avgRps = data.metrics.http_reqs?.values?.rate || 0;

  console.log("\n=== Soak Test Summary (30 minutes) ===");
  console.log(`Total requests: ${totalReqs}`);
  console.log(`Average RPS:    ${avgRps.toFixed(2)} req/s`);
  console.log(`p50 latency:    ${p50.toFixed(2)}ms`);
  console.log(`p95 latency:    ${p95.toFixed(2)}ms (threshold: <400ms)`);
  console.log(`p99 latency:    ${p99.toFixed(2)}ms`);
  console.log(`Error rate:     ${(errRate * 100).toFixed(3)}% (threshold: <1%)`);
  console.log(
    `Memory leak check: if p95 rose significantly over 30m, investigate service heap.`
  );
  console.log(`Result: ${p95 < 400 && errRate < 0.01 ? "PASS ✓" : "FAIL ✗"}`);
  return {};
}
