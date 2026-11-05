// The mask bench's review page (MSK-38): two masks of one photo, judged blind.
"use strict";

const MODES = { overlay: "Red overlay", mask: "Mask alone", darken: "Unmasked darkened", differ: "Where they differ" };
const ANSWER_KEYS = { 1: "A", 2: "B", 3: "both-right", 4: "both-wrong", 0: "cant-tell" };
const $ = (id) => document.getElementById(id);
const state = {
  session: null, a: null, b: null, order: "disagreement", kind: "all", items: [], index: 0,
  frame: null, side: "A", mode: "overlay", zoom: null, answer: null, tags: new Set(), started: 0,
};

async function json(url, body) {
  const response = await fetch(url, body ? { method: "POST", body: JSON.stringify(body) } : undefined);
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || response.statusText);
  return data;
}

function image(url) {
  return new Promise((resolve) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => resolve(null);
    img.src = url;
  });
}

function pixels(img, width, height) {
  const canvas = new OffscreenCanvas(width, height);
  const context = canvas.getContext("2d");
  context.drawImage(img, 0, 0, width, height);
  return context.getImageData(0, 0, width, height).data;
}

function coverage(img, width, height) {
  const out = new Float32Array(width * height);
  if (!img) return out;
  const data = pixels(img, width, height);
  for (let i = 0; i < out.length; i++) out[i] = data[i * 4] / 255;
  return out;
}

function maskURL(source, item, what = "mask") {
  return `/${what}/${encodeURIComponent(source)}/${item.kind}/${encodeURIComponent(item.photo)}.png`;
}

// The photo, both masks and the pixels neither source could judge, for one item.
async function loadFrame(item) {
  const sources = item.flip ? [state.b, state.a] : [state.a, state.b];
  const [photo, maskA, maskB, unknownA, unknownB] = await Promise.all([
    image(`/photo/${encodeURIComponent(item.photo)}.jpg`),
    image(maskURL(sources[0], item)), image(maskURL(sources[1], item)),
    image(maskURL(sources[0], item, "unknown")), image(maskURL(sources[1], item, "unknown")),
  ]);
  const width = photo.naturalWidth, height = photo.naturalHeight;
  const unknown = coverage(unknownA, width, height);
  const other = coverage(unknownB, width, height);
  for (let i = 0; i < unknown.length; i++) unknown[i] = Math.max(unknown[i], other[i]);
  const frame = {
    item, width, height, sources, unknown,
    photo: pixels(photo, width, height),
    cover: { A: coverage(maskA, width, height), B: coverage(maskB, width, height) },
    composites: {},
  };
  frame.hot = hotspot(frame);
  return frame;
}

// Where the two masks differ most, on a coarse grid.
function hotspot(frame) {
  const { width, height, cover } = frame;
  const columns = 24, rows = 16, sums = new Float32Array(columns * rows);
  for (let y = 0; y < height; y += 2) {
    for (let x = 0; x < width; x += 2) {
      const i = y * width + x;
      sums[Math.floor(y * rows / height) * columns + Math.floor(x * columns / width)] += Math.abs(cover.A[i] - cover.B[i]);
    }
  }
  let best = 0;
  for (let i = 1; i < sums.length; i++) if (sums[i] > sums[best]) best = i;
  return { x: ((best % columns) + 0.5) * width / columns, y: (Math.floor(best / columns) + 0.5) * height / rows };
}

function composite(frame, mode, side) {
  const key = `${mode}|${mode === "differ" ? "" : side}`;
  if (frame.composites[key]) return frame.composites[key];
  const { width, height, photo, unknown } = frame;
  const canvas = new OffscreenCanvas(width, height);
  const context = canvas.getContext("2d");
  const out = context.createImageData(width, height);
  const cover = frame.cover[side], a = frame.cover.A, b = frame.cover.B, data = out.data;
  for (let i = 0, p = 0; i < cover.length; i++, p += 4) {
    let r = photo[p], g = photo[p + 1], bl = photo[p + 2];
    if (mode === "overlay") {
      const t = cover[i] * 0.55;
      r = r + (255 - r) * t; g = g * (1 - t) + 40 * t; bl = bl * (1 - t) + 40 * t;
    } else if (mode === "mask") {
      r = g = bl = cover[i] * 255;
    } else if (mode === "darken") {
      const k = 0.15 + 0.85 * cover[i];
      r *= k; g *= k; bl *= k;
    } else {
      const onlyA = a[i] >= 0.5 && b[i] < 0.5, onlyB = b[i] >= 0.5 && a[i] < 0.5;
      const grey = 0.3 * r + 0.59 * g + 0.11 * bl;
      r = g = bl = grey * 0.6;
      if (onlyA) { r = 230; g = 60; bl = 200; }
      if (onlyB) { r = 60; g = 210; bl = 90; }
    }
    if (unknown[i] >= 0.5) { r = r * 0.5 + 64; g = g * 0.5 + 64; bl = bl * 0.5 + 64; }
    data[p] = r; data[p + 1] = g; data[p + 2] = bl; data[p + 3] = 255;
  }
  context.putImageData(out, 0, 0);
  frame.composites[key] = canvas;
  return canvas;
}

function draw() {
  const canvas = $("canvas"), frame = state.frame;
  const ratio = window.devicePixelRatio || 1;
  canvas.width = canvas.clientWidth * ratio;
  canvas.height = canvas.clientHeight * ratio;
  const context = canvas.getContext("2d");
  context.fillStyle = "#0d0d0d";
  context.fillRect(0, 0, canvas.width, canvas.height);
  if (!frame) return;
  const source = composite(frame, state.mode, state.side);
  context.imageSmoothingQuality = "high";
  if (state.zoom) {
    context.imageSmoothingEnabled = false;
    context.drawImage(source, canvas.width / 2 - state.zoom.x, canvas.height / 2 - state.zoom.y);
  } else {
    const scale = Math.min(canvas.width / frame.width, canvas.height / frame.height);
    const w = frame.width * scale, h = frame.height * scale;
    context.drawImage(source, (canvas.width - w) / 2, (canvas.height - h) / 2, w, h);
  }
  canvas.classList.toggle("zoomed", !!state.zoom);
  $("badge").textContent = state.mode === "differ" ? "A only · B only" : state.side;
}

function render() {
  const item = state.items[state.index];
  const left = state.items.length - state.index;
  $("progress").textContent = state.items.length ? `${Math.max(left, 0)} left in this queue` : "Nothing left in this queue";
  if (!item) { $("item").textContent = ""; return; }
  $("item").textContent = `${item.photo} · ${item.kind} · ${item.cell} · disagreement ${(item.disagreement * 100).toFixed(1)}%`;
  for (const button of document.querySelectorAll("#answers button")) {
    button.classList.toggle("selected", button.dataset.answer === state.answer);
  }
  const tags = $("tags");
  tags.replaceChildren(...(state.session.tags[item.kind] || []).map((tag) => {
    const button = document.createElement("button");
    button.textContent = tag;
    button.classList.toggle("selected", state.tags.has(tag));
    button.onclick = () => { state.tags.has(tag) ? state.tags.delete(tag) : state.tags.add(tag); render(); };
    return button;
  }));
  for (const button of document.querySelectorAll("#modes button")) {
    button.classList.toggle("selected", button.dataset.mode === state.mode);
  }
}

async function show(index) {
  state.index = index;
  state.answer = null; state.tags = new Set(); state.zoom = null; state.side = "A";
  $("note").value = "";
  const item = state.items[index];
  state.frame = item ? await loadFrame(item) : null;
  state.started = performance.now();
  render(); draw();
  const next = state.items[index + 1];
  if (next) loadFrame(next).then((frame) => { state.preloaded = frame; });
}

function toast(text) {
  const element = $("toast");
  element.textContent = text;
  element.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { element.hidden = true; }, 3500);
}

async function submit() {
  const item = state.items[state.index];
  if (!item || !state.answer) { toast("Pick an answer first (1, 2, 3, 4 or 0)."); return; }
  const [shownA, shownB] = state.frame.sources;
  const answer = state.answer === "A" ? (shownA === state.a ? "a" : "b")
    : state.answer === "B" ? (shownB === state.a ? "a" : "b") : state.answer;
  await json("/api/verdict", {
    photo: item.photo, kind: item.kind, a: state.a, b: state.b, shownAsA: shownA === state.a ? "a" : "b", answer,
    tags: [...state.tags], note: $("note").value, queue: state.order, seconds: (performance.now() - state.started) / 1000,
  });
  toast(`A was ${shownA}, B was ${shownB}.`);
  await advance();
}

async function advance() {
  const next = state.index + 1;
  if (state.preloaded && state.items[next] === state.preloaded.item) {
    state.index = next;
    state.frame = state.preloaded;
    state.preloaded = null;
    state.answer = null; state.tags = new Set(); state.zoom = null; state.side = "A";
    $("note").value = "";
    state.started = performance.now();
    render(); draw();
    const after = state.items[next + 1];
    if (after) loadFrame(after).then((frame) => { state.preloaded = frame; });
  } else {
    await show(next);
  }
}

async function accept() {
  const item = state.items[state.index];
  if (!item || state.mode === "differ") return;
  const source = state.frame.sources[state.side === "A" ? 0 : 1];
  await json("/api/reference", { photo: item.photo, kind: item.kind, source });
  toast(`${state.side} is now this photo's ${item.kind} reference.`);
}

async function load() {
  state.a = $("source-a").value;
  state.b = $("source-b").value;
  state.kind = $("kind").value;
  state.order = $("order").value;
  $("progress").textContent = "Scoring the pairs…";
  try {
    const queue = await json(`/api/queue?a=${encodeURIComponent(state.a)}&b=${encodeURIComponent(state.b)}` +
      `&order=${encodeURIComponent(state.order)}&kind=${state.kind}`);
    state.a = queue.a; state.b = queue.b; state.items = queue.items; state.preloaded = null;
    await show(0);
  } catch (error) {
    $("progress").textContent = error.message;
  }
}

function table(element, headers, rows) {
  const head = `<tr>${headers.map((h) => `<th>${h}</th>`).join("")}</tr>`;
  element.innerHTML = head + rows.map((row) => `<tr>${row.map((cell) =>
    `<td class="${typeof cell === "number" ? "number" : ""}">${cell}</td>`).join("")}</tr>`).join("");
}

async function showAreas(visible) {
  $("review").hidden = visible;
  $("areas").hidden = !visible;
  $("show-areas").textContent = visible ? "Back to review" : "Problem areas";
  if (!visible) { draw(); return; }
  const areas = await json("/api/areas");
  $("areas-total").textContent = `${areas.verdicts} verdicts so far.`;
  table($("areas-pairs"), ["Pair", "Kind", "Verdicts", "Better", "Both right", "Both wrong", "Can't tell"],
    areas.pairs.map((p) => [p.pair, p.kind, p.total,
      Object.entries(p.better).map(([name, n]) => `${name} ${n} (${Math.round(100 * n / p.total)}%)`).join(", ") || "none",
      p["both-right"], p["both-wrong"], p["cant-tell"]]));
  table($("areas-tags"), ["Contender", "Kind", "What's wrong", "Times"], areas.tags.map((t) => [t.contender, t.kind, t.tag, t.count]));
  table($("areas-cells"), ["Contender", "Cell", "Times worse"], areas.cells.map((t) => [t.contender, t.cell, t.worse]));
}

function options(select, values, chosen) {
  select.replaceChildren(...values.map((value) => {
    const option = document.createElement("option");
    option.value = value; option.textContent = value; option.selected = value === chosen;
    return option;
  }));
}

async function start() {
  const session = await json("/api/session");
  state.session = session;
  const contenders = [...new Set(session.sources.map((s) => s.split("@")[0]))];
  const sources = [...contenders, ...session.sources];
  options($("source-a"), sources, session.a);
  options($("source-b"), sources, session.b);
  for (const kind of session.kinds) $("kind").append(new Option(kind, kind));
  options($("order"), ["disagreement", "random", "changed", ...session.cells.map((cell) => `cell:${cell}`)], session.queue);
  $("modes").replaceChildren(...Object.entries(MODES).map(([mode, label]) => {
    const button = document.createElement("button");
    button.dataset.mode = mode; button.textContent = label;
    button.onclick = () => { state.mode = mode; render(); draw(); };
    return button;
  }));
  for (const button of document.querySelectorAll("#answers button")) {
    button.onclick = () => { state.answer = button.dataset.answer; render(); };
  }
  $("load").onclick = load;
  $("submit").onclick = submit;
  $("skip").onclick = advance;
  $("show-help").onclick = () => $("help").showModal();
  $("show-areas").onclick = () => showAreas($("areas").hidden);
  window.onresize = draw;
  const canvas = $("canvas");
  let drag = null;
  canvas.onmousedown = (event) => { if (state.zoom) drag = { x: event.clientX, y: event.clientY, moved: false }; };
  window.onmouseup = (event) => {
    if (drag && drag.moved) { drag = null; return; }
    drag = null;
    if (event.target !== canvas || !state.frame) return;
    if (state.zoom) { state.zoom = null; draw(); return; }
    const rect = canvas.getBoundingClientRect();
    const scale = Math.min(rect.width / state.frame.width, rect.height / state.frame.height);
    const x = (event.clientX - rect.left - (rect.width - state.frame.width * scale) / 2) / scale;
    const y = (event.clientY - rect.top - (rect.height - state.frame.height * scale) / 2) / scale;
    state.zoom = { x, y }; draw();
  };
  window.onmousemove = (event) => {
    if (!drag || !state.zoom) return;
    const ratio = window.devicePixelRatio || 1;
    state.zoom.x -= (event.clientX - drag.x) * ratio; state.zoom.y -= (event.clientY - drag.y) * ratio;
    drag.x = event.clientX; drag.y = event.clientY; drag.moved = true;
    draw();
  };
  document.onkeydown = (event) => {
    if (event.target === $("note")) {
      if (event.key === "Escape") $("note").blur();
      if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); submit(); }
      return;
    }
    if (event.target.tagName === "SELECT") return;
    const key = event.key;
    if (key in ANSWER_KEYS) { state.answer = ANSWER_KEYS[key]; render(); }
    else if (key === " ") { event.preventDefault(); state.side = state.side === "A" ? "B" : "A"; draw(); }
    else if (key === "Enter") { event.preventDefault(); submit(); }
    else if (key === "s" || key === "S") advance();
    else if (key === "ArrowLeft" && state.index > 0) show(state.index - 1);
    else if (key === "n" || key === "N") { event.preventDefault(); $("note").focus(); }
    else if (key === "z" || key === "Z") { state.zoom = state.zoom ? null : { ...state.frame.hot }; draw(); }
    else if (key === "m" || key === "M") {
      const modes = Object.keys(MODES); state.mode = modes[(modes.indexOf(state.mode) + 1) % modes.length]; render(); draw();
    } else if (key === "x" || key === "X") { state.mode = state.mode === "differ" ? "overlay" : "differ"; render(); draw(); }
    else if (key === "r" || key === "R") accept();
    else if (key === "?") $("help").showModal();
  };
  if (session.sources.length) await load();
}

start();
