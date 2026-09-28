import AppKit
import Quartz

/// Shows one file in the system Quick Look panel (the PDF card's button). The text view takes panel
/// control through the responder chain (`acceptsPreviewPanelControl`) and hands it this data source.
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private(set) var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        // when no responder claimed the panel (e.g. the text view isn't first responder yet)
        if panel.dataSource == nil { panel.dataSource = self; panel.delegate = self; panel.reloadData() }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
}

extension EditorController {
    /// Redraw the PDF cards whose hover state changed (their controls show only while hovered).
    func pdfHoverChanged(from old: Int?, to new: Int?) {
        for f in [old, new].compactMap({ $0 }) {
            if let hit = imageRects[f] { textView.setNeedsDisplay(hit.rect.insetBy(dx: -4, dy: -4)) }
        }
    }

    /// The PDF whose Quick Look button is under a view point.
    func pdfQuickLookURL(at point: NSPoint) -> URL? {
        guard let plan = currentPlan else { return nil }
        for hit in imageRects.values {
            guard let url = hit.url, url.pathExtension.lowercased() == "pdf",
                  PDFCard.quickLookRect(in: hit.rect).contains(point) else { continue }
            let live = plan.widgets.contains { w in
                if case .image = w.kind { return w.from == hit.from && w.to == hit.to }
                return false
            }
            if live { return url }
        }
        return nil
    }
}
