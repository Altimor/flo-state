// Injected into the real Flo State page: dumps shell geometry in the same
// shape as `FloStateNative --shell-snapshot --dump`.
(() => {
  const R = (el) => {
    if (!el) return null;
    const r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) return null;
    return [r.x, r.y, r.width, r.height].map((v) => Math.round(v * 100) / 100);
  };
  const txt = (el) => (el ? el.textContent.replace(/\s+/g, " ").trim() : null);
  const visible = (el) => {
    if (!el) return false;
    for (let e = el; e; e = e.parentElement) {
      const cs = getComputedStyle(e);
      if (cs.display === "none" || cs.visibility === "hidden") return false;
    }
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };
  const out = { window: [0, 0, innerWidth, innerHeight] };

  const toggle = [...document.querySelectorAll('button[aria-label="Hide sidebar"],button[aria-label="Show sidebar"]')].find(visible);
  out.sidebarToggle = R(toggle);
  const switcher = document.querySelector('button[aria-label="Switch workspace"]');
  const column = switcher && switcher.closest(".shrink-0.overflow-hidden");
  const sidebarVisible = !!column && column.getBoundingClientRect().width > 0;
  out.sidebarVisible = sidebarVisible;
  if (sidebarVisible) {
    let panel = switcher;
    while (panel && getComputedStyle(panel).borderTopWidth !== "1px") panel = panel.parentElement;
    out.sidebarPanel = R(panel);
    out.workspaceSwitcher = { rect: R(switcher), label: txt(switcher) };
    out.sections = [...document.querySelectorAll("section[aria-label] > button")].filter(visible).map((b) => ({
      label: txt(b.querySelector("span")),
      rect: R(b),
    }));
    out.rows = [...document.querySelectorAll("[data-tree-path], section[aria-label] button.group:not([aria-expanded])")]
      .filter(visible)
      .map((b) => {
        const label = b.querySelector("span.min-w-0") || b.querySelector("span:last-child");
        return {
          label: txt(label),
          rect: R(b),
          labelX: Math.round(label.getBoundingClientRect().x * 100) / 100,
          active: b.getAttribute("aria-selected") === "true",
          dir: b.getAttribute("aria-expanded") !== null,
          path: b.getAttribute("data-tree-path") || "",
        };
      })
      .filter((r, i, all) => all.findIndex((o) => o.rect && r.rect && o.rect[1] === r.rect[1]) === i)
      .sort((a, b) => a.rect[1] - b.rect[1]);
  }
  out.tabs = [...document.querySelectorAll("[data-tab-id] > div[role=button]")].map((t) => ({
    title: txt(t.querySelector("span.truncate")),
    rect: R(t),
    active: t.className.includes("bg-[var(--tab-active-bg)] text-"),
  }));
  out.newTabButton = R(document.querySelector('button[aria-label="New tab"]'));
  const footer = document.querySelector("[data-document-footer]");
  out.footer = footer ? { rect: R(footer), text: txt(footer) } : null;
  const ticks = [...document.querySelectorAll(".section-rail-tick")];
  out.railTicks = ticks.map((t) => ({ rect: R(t), title: t.getAttribute("title"), active: t.style.opacity === "1" }));
  const pal = document.querySelector("[cmdk-dialog]");
  if (pal && visible(pal)) {
    out.palette = {
      rect: R(pal),
      input: R(pal.querySelector("[cmdk-input]")),
      placeholder: pal.querySelector("[cmdk-input]").getAttribute("placeholder"),
      heading: txt(pal.querySelector("[cmdk-group-heading]")),
      items: [...pal.querySelectorAll("[cmdk-item]")].map((i) => ({
        text: txt(i),
        rect: R(i),
        selected: i.getAttribute("data-selected") === "true",
      })),
      empty: txt(pal.querySelector("[cmdk-empty]")),
    };
  }
  const launcher = [...document.querySelectorAll("button")].filter((b) => /^(Create new note|Search)⌘/.test(txt(b)) && visible(b));
  if (launcher.length) out.launcher = launcher.map((b) => ({ text: txt(b), rect: R(b) }));
  const settings = document.querySelector("[data-settings-panel]");
  if (settings && visible(settings)) {
    out.settings = {
      title: R(settings.querySelector("h1")),
      sections: [...settings.querySelectorAll("h2")].map((h) => ({ label: txt(h), rect: R(h), card: R(h.nextElementSibling) })),
      rows: [...settings.querySelectorAll("section > div > div")].slice(0, 12).map((r) => ({
        label: txt(r.querySelector(".font-medium")),
        rect: R(r),
      })),
    };
  }
  const cm = [...document.querySelectorAll(".cm-content")].find((e) => visible(e) && e.cmTile);
  if (cm && cm.cmTile) {
    const v = cm.cmTile.view;
    // top of the 3rd line's block (the first line's padding is special-cased natively)
    const pos = v.state.doc.lines >= 3 ? v.state.doc.line(3).from : 0;
    const top = v.documentTop + v.lineBlockAt(pos).top;
    out.editorProbe = [0, top].map((x) => Math.round(x * 100) / 100);
  }
  const fm = document.querySelector("[data-pane]:not(.invisible) [data-frontmatter]");
  out.frontmatter = fm
    ? {
        rows: [...fm.querySelectorAll(".group")].map((r) => ({
          rect: R(r),
          key: r.querySelector("[data-field=key]").value,
          value: r.querySelector("[data-field=value]").value,
        })),
        add: R([...fm.querySelectorAll("button")].find((b) => /Add property/.test(b.textContent))),
      }
    : null;
  out.title = document.title;
  return out;
})();
