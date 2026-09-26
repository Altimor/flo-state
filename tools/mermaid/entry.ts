// The web app's Mermaid widget (beautiful-mermaid render + mermaid-canvas.ts
// frame with pan/zoom/reset/Edit-code), mounted by Flo State Native in a
// WKWebView. Messages back to Swift go through webkit.messageHandlers.flo.
import { renderMermaid } from "@/components/editor-area/mermaid-renderer";
import { openMermaidFullscreen } from "@/components/editor-area/mermaid-fullscreen";
import { mountMermaidCanvas, type MermaidCanvasHandle } from "@/components/editor-area/mermaid-canvas";

declare const webkit: any;
let handle: MermaidCanvasHandle | null = null;
const post = (m: unknown) => { try { webkit.messageHandlers.flo.postMessage(m); } catch { /* snapshot mode */ } };

(window as any).floMermaid = function (body: string, fenceText: string, interactive: boolean) {
  const host = document.getElementById("host")!;
  const result = renderMermaid(body);
  const ariaLabel = `Mermaid diagram: ${body.split("\n")[0]}`;
  if (handle) { handle.updateSource(result.svg ?? "", fenceText, result.error); return; }
  handle = mountMermaidCanvas(host, {
    svgHtml: result.svg ?? "",
    ariaLabel,
    source: fenceText,
    onSourceChange: (next: string) => post({ type: "source", text: next }),
    onExpand: interactive ? () => post({ type: "expand" }) : undefined,
  });
  if (result.error) handle.updateSource("", fenceText, result.error);
};
(window as any).floRenderSvg = (body: string) => renderMermaid(body);

// Fullscreen overlay (mermaid-fullscreen.ts) in its own full-window web view;
// tells Swift when the overlay has been removed so the view can go away.
(window as any).floFullscreen = function (body: string) {
  openMermaidFullscreen(body, `Mermaid diagram: ${body.split("\n")[0]}`);
  if (!document.querySelector(".cm-mermaid-fullscreen")) { post({ type: "closed" }); return; }
  const mo = new MutationObserver(() => {
    if (!document.querySelector(".cm-mermaid-fullscreen")) { mo.disconnect(); post({ type: "closed" }); }
  });
  mo.observe(document.body, { childList: true });
};
