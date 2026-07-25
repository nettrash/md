//
//  md-init.js
//  Shared rich-content renderer for md's WebView preview + print/PDF path.
//
//  Runs entirely offline from bundled assets (no network). Renders, in order:
//    1. LaTeX math  — KaTeX auto-render ($…$, $$…$$, \(…\), \[…\]).
//                     mhchem rides KaTeX (it registers \ce{}/\pu{} onto it),
//                     so chemistry is typeset by the same katex.render() calls.
//    2. Highlight   — ```lang fenced code (<code class="language-…">), via
//                     highlight.js. Diagram / math / data fences carry their
//                     own class and are skipped; a bare fence stays plain text.
//    3. Mermaid     — ```mermaid fenced blocks (<pre class="mermaid">).
//    4. Graphviz    — ```dot / ```graphviz blocks (<div class="graphviz">),
//                     via Viz.js. The layout engine comes from the block's
//                     data-engine (dot, neato, circo, …).
//    5. PlantUML    — ```plantuml / ```puml blocks (<div class="plantuml">),
//                     via the TeaVM PlantUML engine. Rendered SEQUENTIALLY —
//                     the engine keeps global state, so concurrent render()
//                     calls clobber each other.
//
//  When everything has settled it sets  <html data-md-render-complete="1">
//  and pokes the host (WKScriptMessageHandler `mdRender` on Apple, the
//  `MdRenderBridge` JS interface on Android) so the print/PDF capture knows
//  the async diagrams are done. Identical file is bundled in md / md.macOS /
//  md.Android — edit here, copy everywhere.
//
//  The heavy engines (KaTeX, highlight.js, Mermaid, Viz, PlantUML) are only
//  pulled in when the document actually uses them: the host HTML includes the
//  KaTeX / highlight.js / Mermaid / Viz scripts conditionally, and the 7 MB
//  PlantUML engine is dynamically imported here only when a .plantuml block
//  exists — so a plain document never loads any of it. This file itself is
//  tiny and always loads.
//
//  Viz.js is the same bundled asset PlantUML already uses for its own
//  Graphviz-backed layouts, so ```dot blocks add no payload at all.
//

const DARK = document.body.dataset.mdDark === '1';

function notifyComplete() {
  document.documentElement.setAttribute('data-md-render-complete', '1');
  try { window.webkit?.messageHandlers?.mdRender?.postMessage('complete'); } catch (e) {}
  try { window.MdRenderBridge?.onRenderComplete(); } catch (e) {}
}

function waitForSvg(el, timeoutMs) {
  return new Promise(resolve => {
    const start = Date.now();
    (function poll() {
      if (el.querySelector('svg')) return resolve(true);
      if (Date.now() - start > timeoutMs) return resolve(false);
      setTimeout(poll, 80);
    })();
  });
}

function renderMath() {
  if (typeof katex === 'undefined') return;
  // Render ONLY the spans the host already identified as math (.md-mathi /
  // .md-mathd). We deliberately do NOT use KaTeX auto-render's whole-body
  // delimiter scan: that would re-interpret ordinary prose (e.g. two currency
  // amounts, "$5 and $10") as a formula. The host's inline() pass owns the
  // decision of what is math; here we just typeset it.
  document.querySelectorAll('.md-mathi').forEach(function (el) {
    try { katex.render(el.textContent, el, { displayMode: false, throwOnError: false }); } catch (e) {}
  });
  document.querySelectorAll('.md-mathd').forEach(function (el) {
    try { katex.render(el.textContent, el, { displayMode: true, throwOnError: false }); } catch (e) {}
  });
}

function highlightCode() {
  if (typeof hljs === 'undefined') return;
  // Highlight ONLY the fenced blocks the host tagged with a real code language
  // (class="language-…"). Diagram / math / data fences (mermaid, dot, math,
  // csv, …) have their own handling and never carry that class, and a bare
  // fence with no language stays plain — so this touches exactly the code
  // blocks meant for it. hljs reads the language from the class name; an
  // unknown language simply leaves the block unstyled rather than throwing.
  // (Reaches preview / print / PDF / HTML export, which use this live DOM; NOT
  // EPUB, which is built from the source HTML before any script runs.)
  document.querySelectorAll('code[class^="language-"]').forEach(function (el) {
    try { hljs.highlightElement(el); } catch (e) {}
  });
}

async function renderMermaid() {
  if (typeof mermaid === 'undefined') return;
  const blocks = document.querySelectorAll('.mermaid');
  if (!blocks.length) return;
  try {
    mermaid.initialize({
      startOnLoad: false,
      theme: DARK ? 'dark' : 'default',
      securityLevel: 'strict',
    });
    await mermaid.run({ nodes: blocks });
  } catch (e) { /* mermaid annotates the block with its own error box */ }
}

async function renderGraphviz() {
  const blocks = Array.from(document.querySelectorAll('.graphviz'));
  if (!blocks.length || typeof Viz === 'undefined') return;
  // One instance renders every block on the page (it is reusable, and each
  // instance compiles the WASM afresh).
  let viz;
  try { viz = await Viz.instance(); }
  catch (e) { return; } // leave the raw source visible
  for (const el of blocks) {
    const source = el.textContent;
    try {
      // `bgcolor=transparent` drops Graphviz's opaque white backing polygon so
      // the diagram sits on the paper like every other block. Ink colours are
      // NOT set here but in CSS (see MarkdownHTML.css): a `fontname` or colour
      // passed to the engine would change the metrics it lays the graph out
      // with, and the app's typewriter face doesn't exist on every platform.
      const svg = viz.renderSVGElement(source, {
        engine: el.dataset.engine || 'dot',
        graphAttributes: { bgcolor: 'transparent' },
      });
      el.textContent = '';
      el.appendChild(svg);
    } catch (e) {
      // A syntax error throws with a message; the untouched source stays
      // on screen, matching how a failed PlantUML block behaves.
    }
  }
}

async function renderPlantuml() {
  const blocks = Array.from(document.querySelectorAll('.plantuml'));
  if (!blocks.length) return;
  // Pull the 7 MB TeaVM engine in only now, and only once.
  let plantumlRender;
  try {
    ({ render: plantumlRender } = await import('./plantuml.js'));
  } catch (e) {
    return; // leave the raw source visible if the engine can't load
  }
  for (let i = 0; i < blocks.length; i++) {
    const el = blocks[i];
    if (!el.id) el.id = 'md-puml-' + i;
    const lines = el.textContent.split('\n');
    el.textContent = '';
    try {
      // Sequential — the engine keeps global state; concurrent calls clobber.
      plantumlRender(lines, el.id, { dark: DARK });
      // Graphviz-backed diagrams (class/activity/…) are slow; give them room.
      const ok = await waitForSvg(el, 20000);
      // A failed or timed-out render (no thrown error, no SVG) must not leave
      // the block blank — restore the raw source.
      if (!ok && !el.querySelector('svg')) el.textContent = lines.join('\n');
    } catch (e) {
      el.textContent = lines.join('\n'); // fall back to the raw source
    }
  }
}

async function run() {
  renderMath();
  highlightCode();
  await renderMermaid();
  await renderGraphviz();
  await renderPlantuml();
  notifyComplete();
}

if (document.readyState === 'complete') {
  run();
} else {
  window.addEventListener('load', run);
}
