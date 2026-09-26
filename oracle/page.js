// Injected into the real Flo State page. Exposes window.__flo for fixture extraction.
(() => {
  const view = () => document.querySelector(".cm-content").cmTile.view;

  function langState(state) {
    for (const v of state.values) {
      if (v && v.tree && typeof v.tree.iterate === "function" && v.context) return v;
    }
    return null;
  }
  function tree(state) {
    const ls = langState(state);
    return ls ? ls.tree : null;
  }

  async function settle(maxMs = 3000) {
    const v = view();
    const t0 = performance.now();
    for (;;) {
      await new Promise((r) => requestAnimationFrame(() => r()));
      const t = tree(v.state);
      if (t && t.length >= v.state.doc.length) break;
      if (performance.now() - t0 > maxMs) break;
      await new Promise((r) => setTimeout(r, 20));
    }
    // two more frames so late decorations (foldTreeSync etc.) land
    for (let i = 0; i < 3; i++) await new Promise((r) => requestAnimationFrame(() => r()));
    await new Promise((r) => setTimeout(r, 30));
  }

  async function setDoc(text, anchor, head) {
    const v = view();
    v.focus();
    const a = anchor ?? 0;
    v.dispatch({ selection: { anchor: 0 } });
    await settle();
    v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: text } });
    await settle();
    // selection separately so selection-driven guards (heading/list) run as they would
    v.dispatch({ selection: { anchor: a, head: head ?? a } });
    await settle();
  }

  function dumpTree() {
    const v = view();
    const t = tree(v.state);
    const out = [];
    let depth = 0;
    t.iterate({
      enter(n) {
        out.push([n.name, n.from, n.to, depth]);
        depth++;
      },
      leave() {
        depth--;
      },
    });
    return out;
  }

  function sel() {
    const s = view().state.selection;
    return { main: s.mainIndex, ranges: s.ranges.map((r) => [r.anchor, r.head]) };
  }

  const STYLE_PROPS = [
    "fontFamily", "fontSize", "fontWeight", "fontStyle", "textDecorationLine",
    "color", "backgroundColor", "letterSpacing", "verticalAlign",
  ];

  // Per-character rendered ground truth for every doc position in the DOM.
  function render() {
    const v = view();
    const doc = v.state.doc.toString();
    const styles = [];
    const styleIndex = new Map();
    const chars = new Array(doc.length).fill(null); // null = not rendered (hidden/replaced/offscreen)
    const walker = document.createTreeWalker(v.contentDOM, NodeFilter.SHOW_TEXT);
    const range = document.createRange();
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      let base;
      try {
        base = v.posAtDOM(node, 0);
      } catch (e) {
        continue;
      }
      // Skip text living inside widgets (not doc text).
      const widget = node.parentElement.closest("[contenteditable=false]");
      if (widget && widget !== v.contentDOM) continue;
      const el = node.parentElement;
      const cs = getComputedStyle(el);
      const classes = [];
      let opacity = 1;
      const decos = new Set();
      for (let e = el; e && e !== v.contentDOM.parentElement; e = e.parentElement) {
        if (e !== v.contentDOM && e.className && typeof e.className === "string") classes.push(e.className);
        const ecs = getComputedStyle(e);
        opacity *= parseFloat(ecs.opacity);
        for (const d of ecs.textDecorationLine.split(" ")) if (d !== "none") decos.add(d);
      }
      const effDeco = [...decos].sort().join(" ") || "none";
      const hiddenByStyle =
        cs.display === "none" || cs.visibility === "hidden" || parseFloat(cs.fontSize) === 0 ||
        opacity === 0;
      const key = STYLE_PROPS.map((p) => cs[p]).join("|") + "|" + effDeco + "|" + opacity + "|" + classes.join(">");
      let sid = styleIndex.get(key);
      if (sid === undefined) {
        sid = styles.length;
        styleIndex.set(key, sid);
        const s = {};
        for (const p of STYLE_PROPS) s[p] = cs[p];
        s.textDecorationLine = effDeco;
        s.opacity = opacity;
        s.classes = classes;
        styles.push(s);
      }
      const text = node.nodeValue;
      for (let i = 0; i < text.length; i++) {
        const pos = base + i;
        if (pos < 0 || pos >= doc.length) continue;
        if (doc[pos] !== text[i]) continue; // decoration-inserted text
        range.setStart(node, i);
        range.setEnd(node, i + 1);
        const rects = range.getClientRects();
        const r = rects[0];
        const visible = !hiddenByStyle && r && r.width > 0.01 && r.height > 0;
        chars[pos] = [sid, visible ? 1 : 0, r ? +r.left.toFixed(1) : null, r ? +r.top.toFixed(1) : null,
          r ? +r.width.toFixed(2) : null, r ? +r.height.toFixed(1) : null];
      }
    }
    const lines = [];
    for (const lineEl of v.contentDOM.querySelectorAll(".cm-line")) {
      let from;
      try { from = v.posAtDOM(lineEl, 0); } catch (e) { continue; }
      const r = lineEl.getBoundingClientRect();
      const cs = getComputedStyle(lineEl);
      lines.push({
        from, to: v.state.doc.lineAt(from).to, cls: lineEl.className, top: +r.top.toFixed(1), height: +r.height.toFixed(1),
        left: +r.left.toFixed(1), paddingLeft: cs.paddingLeft, textIndent: cs.textIndent,
        paddingTop: cs.paddingTop, paddingBottom: cs.paddingBottom, lineHeight: cs.lineHeight,
        fontSize: cs.fontSize, style: lineEl.getAttribute("style") || "",
      });
    }
    // Widgets (bullets drawn via CSS pseudo-elements are on marks; replace-widgets here)
    const widgets = [];
    for (const w of v.contentDOM.querySelectorAll("[contenteditable=false], .cm-widgetBuffer")) {
      let pos = null;
      try { pos = v.posAtDOM(w, 0); } catch (e) {}
      const r = w.getBoundingClientRect();
      widgets.push({ pos, cls: w.className, tag: w.tagName, text: w.textContent.slice(0, 80),
        left: +r.left.toFixed(1), top: +r.top.toFixed(1), width: +r.width.toFixed(1), height: +r.height.toFixed(1) });
    }
    // Pseudo-element markers on list prefixes (bullets / checkboxes)
    const markers = [];
    for (const m of v.contentDOM.querySelectorAll(".cm-list-prefix")) {
      let pos = null;
      try { pos = v.posAtDOM(m, 0); } catch (e) {}
      const b = getComputedStyle(m, "::before");
      const r = m.getBoundingClientRect();
      markers.push({ pos, cls: m.className, content: b.content, beforeLeft: b.left, beforeWidth: b.width,
        beforeFontSize: b.fontSize, beforeColor: b.color, left: +r.left.toFixed(1), width: +r.width.toFixed(1) });
    }
    const contentRect = v.contentDOM.getBoundingClientRect();
    return { doc, sel: sel(), styles, chars, lines, widgets, markers,
      content: { left: +contentRect.left.toFixed(1), width: +contentRect.width.toFixed(1) } };
  }

  window.__flo = { view, setDoc, settle, dumpTree, sel, render,
    docText: () => view().state.doc.toString() };
})();
