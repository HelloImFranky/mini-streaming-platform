/**
 * spike.js — Spike / Release-Day Test
 *
 * Purpose: Simulate a "release day" traffic spike hitting all major endpoints.
 * Load profile:
 *   - 0 → 500 VUs over 1 minute (ramp up)
 *   - 500 VUs sustained for 3 minutes (spike)
 *   - 500 → 0 VUs over 1 minute (ramp down)
 *
 * Traffic mix: 40% content catalog, 40% playback start, 20% user profile
 *
 * Thresholds (relaxed for spike): p95 < 500ms, error rate < 5%
 *
 * Run: k6 run load-tests/spike.js
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";

const contentErrors = new Counter("content_errors");
const playbackErrors = new Counter("playback_errors");
const userErrors = new Counter("user_errors");
const spikeErrorRate = new Rate("spike_error_rate");

export const options = {
  stages: [
    { duration: "1m", target: 500 },  // ramp up
    { duration: "3m", target: 500 },  // spike
    { duration: "1m", target: 0 },    // ramp down
  ],
  thresholds: {
    http_req_duration: ["p(95)<500"],
    http_req_failed: ["rate<0.05"],
    spike_error_rate: ["rate<0.05"],
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

  if (roll < 0.40) {
    // 40% — Browse content catalog
    const contentId = randomItem(CONTENT_IDS);
    const res = http.get(`${BASE_URL}/content/${contentId}`, {
      tags: { name: "content-get", endpoint: "content" },
    });
    const ok = check(res, {
      "content 200": (r) => r.status === 200,
    });
    if (!ok) contentErrors.add(1);
    spikeErrorRate.add(!ok);

  } else if (roll < 0.80) {
    // 40% — Start playback session
    const userId = randomItem(USER_IDS);
    const contentId = randomItem(CONTENT_IDS);
    const payload = JSON.stringify({ user_id: userId, content_id: contentId });

    const res = http.post(`${BASE_URL}/playback/start`, payload, {
      headers: { "Content-Type": "application/json" },
      tags: { name: "playback-start", endpoint: "playback" },
    });
    const ok = check(res, {
      "playback start 201": (r) => r.status === 201,
    });
    if (!ok) playbackErrors.add(1);
    spikeErrorRate.add(!ok);

  } else {
    // 20% — Fetch user profile
    const userId = randomItem(USER_IDS);
    const res = http.get(`${BASE_URL}/users/${userId}`, {
      tags: { name: "user-get", endpoint: "users" },
    });
    const ok = check(res, {
      "user get 200": (r) => r.status === 200,
    });
    if (!ok) userErrors.add(1);
    spikeErrorRate.add(!ok);
  }

  // Short think time — simulates fast user interactions during high demand
  sleep(Math.random() * 0.5);
}

export function handleSummary(data) {
  const p95 = data.metrics.http_req_duration?.values?.["p(95)"] || 0;
  const p99 = data.metrics.http_req_duration?.values?.["p(99)"] || 0;
  const errRate = data.metrics.http_req_failed?.values?.rate || 0;
  const rps = data.metrics.http_reqs?.values?.rate || 0;

  console.log("\n=== Spike Test Summary ===");
  console.log(`Peak RPS:    ${rps.toFixed(1)} req/s`);
  console.log(`p95 latency: ${p95.toFixed(2)}ms (threshold: <500ms)`);
  console.log(`p99 latency: ${p99.toFixed(2)}ms`);
  console.log(`Error rate:  ${(errRate * 100).toFixed(3)}% (threshold: <5%)`);
  console.log(`Content errors:  ${data.metrics.content_errors?.values?.count || 0}`);
  console.log(`Playback errors: ${data.metrics.playback_errors?.values?.count || 0}`);
  console.log(`User errors:     ${data.metrics.user_errors?.values?.count || 0}`);
  console.log(`Result:      ${p95 < 500 && errRate < 0.05 ? "PASS ✓" : "FAIL ✗"}`);
  return {};
}
