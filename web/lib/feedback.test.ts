import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import { test } from "node:test";
import { assetPath, feedbackConfig, neutralized, parseNumbers, Rejection, validate, withAttachments } from "./feedback.ts";
import { appJWT, normalizeKey } from "./github-app.ts";

const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10]).toString("base64");
const diagnostics = Buffer.from(JSON.stringify({ format: "app.redlamp.feedback-diagnostics" })).toString("base64");

function report(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    report: "6F1C2A7E-0B5D-4C3B-9E2A-1D4F5A6B7C8D",
    kind: "bug",
    area: "masking.objects",
    title: "[Masking › Objects] Clicking a second object drops the first",
    body: '<!-- redlamp-feedback v1 {"kind":"bug"} -->\n![Screenshot 1](attachment:screenshot-1.jpg)\n[diagnostics.json](attachment:diagnostics.json)',
    labels: ["in-app", "bug", "component:masking"],
    attachments: [
      { name: "screenshot-1.jpg", type: "image/jpeg", data: jpeg },
      { name: "diagnostics.json", type: "application/json", data: diagnostics },
    ],
    dryRun: false,
    ...overrides,
  };
}

function rejects(payload: unknown, status: number, message: RegExp) {
  assert.throws(
    () => validate(payload),
    (error: unknown) => error instanceof Rejection && error.status === status && message.test(error.message),
  );
}

test("a report from the app passes, with its attachments decoded", () => {
  const submission = validate(report());
  assert.equal(submission.kind, "bug");
  assert.equal(submission.area, "masking.objects");
  assert.deepEqual(submission.attachments.map((file) => file.name), ["screenshot-1.jpg", "diagnostics.json"]);
  assert.equal(submission.attachments[0].data[0], 0xff);
  assert.equal(submission.dryRun, false);
});

test("a report needs an ID, a kind, a title and words", () => {
  rejects(report({ report: "nope" }), 400, /UUID/);
  rejects(report({ kind: "rant" }), 400, /kind/);
  rejects(report({ title: "  " }), 400, /title/);
  rejects(report({ body: undefined }), 400, /body/);
  rejects(report({ area: "Masking/Objects" }), 400, /feature ID/);
  rejects(null, 400, /JSON/);
});

test("only the report's own labels go through", () => {
  rejects(report({ labels: ["in-app", "bug", "tracker"] }), 400, /labels/);
  rejects(report({ labels: ["in-app", "enhancement"] }), 400, /labels/);
  rejects(report({ labels: ["in-app", "bug", "component:export"] }), 400, /labels/);
  assert.deepEqual(validate(report({ area: null, labels: ["in-app", "bug"] })).labels, ["in-app", "bug"]);
});

test("attachments are screenshots and diagnostics, within their limits", () => {
  rejects(report({ attachments: [{ name: "run.sh", type: "text/plain", data: jpeg }] }), 400, /isn't an attachment/);
  rejects(report({ attachments: [{ name: "screenshot-1.jpg", type: "image/png", data: jpeg }] }), 400, /JPEG/);
  rejects(
    report({ attachments: [{ name: "screenshot-1.jpg", type: "image/jpeg", data: Buffer.from("GIF89a").toString("base64") }] }),
    400,
    /JPEG/,
  );
  const big = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(1_600_000)]).toString("base64");
  rejects(report({ attachments: [{ name: "screenshot-1.jpg", type: "image/jpeg", data: big }] }), 413, /too large/);
  rejects(
    report({ attachments: [{ name: "diagnostics.json", type: "application/json", data: Buffer.from("[1").toString("base64") }] }),
    400,
    /JSON object/,
  );
  const five = Array.from({ length: 5 }, (_, index) => ({ name: `screenshot-${index}.jpg`, type: "image/jpeg", data: jpeg }));
  rejects(report({ attachments: five }), 413, /too many/);
  rejects(
    report({ attachments: [{ name: "screenshot-1.jpg", type: "image/jpeg", data: jpeg }, { name: "screenshot-1.jpg", type: "image/jpeg", data: jpeg }] }),
    400,
    /twice/,
  );
});

test("comments that could pass for the tracker's markers are neutralised; the report's own marker stays", () => {
  const body = validate(report({ body: '<!-- redlamp-feedback v1 {"a":1} -->\nHi <!-- tracker-id: MSK-01 --> there' })).body;
  assert.match(body, /^<!-- redlamp-feedback v1 \{/);
  assert.ok(!body.includes("<!-- tracker-id"));
  assert.equal(neutralized("<!--x-->"), "&lt;!--x-->");
});

test("attachment links point at the stored files, and missing ones say so", () => {
  const body = withAttachments("![a](attachment:screenshot-1.jpg) [d](attachment:diagnostics.json) [x](attachment:other.png)", {
    "screenshot-1.jpg": "https://raw.githubusercontent.com/o/r/main/s.jpg",
    "diagnostics.json": "https://github.com/o/r/blob/main/d.json",
  });
  assert.equal(
    body,
    "![a](https://raw.githubusercontent.com/o/r/main/s.jpg) [d](https://github.com/o/r/blob/main/d.json) [x](#not-attached)",
  );
});

test("attachments are stored by month and report", () => {
  assert.equal(
    assetPath("6F1C2A7E-0B5D-4C3B-9E2A-1D4F5A6B7C8D", "screenshot-1.jpg", new Date(Date.UTC(2026, 9, 4))),
    "reports/2026/10/6f1c2a7e-0b5d-4c3b-9e2a-1d4f5a6b7c8d/screenshot-1.jpg",
  );
});

test("the relay is off unless it's switched on and fully set up", () => {
  const env = {
    FEEDBACK_ENABLED: "1",
    FEEDBACK_GITHUB_APP_ID: "5183547",
    FEEDBACK_GITHUB_INSTALLATION_ID: "167750072",
    FEEDBACK_GITHUB_APP_PRIVATE_KEY: "-----BEGIN PRIVATE KEY-----\\nabc\\n-----END PRIVATE KEY-----",
    FEEDBACK_REPO: "pdcgomes/redlamp",
    FEEDBACK_ASSETS_REPO: "pdcgomes/redlamp-feedback",
  };
  assert.equal(feedbackConfig(env)?.repo, "pdcgomes/redlamp");
  assert.equal(feedbackConfig({ ...env, FEEDBACK_ENABLED: "0" }), null);
  assert.equal(feedbackConfig({ ...env, FEEDBACK_REPO: "not a repo" }), null);
  assert.equal(feedbackConfig({ ...env, FEEDBACK_GITHUB_APP_ID: undefined }), null);
});

test("issue numbers for the status are bounded", () => {
  assert.deepEqual(parseNumbers("12,15"), [12, 15]);
  assert.throws(() => parseNumbers(""), Rejection);
  assert.throws(() => parseNumbers("1,x"), Rejection);
  assert.throws(() => parseNumbers(Array.from({ length: 51 }, (_, i) => i + 1).join(",")), Rejection);
});

test("the app's token is signed with its key and lasts under ten minutes", () => {
  const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const pem = privateKey.export({ type: "pkcs1", format: "pem" }).toString();
  const now = Date.UTC(2026, 9, 4, 8, 0, 0);
  const [header, payload, signature] = appJWT("5183547", pem, now).split(".");
  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url").toString()), { alg: "RS256", typ: "JWT" });
  const claims = JSON.parse(Buffer.from(payload, "base64url").toString());
  assert.equal(claims.iss, "5183547");
  assert.ok(claims.exp - claims.iat <= 600);
  assert.ok(verify("sha256", Buffer.from(`${header}.${payload}`), publicKey, Buffer.from(signature, "base64url")));
});

test("the key reads as pasted, with escaped newlines, or in base64", () => {
  const pem = "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----";
  assert.equal(normalizeKey(pem), pem);
  assert.equal(normalizeKey(pem.replace(/\n/g, "\\n")), pem);
  assert.equal(normalizeKey(Buffer.from(pem).toString("base64")), pem);
});
