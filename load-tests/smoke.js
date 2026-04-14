/**
 * smoke.js — Smoke test
 *
 * Purpose: Verify all 4 services are healthy via the API gateway.
 * Load profile: 5 VUs, 30 seconds
 * Pass criteria: p95 < 250ms, error rate < 1%
 *
 * Run: k6 run load-tests/smoke.js
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

const errorRate = new Rate("error_rate");
const gatewayLatency = new Trend("gateway_latency");

export const options = {
  vus: 5,
  duration: "30s",
  thresholds: {
    http_req_duration: ["p(95)<250"],
    http_req_failed: ["rate<0.01"],
    error_rate: ["rate<0.01"],
  },
};

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";

export default function () {
  // Test api-gateway health
  {
    const res = http.get(`${BASE_URL}/health`, { tags: { name: "gateway-health" } });
    const ok = check(res, {
      "gateway /health 200": (r) => r.status === 200,
      "gateway response has status ok": (r) => {
        try {
          return JSON.parse(r.body).status === "ok";
        } catch {
          return false;
        }
      },
    });
    errorRate.add(!ok);
    gatewayLatency.add(res.timings.duration);
  }

  // Test user-service via gateway
  {
    const res = http.get(`${BASE_URL}/users/u-001`, { tags: { name: "user-get" } });
    const ok = check(res, {
      "user-service GET /users/u-001 200": (r) => r.status === 200,
    });
    errorRate.add(!ok);
  }

  // Test content-service via gateway
  {
    const res = http.get(`${BASE_URL}/content/c-001`, { tags: { name: "content-get" } });
    const ok = check(res, {
      "content-service GET /content/c-001 200": (r) => r.status === 200,
      "content has id field": (r) => {
        try {
          return JSON.parse(r.body).id !== undefined;
        } catch {
          return false;
        }
      },
    });
    errorRate.add(!ok);
  }

  // Test playback-service via gateway
  {
    const payload = JSON.stringify({ user_id: "u-001", content_id: "c-001" });
    const res = http.post(`${BASE_URL}/playback/start`, payload, {
      headers: { "Content-Type": "application/json" },
      tags: { name: "playback-start" },
    });
    const ok = check(res, {
      "playback-service POST /playback/start 201": (r) => r.status === 201,
      "playback response has session_id": (r) => {
        try {
          return JSON.parse(r.body).session_id !== undefined;
        } catch {
          return false;
        }
      },
    });
    errorRate.add(!ok);
  }

  sleep(1);
}

export function handleSummary(data) {
  console.log("\n=== Smoke Test Summary ===");
  const p95 = data.metrics.http_req_duration?.values?.["p(95)"] || 0;
  const errRate = data.metrics.http_req_failed?.values?.rate || 0;
  console.log(`p95 latency: ${p95.toFixed(2)}ms (threshold: <250ms)`);
  console.log(`Error rate:  ${(errRate * 100).toFixed(3)}% (threshold: <1%)`);
  console.log(
    `Result:      ${p95 < 250 && errRate < 0.01 ? "PASS ✓" : "FAIL ✗"}`
  );
  return {};
}
