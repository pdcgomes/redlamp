"""The mask bench's review page (MSK-38): masks from two sources, judged blind in the browser.

    mise run maskbench -- review [--a redlamp --b lightroom] [--queue disagreement] [--port 8765]

Each item is one photo and kind, shown as A and B in an order fixed per item but unrelated to the
sources; which source was which is shown only after the verdict is sent. Queues: `disagreement`
(the largest first, regions before edges), `random` (fixed per pair, so rates aren't skewed by the
ranking), `changed` (masks that moved between two runs of a contender, for `maskbench check`) and
`cell:<cell>`. Items already judged for the pair are left out.

Verdicts are appended to research/mask-eval/verdicts.jsonl, one JSON object a line: the photo, kind
and cell, both sources (`contender@run`), which was shown as A, the answer (`a`, `b`, `both-right`,
`both-wrong` or `cant-tell`, with `a` and `b` naming sources, not sides), `worse` (the sources the
tags describe), the tags, a note and the seconds it took. Accepting a mask as a photo's reference
copies it into build/mask-bench/references and appends a line to research/mask-eval/references.jsonl.
"""

import hashlib
import http.server
import json
import pathlib
import shutil
import threading
import urllib.parse
import webbrowser

import common as c
import scoring

STATIC = pathlib.Path(__file__).parent / "review"
TAGS = {
    "subject": ["wrong subject", "extra object", "missed part", "holes", "nothing found", "shadow included",
                "rough edge", "halo or haze", "hair or fur", "too soft"],
    "background": ["wrong subject", "extra object", "missed part", "holes", "nothing found", "shadow included",
                   "rough edge", "halo or haze", "hair or fur", "too soft"],
    "sky": ["sky missed", "sky between branches missed", "sky in leaves missed", "water or glass as sky",
            "buildings or snow as sky", "branches or wires as sky", "clouds left out", "no sky, but masked",
            "rough edge", "halo", "too soft"],
}
ANSWERS = ("a", "b", "both-right", "both-wrong", "cant-tell")
LOCK = threading.Lock()


def verdicts():
    if not c.VERDICTS.exists():
        return []
    return [json.loads(line) for line in c.VERDICTS.read_text().splitlines() if line.strip()]


def flip(photo, kind, a, b):
    """Whether item shows source b as A: fixed per item and pair, unrelated to the sources' names."""
    key = "|".join([photo, kind] + sorted([a, b])).encode()
    return hashlib.sha256(key).digest()[0] % 2 == 1


class Queues:
    """The scored pairs, kept once computed (and on disk, in build/mask-bench/scores)."""

    def __init__(self):
        self.scored = {}

    def rows(self, a, b):
        import maskbench

        key = (a, b)
        if key not in self.scored:
            path = c.SCORES / f"{a}__vs__{b}.json".replace("/", "-")
            if path.exists():
                rows = json.loads(path.read_text())["rows"]
            else:
                _, _, rows = maskbench.score_pair(a, b, list(c.KINDS))
                c.SCORES.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps({"candidate": a, "reference": b, "made": c.now(),
                                            "summary": scoring.summary(rows), "rows": rows}, indent=1) + "\n")
            self.scored[key] = rows
        return self.scored[key]

    def queue(self, a, b, order, kind):
        import maskbench

        rows = [r for r in self.rows(a, b) if kind in ("all", r["kind"])]
        judged = {(v["photo"], v["kind"]) for v in verdicts() if {v["a"], v["b"]} == {a, b}}
        rows = [r for r in rows if (r["photo"], r["kind"]) not in judged]
        if order == "random":
            rows.sort(key=lambda r: hashlib.sha256(f"{r['photo']}|{r['kind']}|{a}|{b}".encode()).hexdigest())
        else:
            if order == "changed":
                moved = maskbench.CHECK_MOVED
                rows = [r for r in rows if r["metrics"]["iou"] < moved["iou"]
                        or r["metrics"]["boundaryF"] < moved["boundaryF"]
                        or r["metrics"]["regionDisagreement"] > moved["regionDisagreement"]]
            elif order.startswith("cell:"):
                rows = [r for r in rows if r["cell"] == order[5:]]
            rows.sort(key=lambda r: -scoring.disagreement(r["metrics"]))
        return [{"photo": r["photo"], "kind": r["kind"], "cell": r["cell"],
                 "disagreement": round(scoring.disagreement(r["metrics"]), 4),
                 "flip": flip(r["photo"], r["kind"], a, b)} for r in rows]


def contender_of(source):
    return source.partition("@")[0]


def areas():
    """Verdicts counted by pair and kind, by contender's tags, and by cell for the worse source."""
    pairs, tags, cells = {}, {}, {}
    for v in verdicts():
        pair = " vs ".join(sorted([contender_of(v["a"]), contender_of(v["b"])]))
        key = f"{pair}|{v['kind']}"
        count = pairs.setdefault(key, {"pair": pair, "kind": v["kind"], "total": 0, "better": {}, "both-right": 0,
                                       "both-wrong": 0, "cant-tell": 0})
        count["total"] += 1
        if v["answer"] in ("a", "b"):
            better = contender_of(v[v["answer"]])
            count["better"][better] = count["better"].get(better, 0) + 1
        else:
            count[v["answer"]] += 1
        for source in v.get("worse", []):
            name = contender_of(source)
            for tag in v.get("tags", []):
                tags.setdefault(f"{name}|{v['kind']}|{tag}", {"contender": name, "kind": v["kind"], "tag": tag,
                                                              "count": 0})["count"] += 1
            cell = cells.setdefault(f"{name}|{v['cell']}", {"contender": name, "cell": v["cell"], "worse": 0})
            cell["worse"] += 1
    return {"pairs": sorted(pairs.values(), key=lambda p: (p["pair"], p["kind"])),
            "tags": sorted(tags.values(), key=lambda t: -t["count"]),
            "cells": sorted(cells.values(), key=lambda t: -t["worse"]),
            "verdicts": len(verdicts())}


def sources():
    out = []
    for contender_id, spec in c.contenders().items():
        if spec["runner"] == "lightroom":
            out += [f"lightroom@{v}" for v in c.lightroom_versions()]
        else:
            out += [f"{contender_id}@{run}" for run in c.runs_of(contender_id, checks=True)]
    return out


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "MaskBench/1"

    def log_message(self, *args):
        pass

    def send(self, body, kind="application/json", status=200):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "max-age=3600" if kind.startswith("image/") else "no-store")
        self.end_headers()
        self.wfile.write(body)

    def file(self, path, kind):
        if not path.exists():
            return self.send({"error": "not found"}, status=404)
        self.send(path.read_bytes(), kind)

    def do_GET(self):  # noqa: N802 - http.server's name
        url = urllib.parse.urlparse(self.path)
        query = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        parts = [urllib.parse.unquote(p) for p in url.path.strip("/").split("/")]
        try:
            if url.path == "/":
                return self.file(STATIC / "index.html", "text/html; charset=utf-8")
            if parts[0] == "static" and len(parts) == 2 and "/" not in parts[1]:
                kind = "text/css" if parts[1].endswith(".css") else "text/javascript"
                return self.file(STATIC / parts[1], kind)
            if parts[0] == "api" and parts[1] == "session":
                return self.send({"a": self.server.a, "b": self.server.b, "queue": self.server.order,
                                  "kinds": list(c.KINDS), "tags": TAGS, "sources": sources(),
                                  "cells": sorted({e["cell"] for e in c.pool()})})
            if parts[0] == "api" and parts[1] == "queue":
                a, b = c.resolve(query["a"])[1], c.resolve(query["b"])[1]
                return self.send({"a": a, "b": b, "items": self.server.queues.queue(
                    a, b, query.get("order", "disagreement"), query.get("kind", "all"))})
            if parts[0] == "api" and parts[1] == "areas":
                return self.send(areas())
            if parts[0] == "photo" and len(parts) == 2:
                return self.file(c.bench_jpeg(c.photo(parts[1].removesuffix(".jpg"))), "image/jpeg")
            if parts[0] in ("mask", "unknown") and len(parts) == 4:
                folder, _ = c.resolve(parts[1])
                photo_id = parts[3].removesuffix(".png")
                path = (c.mask_path if parts[0] == "mask" else c.unknown_path)(folder, parts[2], photo_id)
                return self.file(path, "image/png")
        except (KeyError, StopIteration, SystemExit) as error:
            return self.send({"error": str(error)}, status=404)
        self.send({"error": "not found"}, status=404)

    def do_POST(self):  # noqa: N802 - http.server's name
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if self.path == "/api/verdict":
            if body.get("answer") not in ANSWERS:
                return self.send({"error": "bad answer"}, status=400)
            a, b = body["a"], body["b"]
            worse = {"a": [b], "b": [a], "both-wrong": [a, b]}.get(body["answer"], [])
            entry = c.photo(body["photo"])
            line = {"at": c.now(), "photo": body["photo"], "kind": body["kind"], "cell": entry["cell"],
                    "a": a, "b": b, "shownAsA": body["shownAsA"], "answer": body["answer"], "worse": worse,
                    "tags": [t for t in body.get("tags", []) if t in TAGS.get(body["kind"], [])],
                    "note": body.get("note", "").strip(), "queue": body.get("queue"),
                    "seconds": round(float(body.get("seconds", 0)), 1)}
            with LOCK, c.VERDICTS.open("a") as file:
                file.write(json.dumps(line) + "\n")
            return self.send({"ok": True, "verdicts": len(verdicts())})
        if self.path == "/api/reference":
            folder, name = c.resolve(body["source"])
            source = c.mask_path(folder, body["kind"], body["photo"])
            target = c.REFS / body["kind"] / f"{body['photo']}.png"
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            unknown = c.unknown_path(folder, body["kind"], body["photo"])
            if unknown.exists():
                shutil.copyfile(unknown, c.unknown_path(c.REFS, body["kind"], body["photo"]))
            line = {"at": c.now(), "photo": body["photo"], "kind": body["kind"], "source": name,
                    "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
                    "local": contender_of(name) == "lightroom"}
            with LOCK, c.REFERENCES.open("a") as file:
                file.write(json.dumps(line) + "\n")
            return self.send({"ok": True})
        self.send({"error": "not found"}, status=404)


def serve(args):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.a, server.b, server.order = args.a, args.b, args.queue
    server.queues = Queues()
    url = f"http://127.0.0.1:{args.port}/"
    print(f"==> The review page: {url} (Ctrl-C to stop)")
    if not getattr(args, "no_open", False):
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
