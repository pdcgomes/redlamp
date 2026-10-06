// The history record of a kit's run, as scripts/perf-history.py append writes it, made where
// there's no Python: `osascript -l JavaScript record.js <output> <kit.json> <facts.json>
// <bench.json> [sweep perf.json] [folders perf.json] [decoder perf.json]`. kit.json has the
// commit's subject; facts.json the commit the app was built from, the Mac and the load averages.
// A missing file is left out; from the decoder run only the decode service's figures are kept.
ObjC.import("Foundation");

function read(path) {
  if (!path || !$.NSFileManager.defaultManager.fileExistsAtPath(path)) return null;
  return JSON.parse($.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js);
}

function round(value) {
  return Math.round(value * 1e4) / 1e4;
}

function run(argv) {
  const [output, kitPath, factsPath, benchPath, sweepPath, foldersPath, decoderPath] = argv;
  const kit = read(kitPath);
  const facts = read(factsPath);
  const entries = {};
  const bench = read(benchPath);
  if (bench) {
    for (const [id, entry] of Object.entries(bench.metrics)) {
      entries[id] = { value: round(entry.value), low: round(entry.low), high: round(entry.high), spread: round(entry.spread) };
    }
  }
  for (const [path, keep] of [[sweepPath, () => true], [foldersPath, () => true],
                              [decoderPath, (id) => id.startsWith("decoder-") || id === "folders-thumbs-decoder-running"]]) {
    const values = read(path);
    if (!values) continue;
    for (const [id, value] of Object.entries(values)) {
      if (keep(id)) entries[id] = { value: round(value) };
    }
  }
  if (Object.keys(entries).length === 0) throw new Error("nothing measured");
  const metrics = {};
  for (const id of Object.keys(entries).sort()) metrics[id] = entries[id];
  const record = {
    date: facts.date,
    commit: facts.commit,
    subject: kit.subject,
    dirty: false,
    source: "harness",
    machine: { chip: facts.chip, memoryGB: facts.memoryGB, macOS: facts.macOS },
    load: { before: facts.loadBefore, after: facts.loadAfter },
    noisy: Math.max(facts.loadBefore, facts.loadAfter) > 8.0,
    runs: bench ? bench.runs : null,
    metrics,
  };
  $(JSON.stringify(record) + "\n").writeToFileAtomicallyEncodingError(output, true, $.NSUTF8StringEncoding, null);
  return `${Object.keys(metrics).length} metrics at ${record.commit}${record.noisy ? ", noisy" : ""}`;
}
