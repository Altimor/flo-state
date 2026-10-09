import AppKit
import XCTest
import PDFKit
@testable import FloCore
@testable import FloStateNative

/// The PDF tab's toolbar and zoom keys.
@MainActor
final class PDFViewerTests: XCTestCase {
    func makePDF(_ pages: Int) -> String {
        let path = NSTemporaryDirectory() + "flo-pdf-\(UUID().uuidString).pdf"
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages { ctx.beginPDFPage(nil); ctx.endPDFPage() }
        ctx.closePDF()
        return path
    }

    func viewer(_ pages: Int = 3) -> FileViewerView {
        let v = FileViewerView(path: makePDF(pages), kind: .pdf, background: .white)
        v.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        v.layoutSubtreeIfNeeded()
        v.layout()
        return v
    }

    func testZoomStepsAndActualSize() throws {
        let v = viewer()
        let pdf = try XCTUnwrap(v.pdfView)
        let start = pdf.scaleFactor
        v.zoom(1)
        XCTAssertGreaterThan(pdf.scaleFactor, start)
        v.zoom(-1); v.zoom(-1)
        XCTAssertLessThan(pdf.scaleFactor, start)
        v.zoom(0)
        XCTAssertEqual(pdf.scaleFactor, 1, accuracy: 0.001)
        XCTAssertEqual(v.toolbar?.zoomLabel.title, "100%")
        // the fit button: fit width, then actual size again
        v.toggleFit()
        XCTAssertEqual(pdf.scaleFactor, v.fitScale()!, accuracy: 0.01)
        XCTAssertEqual(v.toolbar?.fitButton.title, "Actual Size")
        v.toggleFit()
        XCTAssertEqual(pdf.scaleFactor, 1, accuracy: 0.001)
        XCTAssertEqual(v.toolbar?.fitButton.title, "Fit")
    }

    func testPageIndicator() {
        let v = viewer(3)
        XCTAssertEqual(v.toolbar?.pageLabel.stringValue, "1 / 3")
        v.pdfView?.go(to: v.pdfView!.document!.page(at: 2)!)
        v.updateToolbar()
        XCTAssertEqual(v.toolbar?.pageLabel.stringValue, "3 / 3")
        XCTAssertGreaterThan(v.toolbar?.frame.width ?? 0, 100, "the toolbar is laid out")
    }

    /// ⌘+ / ⌘− / ⌘0 (the View menu's font-size actions) go to the PDF when its tab is active.
    func testZoomKeysRouteToThePDF() async throws {
        let f = ShellFixture(files: ["a.md": "# A"], config: "")
        await f.open()
        let pdf = f.p("doc.pdf")
        try FileManager.default.copyItem(atPath: makePDF(2), toPath: pdf)
        var got: [ShellModel.EditorCommandRequest] = []
        f.model.editorCommand = { got.append($0) }
        let size = f.model.values.editorFontSize
        try await f.model.editor.openFileInTabOrFocus(pdf)
        XCTAssertTrue(f.model.activeTabIsPDF)
        f.model.perform(.fontSizeIncrease)
        f.model.perform(.fontSizeDecrease)
        f.model.perform(.fontSizeReset)
        XCTAssertEqual(got, [.viewerZoom(1), .viewerZoom(-1), .viewerZoom(0)])
        XCTAssertEqual(f.model.values.editorFontSize, size, "the editor font is untouched")
        try await f.model.editor.openFileInTabOrFocus(f.p("a.md"))
        XCTAssertFalse(f.model.activeTabIsPDF)
    }
}
