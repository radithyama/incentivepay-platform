#!/usr/bin/env node
// One-time demo data seed for a fresh (or freshly re-deployed) IncentivePay
// environment. Creates a handful of participants, two incentive rules (one
// under the auto-approve threshold, one over it), and a few events - so
// every role has something real to look at on first login: a ledger with
// completed disbursements, a rules list, and a live approvals queue with
// one item still pending (the other pending item gets approved here, to
// show that flow having already happened once).
//
// Idempotent on rerun for participants/events (server-side externalRef /
// externalEventId uniqueness rejects duplicates harmlessly); rules are not
// deduped and will create a second copy if run twice - safe to ignore, or
// delete via the DB if it matters for a given demo.
//
// Usage:
//   HMAC_SECRET=... node deploy/seed-demo-data.mjs
//
// Env overrides (defaults target the live deployment):
//   API_BASE, KEYCLOAK_BASE, KEYCLOAK_REALM, KEYCLOAK_CLIENT_ID,
//   ADMIN_USER, ADMIN_PASS, APPROVER_USER, APPROVER_PASS
// HMAC_SECRET is required - see IncentivePay-Credentials.txt / .env.prod on the VM.

import crypto from "node:crypto";

const API_BASE = process.env.API_BASE ?? "https://api.incentivepay.radithyama.app";
const KEYCLOAK_BASE = process.env.KEYCLOAK_BASE ?? "https://auth.incentivepay.radithyama.app";
const REALM = process.env.KEYCLOAK_REALM ?? "incentivepay";
const CLIENT_ID = process.env.KEYCLOAK_CLIENT_ID ?? "incentivepay-client";

const HMAC_SECRET = process.env.HMAC_SECRET;
if (!HMAC_SECRET) {
  console.error("HMAC_SECRET env var is required (see IncentivePay-Credentials.txt or .env.prod on the VM).");
  process.exit(1);
}

const ADMIN_USER = process.env.ADMIN_USER ?? "admin-demo";
const ADMIN_PASS = process.env.ADMIN_PASS ?? "incentivepay-demo";
const APPROVER_USER = process.env.APPROVER_USER ?? "approver-demo";
const APPROVER_PASS = process.env.APPROVER_PASS ?? "incentivepay-demo";

async function getToken(username, password) {
  const res = await fetch(`${KEYCLOAK_BASE}/realms/${REALM}/protocol/openid-connect/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "password", client_id: CLIENT_ID, username, password }),
  });
  if (!res.ok) {
    throw new Error(`Token request for ${username} failed: ${res.status} ${await res.text()}`);
  }
  return (await res.json()).access_token;
}

// Mirrors HmacSignatureFilter's canonical form: METHOD\nPATH\nTIMESTAMP\nBODY.
function hmacSignatureHex(method, path, timestamp, body) {
  return crypto.createHmac("sha256", HMAC_SECRET).update(`${method}\n${path}\n${timestamp}\n${body}`).digest("hex");
}

async function call(token, method, path, body) {
  const bodyString = body !== undefined ? JSON.stringify(body) : "";
  const headers = { Authorization: `Bearer ${token}` };
  if (body !== undefined) headers["Content-Type"] = "application/json";

  if (["POST", "PUT", "PATCH", "DELETE"].includes(method)) {
    const timestamp = Math.floor(Date.now() / 1000).toString();
    headers["X-Timestamp"] = timestamp;
    headers["X-Signature"] = hmacSignatureHex(method, path, timestamp, bodyString);
  }

  const res = await fetch(`${API_BASE}${path}`, { method, headers, body: body !== undefined ? bodyString : undefined });
  const text = await res.text();
  const parsed = text ? JSON.parse(text) : undefined;
  return { ok: res.ok, status: res.status, body: parsed };
}

const PARTICIPANTS = [
  { externalRef: "EMP-1001", displayName: "Amara Osei", email: "amara.osei@example.com", type: "EMPLOYEE" },
  { externalRef: "EMP-1002", displayName: "Diego Fontana", email: "diego.fontana@example.com", type: "EMPLOYEE" },
  { externalRef: "PTR-2001", displayName: "Northwind Logistics", email: "ap@northwind-logistics.example.com", type: "PARTNER" },
  { externalRef: "PTR-2002", displayName: "Blue Harbor Supply", email: "billing@blueharbor.example.com", type: "PARTNER" },
];

async function main() {
  console.log(`Seeding demo data against ${API_BASE} ...`);

  const adminToken = await getToken(ADMIN_USER, ADMIN_PASS);
  const approverToken = await getToken(APPROVER_USER, APPROVER_PASS);
  console.log(`Authenticated as ${ADMIN_USER} and ${APPROVER_USER}.`);

  for (const p of PARTICIPANTS) {
    const res = await call(adminToken, "POST", "/v1/participants", p);
    console.log(res.ok ? `  + participant ${p.externalRef}` : `  - participant ${p.externalRef} skipped (${res.status}: ${res.body?.message ?? "already exists?"})`);
  }

  const effectiveFrom = "2025-01-01";
  const lowRule = await call(adminToken, "POST", "/v1/rules", {
    name: "Standard referral bonus",
    type: "FLAT",
    appliesTo: "BOTH",
    effectiveFrom,
    flatAmount: "150.00",
  });
  const highRule = await call(adminToken, "POST", "/v1/rules", {
    name: "Large partner payout",
    type: "FLAT",
    appliesTo: "BOTH",
    effectiveFrom,
    flatAmount: "750.00",
  });

  if (!lowRule.ok || !highRule.ok) {
    console.error("Failed to create rules - aborting event seeding.", lowRule.body, highRule.body);
    process.exit(1);
  }
  console.log(`  + rule "${lowRule.body.name}" (${lowRule.body.id}) - auto-approves`);
  console.log(`  + rule "${highRule.body.name}" (${highRule.body.id}) - requires approval`);

  const occurredAt = new Date().toISOString();
  const events = [
    { externalEventId: "seed-evt-auto-1", participantExternalRef: "EMP-1001", ruleId: lowRule.body.id, eventType: "referral", amount: "1", occurredAt },
    { externalEventId: "seed-evt-auto-2", participantExternalRef: "EMP-1002", ruleId: lowRule.body.id, eventType: "referral", amount: "1", occurredAt },
    { externalEventId: "seed-evt-auto-3", participantExternalRef: "PTR-2001", ruleId: lowRule.body.id, eventType: "referral", amount: "1", occurredAt },
    { externalEventId: "seed-evt-pending-1", participantExternalRef: "PTR-2002", ruleId: highRule.body.id, eventType: "quarterly-bonus", amount: "1", occurredAt },
    { externalEventId: "seed-evt-pending-2", participantExternalRef: "EMP-1001", ruleId: highRule.body.id, eventType: "quarterly-bonus", amount: "1", occurredAt },
  ];

  const created = [];
  for (const e of events) {
    const res = await call(adminToken, "POST", "/v1/events", e);
    if (res.ok) {
      console.log(`  + event ${e.externalEventId} -> disbursement ${res.body.status}`);
      created.push(res.body);
    } else {
      console.log(`  - event ${e.externalEventId} failed (${res.status}: ${res.body?.message})`);
    }
  }

  const stillPending = created.filter((d) => d.status === "PENDING_APPROVAL");
  if (stillPending.length > 0) {
    const toApprove = stillPending[0];
    const approveRes = await call(approverToken, "POST", `/v1/disbursements/${toApprove.id}/approve`, undefined);
    console.log(
      approveRes.ok
        ? `  + approved disbursement ${toApprove.id} as ${APPROVER_USER} (${stillPending.length - 1} left pending for the demo)`
        : `  - approving ${toApprove.id} failed (${approveRes.status}: ${approveRes.body?.message})`,
    );
  }

  console.log("\nDone. Log in as viewer-demo, approver-demo, financeops-demo, or admin-demo to see the seeded data.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
