// Drive the shipped bearings board's card-stack state-preservation contract
// under a minimal DOM shim, asserting behavior through the real template script
// rather than by reading its source.
//
// The board's Captain's Call section deals one card at a time. When Lavish hot
// reloads the artifact (the ~300ms file-watch reload it does whenever the board
// file is rewritten), the template must return the captain to the card they were
// on instead of dealing card 1 again. It does that by stashing the active card's
// own key in a hidden input inside a [data-lavish-question] scope, which Lavish's
// own review-state replay carries across the reload, and reading it back when the
// replay lands.
//
// This harness pins the halves the template owns:
//   persist               - navigating the stack writes the active card's key
//                            into #bb-card-index and announces it with a change
//                            event, the only way Lavish's SDK samples
//                            review-state fields.
//   questionScope         - #bb-card-index's real ancestor chain (parsed from
//                            the built markup, not grepped) carries a
//                            data-lavish-question scope, the property that
//                            makes Lavish collect and replay the field at all.
//   restoreViaMessage      - the async lavish:restoreReviewState message
//                            replays that key into the deck, read back before
//                            the fallback timer below could also have fired.
//   restoreViaFallback     - with no restoreReviewState message ever
//                            delivered, the ~300ms fallback timer alone
//                            replays the key.
//   restoreAcrossRebuild   - (only when a second board file is given) the same
//                            stashed key replayed against a differently built
//                            board, proving the restore follows the card's
//                            identity rather than its old array position when
//                            a rebuild drops or reorders Captain's Call cards.
// The vendor half in between (Lavish collecting the hidden input on `change` and
// replaying it after the reload) is proven end to end against the real lavish-axi
// and a real browser in the delivery evidence; this file is the CI-runnable
// regression for the template's own logic.
//
// Usage: node board-cardstate-harness.mjs <built-board.html> <nav-clicks> [<rebuilt-board.html>]
// Prints one JSON document:
//   { persist:{ hiddenValue, card },
//     questionScope:{ dataLavishQuestion },
//     restoreViaMessage:{ setTo, card },
//     restoreViaFallback:{ setTo, card },
//     restoreAcrossRebuild:{ setTo, card } | null }
import { readFileSync } from "node:fs";

const VOID_TAGS = new Set([
  "input", "br", "hr", "meta", "link", "img", "source", "col", "area", "base", "embed", "track", "wbr",
]);

// Parses just enough of the static markup (everything before the board's data
// slot) to know, for every id, the real chain of ancestor tags/attributes it
// sits under - so #bb-card-index's [data-lavish-question] scope can be
// asserted structurally instead of by grepping the file.
function parseStaticAncestry(markup) {
  const idFrames = new Map();
  const stack = [];
  const tagRe = /<!--[\s\S]*?-->|<(\/?)([a-zA-Z][a-zA-Z0-9-]*)([^>]*)>/g;
  let m;
  while ((m = tagRe.exec(markup)) !== null) {
    if (m[2] === undefined) continue; // matched a comment
    const tag = m[2].toLowerCase();
    if (m[1] === "/") {
      for (let i = stack.length - 1; i >= 0; i--) {
        if (stack[i].tag === tag) { stack.length = i; break; }
      }
      continue;
    }
    const attrs = {};
    const attrRe = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*"([^"]*)"|([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*'([^']*)'/g;
    let am;
    while ((am = attrRe.exec(m[3] || "")) !== null) {
      if (am[1] !== undefined) attrs[am[1]] = am[2];
      else attrs[am[3]] = am[4];
    }
    if (attrs.id) {
      idFrames.set(attrs.id, { tag, attrs, ancestors: stack.map((f) => ({ tag: f.tag, attrs: f.attrs })) });
    }
    if (!m[3].trim().endsWith("/") && !VOID_TAGS.has(tag)) stack.push({ tag, attrs });
  }
  return idFrames;
}

function loadBoard(path) {
  const html = readFileSync(path, "utf8");
  const dataJson = html
    .split('<script id="bearings-data" type="application/json">')[1]
    .split("</script>")[0];
  const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
  const staticHtml = html.slice(0, html.indexOf('<script id="bearings-data"'));
  return { dataJson, script, idFrames: parseStaticAncestry(staticHtml) };
}

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this._listeners = {};
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.classList = {
      add: (c) => { if (!this.classList.contains(c)) this.className = (this.className + " " + c).trim(); },
      remove: (c) => { this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" "); },
      contains: (c) => this.className.split(/\s+/).includes(c),
      toggle: (c, on) => { if (on) this.classList.add(c); else this.classList.remove(c); },
    };
  }
  get textContent() {
    return this.children.length ? this.children.map((c) => c.textContent).join("") : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = String(v); }
  getAttribute(k) { return k in this.attributes ? this.attributes[k] : null; }
  addEventListener(type, fn) { (this._listeners[type] = this._listeners[type] || []).push(fn); }
  dispatchEvent(evt) { (this._listeners[evt.type] || []).slice().forEach((fn) => fn.call(this, evt)); return true; }
  querySelector() { return null; }
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

// Builds a connected Node graph for `id` from its parsed static ancestry, so
// .parentNode reflects the element's real position in the shipped markup.
function buildStaticNode(id, idFrames, cache) {
  if (cache.has(id)) return cache.get(id);
  const frame = idFrames.get(id);
  if (!frame) { cache.set(id, null); return null; }
  let parent = null;
  frame.ancestors.forEach((a) => {
    const n = new Node(a.tag);
    Object.keys(a.attrs).forEach((k) => n.setAttribute(k, a.attrs[k]));
    if (a.attrs.class) n.className = a.attrs.class;
    if (parent) parent.appendChild(n);
    parent = n;
  });
  const node = new Node(frame.tag);
  Object.keys(frame.attrs).forEach((k) => node.setAttribute(k, frame.attrs[k]));
  if (frame.attrs.class) node.className = frame.attrs.class;
  if ("value" in frame.attrs) node.value = frame.attrs.value;
  if (parent) parent.appendChild(node);
  cache.set(id, node);
  return node;
}

function makeGlobals(board) {
  const nodeCache = new Map();
  const byId = new Map();
  const dataNode = new Node("script");
  dataNode.textContent = board.dataJson;
  byId.set("bearings-data", dataNode);
  globalThis.document = {
    createElement: (tag) => new Node(tag),
    getElementById: (id) => {
      if (byId.has(id)) return byId.get(id);
      const node = buildStaticNode(id, board.idFrames, nodeCache) || new Node("div");
      byId.set(id, node);
      return node;
    },
    querySelector: () => new Node("div"),
  };
  const win = new Node("window");
  globalThis.window = win;
  return { doc: globalThis.document, win };
}

function run(script) { new Function(script)(); }

function afterDelay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function ancestorQuestionScope(node) {
  let n = node && node.parentNode;
  while (n) {
    if (typeof n.getAttribute === "function") {
      const v = n.getAttribute("data-lavish-question");
      if (v !== null) return v;
    }
    n = n.parentNode;
  }
  return null;
}

async function main() {
  const boardA = loadBoard(process.argv[2]);
  const navClicks = Number(process.argv[3] || 0);
  const boardBPath = process.argv[4];

  // Run 1: navigate the stack, but capture the stashed key only through a
  // change listener attached to #bb-card-index before the template runs - the
  // same way Lavish's SDK samples the field. Reading .value directly afterward
  // would pass even if the template stopped dispatching the change event.
  const g1 = makeGlobals(boardA);
  const cardIndexInput1 = g1.doc.getElementById("bb-card-index");
  let hiddenValue = null;
  cardIndexInput1.addEventListener("change", () => { hiddenValue = cardIndexInput1.value; });
  run(boardA.script);
  const nextBtn = g1.doc.getElementById("bb-stack-next");
  for (let i = 0; i < navClicks; i++) nextBtn.dispatchEvent({ type: "click" });
  const persist = {
    hiddenValue,
    card: g1.doc.getElementById("bb-stack-count").textContent,
  };
  const questionScope = { dataLavishQuestion: ancestorQuestionScope(cardIndexInput1) };

  // Run 2: a fresh document, then replay the stashed key the way Lavish's
  // review-state restore does for the async message path - set the hidden
  // input, deliver the lavish:restoreReviewState message, and read the deck
  // back before the ~300ms fallback timer below could also have restored it.
  const g2 = makeGlobals(boardA);
  run(boardA.script);
  g2.doc.getElementById("bb-card-index").value = persist.hiddenValue;
  g2.win.dispatchEvent({ type: "message", data: { type: "lavish:restoreReviewState" } });
  await afterDelay(50);
  const restoreViaMessage = {
    setTo: persist.hiddenValue,
    card: g2.doc.getElementById("bb-stack-count").textContent,
  };

  // Run 3: a fresh document again, set the stashed key but never deliver the
  // restoreReviewState message, so only the unconditional fallback timer can
  // restore it.
  const g3 = makeGlobals(boardA);
  run(boardA.script);
  g3.doc.getElementById("bb-card-index").value = persist.hiddenValue;
  await afterDelay(400);
  const restoreViaFallback = {
    setTo: persist.hiddenValue,
    card: g3.doc.getElementById("bb-stack-count").textContent,
  };

  // Run 4 (optional): replay the same stashed key against a second, separately
  // built board - the shape of a real rebuild that drops or reorders Captain's
  // Call cards - to prove the restore resolves by the card's own key rather
  // than by its old array position.
  let restoreAcrossRebuild = null;
  if (boardBPath) {
    const boardB = loadBoard(boardBPath);
    const g4 = makeGlobals(boardB);
    run(boardB.script);
    g4.doc.getElementById("bb-card-index").value = persist.hiddenValue;
    g4.win.dispatchEvent({ type: "message", data: { type: "lavish:restoreReviewState" } });
    await afterDelay(50);
    restoreAcrossRebuild = {
      setTo: persist.hiddenValue,
      card: g4.doc.getElementById("bb-stack-count").textContent,
    };
  }

  process.stdout.write(
    JSON.stringify({ persist, questionScope, restoreViaMessage, restoreViaFallback, restoreAcrossRebuild }) + "\n"
  );
}

main();
