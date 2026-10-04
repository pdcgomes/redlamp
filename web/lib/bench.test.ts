import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { benchConfig, Rejection, schemaErrors, submissionPath, summary, validate } from "./bench.ts";

const root = path.join(import.meta.dirname, "..", "..");
const schema = JSON.parse(readFileSync(path.join(root, "docs", "camera-bench.schema.json"), "utf8"));
/** The report the Swift tests record, with every field the format has. */
const golden = () =>
  JSON.parse(readFileSync(path.join(root, "packages", "RedlampRecipes", "Tests", "Golden", "camera-bench-report.json"), "utf8"));

function rejects(payload: unknown, message: RegExp) {
  assert.throws(
    () => validate(payload, schema),
    (error: unknown) => error instanceof Rejection && error.status === 400 && message.test(error.message),
  );
}

test("the app's report is accepted as it is", () => {
  assert.deepEqual(schemaErrors(golden(), schema), []);
  assert.equal(validate(golden(), schema).format, 1);
});

test("a report carrying anything but measurements is refused", () => {
  const withName = golden();
  withName.photos[0].fileName = "DSC00042.ARW";
  rejects(withName, /photos\/0\/fileName: isn't allowed/);
  const withGPS = golden();
  withGPS.photos[0].identity.gps = "51.5,-0.1";
  rejects(withGPS, /identity\/gps: isn't allowed/);
  const withPath = golden();
  withPath.path = "/Users/someone/Pictures";
  rejects(withPath, /path: isn't allowed/);
});

test("wrong types, values and sizes are refused", () => {
  const verdict = golden();
  verdict.photos[0].checks[0].verdict = "great";
  rejects(verdict, /verdict: isn't one of its values/);
  const orientation = golden();
  orientation.photos[0].identity.orientation = 8;
  rejects(orientation, /orientation/);
  const format = golden();
  format.format = 2;
  rejects(format, /format: isn't 1/);
  const note = golden();
  note.answers[0].note = "x".repeat(501);
  rejects(note, /note: is longer than 500/);
  const empty = golden();
  empty.photos = [];
  rejects(empty, /photos: has too few items/);
  rejects("not a report", /isn't of type object/);
});

test("the relay is off until it's set up", () => {
  const env = {
    BENCH_ENABLED: "1",
    BENCH_REPO: "pdcgomes/redlamp-bench",
    FEEDBACK_GITHUB_APP_ID: "5183547",
    FEEDBACK_GITHUB_INSTALLATION_ID: "167750072",
    FEEDBACK_GITHUB_APP_PRIVATE_KEY: "key",
  };
  assert.equal(benchConfig({ ...env, BENCH_ENABLED: "0" }), null);
  assert.equal(benchConfig({ ...env, BENCH_REPO: "not a repo" }), null);
  assert.equal(benchConfig(env)?.prefix, "");
  assert.equal(benchConfig({ ...env, VERCEL_ENV: "preview" })?.prefix, "preview/");
});

test("each submission gets its own file, by month", () => {
  const date = new Date(Date.UTC(2026, 9, 4, 12));
  assert.equal(submissionPath({ prefix: "" }, "abc", date), "submissions/2026/10/abc.json");
  assert.equal(submissionPath({ prefix: "preview/" }, "abc", date), "preview/submissions/2026/10/abc.json");
});

test("the summary the app downloads holds only what each mode still needs", () => {
  const evidence = {
    format: 1,
    modes: [
      {
        key: "Sony|ILCE-7M3|sony_arw2_load_raw|14|6024x4024",
        camera: "Sony ILCE-7M3",
        label: "14-bit compressed ARW, 6024 × 4024",
        tier: "verified",
        contributors: 3,
        photos: 12,
        needs: ["warmLight"],
        verified: true,
        problems: [{ check: "preview.cast" }],
        versions: { redlamp: ["0.2.2"] },
      },
    ],
  };
  const cut = summary(evidence);
  assert.deepEqual(Object.keys(cut.modes[0]).sort(), [
    "camera", "contributors", "key", "label", "needs", "photos", "tier", "verified",
  ]);
  assert.deepEqual(summary(null), { format: 1, modes: [] });
});
