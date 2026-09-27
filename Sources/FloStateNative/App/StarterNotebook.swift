import Foundation
import FloCore

/// "Start from Scratch": a new notebook folder in ~/Documents with a Welcome note
/// (folder name, note name and content in the UI language).
enum StarterNotebook {
    static var folderName: String { L("Notebook") }
    static var noteName: String { L("Welcome.md") }

    /// The note in the UI language: `<lang>.lproj/Welcome.md`, else the English `welcome`.
    static var localizedWelcome: String {
        guard let url = L10n.bundle.url(forResource: "Welcome", withExtension: "md"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return welcome }
        return s
    }

    /// ~/Documents/Notebook, or "Notebook 2", "Notebook 3"… when that name is taken
    /// by a non-empty folder (an empty one is reused).
    static func folder(documents: URL) -> URL {
        let fm = FileManager.default
        for i in 1...999 {
            let url = documents.appendingPathComponent(i == 1 ? folderName : "\(folderName) \(i)")
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: url.path, isDirectory: &isDir) { return url }
            if isDir.boolValue, ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter({ !$0.hasPrefix(".") }).isEmpty { return url }
        }
        return documents.appendingPathComponent("\(folderName) \(UUID().uuidString.prefix(4))")
    }

    /// Creates the folder and Welcome.md; returns (folder, note).
    static func create(documents: URL) throws -> (String, String) {
        let dir = folder(documents: documents)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let note = dir.appendingPathComponent(noteName)
        try Data(localizedWelcome.utf8).write(to: note, options: .withoutOverwriting)
        return (dir.path, note.path)
    }

    static let welcome = """
    # Welcome to Flo State

    This notebook is just a folder of plain markdown files in your Documents folder. Any app can open them, and nothing is locked in.

    ## Writing

    Markdown renders as you type. The syntax shows on the line you're editing and gets out of the way everywhere else: **bold**, _italic_, `code`, [links](https://flocrivello.com/flostate/).

    - Lists continue when you press Return
    - [ ] Checkboxes too
    - [x] Click one to tick it

    ## Moving around

    - **⌘K** runs any command. **⌘O** jumps to a note by name.
    - **⌘⇧F** searches inside all your notes.
    - **⌘N** creates a note. **⌘T** opens a new tab.
    - **⌘\\\\** shows or hides the sidebar.
    - Type `[[` to link to another note, like [[Welcome]].

    ## Daily notes

    **⌘⇧D** jumps to today's entry in your daily note, adding a dated heading if it isn't there yet.

    ## Headings fold

    Hover a heading and click the arrow on its left to collapse everything under it. **⌘⌥←** collapses all headings and **⌘⌥→** expands them.

    ## Images, tables, math and diagrams

    Paste or drop an image: it's saved in an `attachments` folder next to the note. Hover it and drag the corner handle to resize, or right-click for preset sizes.

    | Feature | Shortcut |
    | --- | --- |
    | Command palette | ⌘K |
    | Search all notes | ⌘⇧F |

    Math uses LaTeX: $e^{i\\pi} + 1 = 0$

    ```mermaid
    graph LR
      Idea --> Draft --> Done
    ```

    ## Make it yours

    **⌘,** opens Settings: themes, fonts, sizes and spacing. **⌘+** and **⌘−** change the text size.

    Delete this note whenever you like. Happy writing.
    """
}
