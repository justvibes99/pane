import SwiftUI
import WebKit
import CryptoKit
import UniformTypeIdentifiers

// MARK: - State

enum ViewportPreset: String, CaseIterable {
    case auto = "Auto"
    case mobile = "Mobile"
    case tablet = "Tablet"
    case desktop = "Desktop"

    /// Device resolution (points). nil = fill pane.
    var deviceSize: CGSize? {
        switch self {
        case .auto:    return nil
        case .mobile:  return CGSize(width: 390, height: 844)   // iPhone 15
        case .tablet:  return CGSize(width: 820, height: 1180)  // iPad Air
        case .desktop: return CGSize(width: 1440, height: 900)  // Laptop
        }
    }
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case freehand, rectangle, ellipse, arrow, line, text

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .freehand:  return "pencil.tip"
        case .rectangle: return "rectangle"
        case .ellipse:   return "circle"
        case .arrow:     return "arrow.up.right"
        case .line:      return "line.diagonal"
        case .text:      return "character.textbox"
        }
    }

    var label: String {
        switch self {
        case .freehand:  return "Freehand"
        case .rectangle: return "Rectangle"
        case .ellipse:   return "Ellipse"
        case .arrow:     return "Arrow"
        case .line:      return "Line"
        case .text:      return "Text"
        }
    }
}

struct Annotation: Identifiable {
    let id = UUID()
    let tool: AnnotationTool
    var points: [CGPoint]  // freehand: N points; shapes/text: [start, end] or [position]
    var text: String = ""  // only used for .text tool
}

struct ThemeToken: Identifiable {
    let id = UUID()
    let name: String          // CSS var name without --
    var value: String
    let originalValue: String
    var isColor: Bool { value.hasPrefix("#") || value.hasPrefix("rgb") || value.hasPrefix("hsl") }
    var isDirty: Bool { value != originalValue }
}

// MARK: - Project Types

struct ProjectInfo: Codable, Identifiable {
    var id: String { slug }
    let slug: String
    var displayName: String
    var sourcePath: String?       // path to real codebase (nil for new/scratch)
    var createdAt: Date
    var lastOpenedAt: Date
    var sections: [SectionInfo]
    var extracted: Bool           // true once Claude has analyzed the source
}

struct SectionInfo: Codable, Identifiable {
    var id: String { name }
    let name: String              // matches <section id="name">
    var displayName: String
}

enum ProjectContext: Equatable {
    case none
    case scratch
    case project(String) // slug
}

enum LaunchMode { case picker, workspace }

// MARK: - Theme Setup Templates

struct ThemeTemplate: Identifiable {
    let id: String
    let displayName: String
    let bgColor: String
    let surfaceColor: String
    let textColor: String
    let accentColor: String
    let fontFamily: String
    let fontLabel: String
}

enum FontChoice: String, CaseIterable, Identifiable {
    case system, serif, mono, rounded
    var id: String { rawValue }
    var cssValue: String {
        switch self {
        case .system: return "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
        case .serif: return "Georgia, 'Times New Roman', serif"
        case .mono: return "'SF Mono', 'Fira Code', 'Courier New', monospace"
        case .rounded: return "ui-rounded, 'SF Pro Rounded', system-ui, sans-serif"
        }
    }
}

let themeTemplates: [ThemeTemplate] = [
    ThemeTemplate(id: "modern-dark", displayName: "Modern Dark",
                  bgColor: "#1A1A2E", surfaceColor: "#16213E",
                  textColor: "#E8E8E8", accentColor: "#0F7DFF",
                  fontFamily: FontChoice.system.cssValue, fontLabel: "System"),
    ThemeTemplate(id: "clean-light", displayName: "Clean Light",
                  bgColor: "#FFFFFF", surfaceColor: "#F5F5F5",
                  textColor: "#1A1A1A", accentColor: "#0D9488",
                  fontFamily: FontChoice.system.cssValue, fontLabel: "System"),
    ThemeTemplate(id: "warm-neutral", displayName: "Warm Neutral",
                  bgColor: "#FAF6F1", surfaceColor: "#F0EBE3",
                  textColor: "#3E2C1C", accentColor: "#E07A2F",
                  fontFamily: FontChoice.serif.cssValue, fontLabel: "Serif"),
    ThemeTemplate(id: "bold-contrast", displayName: "Bold Contrast",
                  bgColor: "#000000", surfaceColor: "#1A1A1A",
                  textColor: "#FFFFFF", accentColor: "#E53E3E",
                  fontFamily: FontChoice.mono.cssValue, fontLabel: "Mono"),
]

// MARK: - Project Helpers

private let libraryBase = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("ligma/library")

func slugify(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespaces).lowercased()
        .replacingOccurrences(of: " ", with: "-")
        .replacingOccurrences(of: "_", with: "-")
        .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
}

func loadProjectInfo(slug: String) -> ProjectInfo? {
    let url = libraryBase.appendingPathComponent(slug).appendingPathComponent("project.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(ProjectInfo.self, from: data)
}

func saveProjectInfo(_ info: ProjectInfo) {
    let dir = libraryBase.appendingPathComponent(info.slug)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("project.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(info) {
        try? data.write(to: url)
    }
}

func discoverProjects() -> [ProjectInfo] {
    let fm = FileManager.default
    try? fm.createDirectory(at: libraryBase, withIntermediateDirectories: true)
    guard let contents = try? fm.contentsOfDirectory(atPath: libraryBase.path) else { return [] }
    var isDir: ObjCBool = false
    let slugs = contents.filter {
        !$0.hasPrefix(".") && !$0.hasPrefix("_") &&
        fm.fileExists(atPath: libraryBase.appendingPathComponent($0).path, isDirectory: &isDir) &&
        isDir.boolValue
    }
    var projects: [ProjectInfo] = []
    for slug in slugs {
        if let info = loadProjectInfo(slug: slug) {
            projects.append(info)
        } else {
            // Auto-migrate legacy folder (no project.json)
            let info = ProjectInfo(
                slug: slug,
                displayName: slug.replacingOccurrences(of: "-", with: " ").capitalized,
                sourcePath: nil,
                createdAt: Date(),
                lastOpenedAt: Date(),
                sections: [],
                extracted: false
            )
            saveProjectInfo(info)
            projects.append(info)
        }
    }
    return projects.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
}

func createProject(name: String, sourcePath: String?) -> ProjectInfo {
    let slug = slugify(name)
    let info = ProjectInfo(
        slug: slug,
        displayName: name,
        sourcePath: sourcePath,
        createdAt: Date(),
        lastOpenedAt: Date(),
        sections: [],
        extracted: false
    )
    saveProjectInfo(info)
    return info
}

// MARK: - Asset Helpers

private let ligmaBase = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("ligma")

func assetsDir(for slug: String) -> URL {
    let dir = libraryBase.appendingPathComponent(slug).appendingPathComponent("assets")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func activateAssetSymlink(for slug: String) {
    let fm = FileManager.default
    let symlinkURL = ligmaBase.appendingPathComponent("assets")
    // Remove existing symlink/file
    try? fm.removeItem(at: symlinkURL)
    let target = assetsDir(for: slug)
    try? fm.createSymbolicLink(at: symlinkURL, withDestinationURL: target)
}

func deactivateAssetSymlink() {
    let symlinkURL = ligmaBase.appendingPathComponent("assets")
    try? FileManager.default.removeItem(at: symlinkURL)
}

func importAsset(from sourceURL: URL, projectSlug: String) -> String? {
    let fm = FileManager.default
    let dir = assetsDir(for: projectSlug)
    var destName = sourceURL.lastPathComponent
    var destURL = dir.appendingPathComponent(destName)

    // Handle name collisions
    var counter = 1
    let baseName = (destName as NSString).deletingPathExtension
    let ext = (destName as NSString).pathExtension
    while fm.fileExists(atPath: destURL.path) {
        destName = "\(baseName)-\(counter).\(ext)"
        destURL = dir.appendingPathComponent(destName)
        counter += 1
    }

    do {
        try fm.copyItem(at: sourceURL, to: destURL)
        return "assets/\(destName)"
    } catch {
        return nil
    }
}

func componentsDir(for slug: String) -> URL {
    let dir = libraryBase.appendingPathComponent(slug).appendingPathComponent("components")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func listAssets(for slug: String) -> [String] {
    let dir = assetsDir(for: slug)
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
    return files.filter { !$0.hasPrefix(".") }.sorted()
}

func listComponents(for slug: String) -> [String] {
    let dir = componentsDir(for: slug)
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
    return files.filter { $0.hasSuffix(".html") }.sorted()
}

let globalComponentsDir: URL = {
    let dir = libraryBase.appendingPathComponent("_components")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

func listGlobalComponents() -> [String] {
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: globalComponentsDir.path) else { return [] }
    return files.filter { $0.hasSuffix(".html") }.sorted()
}

func projectsWithComponents() -> [String] {
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(atPath: libraryBase.path) else { return [] }
    var isDir: ObjCBool = false
    return contents.filter { name in
        !name.hasPrefix(".") && !name.hasPrefix("_") &&
        fm.fileExists(atPath: libraryBase.appendingPathComponent(name).path, isDirectory: &isDir) &&
        isDir.boolValue && !listComponents(for: name).isEmpty
    }.sorted()
}

func writeDesignBrief(slug: String, tokens: [ThemeToken], instructions: String) {
    let dir = libraryBase.appendingPathComponent(slug)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("design-brief.md")
    var content = "# Design Brief\n\n## Color Palette\n\n```css\n:root {\n"
    for token in tokens {
        content += "  --\(token.name): \(token.value);\n"
    }
    content += "}\n```\n"
    if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        content += "\n## Design Instructions\n\n\(instructions)\n"
    }
    try? content.write(to: url, atomically: true, encoding: .utf8)
}

func loadDesignBrief(slug: String) -> String? {
    let url = libraryBase.appendingPathComponent(slug).appendingPathComponent("design-brief.md")
    return try? String(contentsOf: url, encoding: .utf8)
}

func writeStarterPreview(tokens: [ThemeToken]) {
    let previewURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ligma/preview.html")
    var cssVars = ""
    for token in tokens {
        cssVars += "  --\(token.name): \(token.value);\n"
    }
    let fontVar = tokens.first(where: { $0.name == "font-family" })?.value ?? "system-ui, sans-serif"
    let bgVar = tokens.first(where: { $0.name == "color-bg" })?.value ?? "#ffffff"
    let textVar = tokens.first(where: { $0.name == "color-text" })?.value ?? "#1a1a1a"
    let surfaceVar = tokens.first(where: { $0.name == "color-surface" })?.value ?? "#f5f5f5"
    let accentVar = tokens.first(where: { $0.name == "color-accent" })?.value ?? "#0066ff"
    let html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
    :root {
    \(cssVars)}
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: \(fontVar);
      background: \(bgVar);
      color: \(textVar);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .card {
      background: \(surfaceVar);
      border-radius: 16px;
      padding: 48px;
      max-width: 480px;
      text-align: center;
      box-shadow: 0 1px 3px rgba(0,0,0,0.1);
    }
    .card h1 { font-size: 24px; margin-bottom: 12px; }
    .card p { font-size: 15px; opacity: 0.7; line-height: 1.5; }
    .accent { color: \(accentVar); }
    </style>
    </head>
    <body>
    <div class="card">
      <h1>Ready to design</h1>
      <p>Your theme is set up. Describe what you want in the chat and <span class="accent">let's build it</span>.</p>
    </div>
    </body>
    </html>
    """
    try? html.write(to: previewURL, atomically: true, encoding: .utf8)
}

func detectFramework(at path: String) -> String? {
    let fm = FileManager.default
    let checks: [(String, String)] = [
        ("package.json", "Node.js"),
        ("Package.swift", "Swift"),
        ("pubspec.yaml", "Flutter"),
        ("Cargo.toml", "Rust"),
        ("go.mod", "Go"),
        ("requirements.txt", "Python"),
        ("Gemfile", "Ruby"),
        ("pom.xml", "Java/Maven"),
        ("build.gradle", "Java/Gradle"),
    ]
    for (file, framework) in checks {
        let filePath = (path as NSString).appendingPathComponent(file)
        if fm.fileExists(atPath: filePath) { return framework }
    }
    return nil
}

@Observable
final class AppState {
    var showPreview: Bool {
        didSet { UserDefaults.standard.set(showPreview, forKey: "showPreview") }
    }
    var previewReady = false
    var lastUpdated: Date?

    // Iteration history
    var versions: [URL] = []
    var currentVersionIndex = 0
    var isBrowsingHistory = false
    var newVersionsWhileBrowsing = 0

    // Design library (sidebar, not modal)
    var showLibrary: Bool {
        didSet { UserDefaults.standard.set(showLibrary, forKey: "showLibrary") }
    }
    var showSaveSheet = false

    // Build spec
    var showSpecSheet = false

    // Viewport
    var viewport: ViewportPreset = .auto
    var viewportRotated = false

    // Copy as image confirmation
    var showCopyImageConfirmation = false

    // Session tracking (bumped on new session to trigger WebView clear)
    var sessionGeneration = 0

    // Sketch overlay
    var isSketchMode = false
    var annotations: [Annotation] = []
    var currentAnnotation: Annotation?
    var activeTool: AnnotationTool = .freehand
    var editingAnnotationId: UUID?
    var editingText: String = ""

    // Theme editor
    var showThemeEditor = false
    var themeTokens: [ThemeToken] = []

    // New session confirmation
    var showNewSessionConfirm = false

    // Session resume
    var showResumePrompt = false

    // Project-first architecture
    var launchMode: LaunchMode = .picker
    var currentProject: ProjectContext = .none
    var currentProjectInfo: ProjectInfo?
    var currentSectionId: String?
    var showApplySheet = false
    var showRebaseConfirm = false

    // Asset import
    var showAssetImportConfirmation = false
    var lastImportedAssetPath: String?
    var showAssetsPopover = false
    var showSettingsPopover = false

    // Claude settings
    var claudeModel: String {
        didSet {
            UserDefaults.standard.set(claudeModel, forKey: "claudeModel")
            NotificationCenter.default.post(name: .clearSession, object: nil)
        }
    }
    var claudePermissionMode: String {
        didSet {
            UserDefaults.standard.set(claudePermissionMode, forKey: "claudePermissionMode")
            NotificationCenter.default.post(name: .clearSession, object: nil)
        }
    }

    // Element picker
    var isElementPickerActive = false

    // Component editing
    var editingComponentPath: URL?

    // Component library
    var sidebarTab: Int = 0  // 0 = Views, 1 = Components
    var selectedComponent: String?  // "project/component-name" or "_global/component-name"
    var attachedComponents: [(name: String, html: String)] = []

    // Element picker naming
    var showComponentNamingSheet = false
    var pendingComponentHTML: String?
    var pendingComponentTag: String?
    var pendingComponentPNG: Data?

    // Theme setup
    var designInstructions: String = ""
    var skipInitialPreviewClear = false

    // Annotation undo stack
    enum AnnotationUndoAction {
        case added           // last annotation was newly added — undo by removing
        case moved(UUID, [CGPoint])  // annotation was moved — undo by restoring original points
    }
    var annotationUndoStack: [AnnotationUndoAction] = []

    func pushAnnotationUndo(_ action: AnnotationUndoAction) {
        annotationUndoStack.append(action)
    }

    func undoLastAnnotation() {
        guard let action = annotationUndoStack.popLast() else { return }
        switch action {
        case .added:
            if !annotations.isEmpty { annotations.removeLast() }
        case .moved(let id, let originalPoints):
            if let idx = annotations.firstIndex(where: { $0.id == id }) {
                annotations[idx].points = originalPoints
            }
        }
    }

    init() {
        self.showPreview = true
        self.showLibrary = UserDefaults.standard.bool(forKey: "showLibrary")
        self.claudeModel = UserDefaults.standard.string(forKey: "claudeModel") ?? "sonnet"
        self.claudePermissionMode = UserDefaults.standard.string(forKey: "claudePermissionMode") ?? "acceptEdits"
    }
}

extension Notification.Name {
    static let reloadPreview = Notification.Name("reloadPreview")
    static let previousVersion = Notification.Name("previousVersion")
    static let nextVersion = Notification.Name("nextVersion")
    static let copyPreviewAsImage = Notification.Name("copyPreviewAsImage")
    static let clearSession = Notification.Name("clearSession")
    static let libraryDidChange = Notification.Name("libraryDidChange")
    static let refreshScreenshot = Notification.Name("refreshScreenshot")
    static let injectThemeChange = Notification.Name("injectThemeChange")
    static let writeThemeToFile = Notification.Name("writeThemeToFile")
    static let activateElementPicker = Notification.Name("activateElementPicker")
    static let deactivateElementPicker = Notification.Name("deactivateElementPicker")
}

// MARK: - App

@main
struct LigmaApp: App {
    @State private var state = AppState()

    init() {
        // Single-instance: if another Ligma is already running, activate it and quit
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myExec = Bundle.main.executableURL?.lastPathComponent ?? "Ligma"
        if let existing = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier != myPID &&
            $0.executableURL?.lastPathComponent == myExec
        }) {
            existing.activate()
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
            return
        }

        NSApplication.shared.setActivationPolicy(.regular)
        // Set dock icon from bundled .icns (preferred) or .png fallback
        if let icnsURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: icnsURL) {
            NSApplication.shared.applicationIconImage = image
        } else if let url = Bundle.module.url(forResource: "ligma-logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 512, height: 512)
            NSApplication.shared.applicationIconImage = image
        }
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch state.launchMode {
                case .picker:
                    ProjectPickerView(state: state)
                case .workspace:
                    ContentView(state: state)
                }
            }
        }
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Preview") {
                Button(state.showPreview ? "Hide Preview" : "Show Preview") {
                    state.showPreview.toggle()
                }
                .keyboardShortcut("d", modifiers: .command)

                Divider()

                Button("Previous Version") {
                    NotificationCenter.default.post(name: .previousVersion, object: nil)
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!state.showPreview || state.versions.count < 2)

                Button("Next Version") {
                    NotificationCenter.default.post(name: .nextVersion, object: nil)
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!state.showPreview || !state.isBrowsingHistory)

                Divider()

                Button("Save to Library...") {
                    state.showSaveSheet = true
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!state.previewReady)

                Button("Export Spec...") {
                    state.showSpecSheet = true
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!state.previewReady)

                Button("Copy as Image") {
                    NotificationCenter.default.post(name: .copyPreviewAsImage, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!state.previewReady)

                Divider()

                Button("Reload Preview") {
                    NotificationCenter.default.post(name: .reloadPreview, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!state.showPreview)

                Button("Open in Browser") {
                    let url = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("ligma/preview.html")
                    NSWorkspace.shared.open(url)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!state.previewReady)

                Divider()

                Button("Show/Hide Theme Editor") {
                    state.showThemeEditor.toggle()
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!state.previewReady || !state.showPreview)
            }

            CommandMenu("Projects") {
                Button(state.showLibrary ? "Hide Projects" : "Show Projects") {
                    state.showLibrary.toggle()
                }
                .keyboardShortcut("l", modifiers: .command)

                if state.launchMode == .workspace {
                    Divider()
                    Button("Close Project") {
                        state.launchMode = .picker
                        state.currentProject = .none
                        state.currentProjectInfo = nil
                        state.currentSectionId = nil
                        state.editingComponentPath = nil
                        state.previewReady = false
                    }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                }
            }
        }
    }
}

// MARK: - Ligma Logo (Figma mirrored as L)

struct LigmaLogo: View {
    var body: some View {
        if let url = Bundle.module.url(forResource: "ligma-logo", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
    }
}

// MARK: - Project Picker View

struct ProjectPickerView: View {
    @Bindable var state: AppState

    @State private var showNewProjectSheet = false
    @State private var showOpenCodebaseSheet = false
    @State private var showOpenProjectSheet = false

    private let bgColor = Color(red: 0x2C/255, green: 0x2C/255, blue: 0x2C/255)
    private let cardBg = Color(red: 0x38/255, green: 0x38/255, blue: 0x38/255)
    private let cardBorder = Color(red: 0x44/255, green: 0x44/255, blue: 0x44/255)
    private let teal = Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255)

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Title
                VStack(spacing: 6) {
                    LigmaLogo()
                        .frame(width: 48, height: 48)
                    Text("Ligma")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Design as fast as you build")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 0xB3/255, green: 0xB3/255, blue: 0xB3/255))
                }

                // 2x2 card grid
                LazyVGrid(columns: [GridItem(.fixed(200)), GridItem(.fixed(200))], spacing: 12) {
                    pickerCard(icon: "plus.rectangle.on.rectangle", title: "New Project",
                               subtitle: "Start a blank project") {
                        showNewProjectSheet = true
                    }

                    pickerCard(icon: "folder", title: "Open Project",
                               subtitle: "Open from library") {
                        showOpenProjectSheet = true
                    }

                    pickerCard(icon: "arrow.right.doc.on.clipboard", title: "Open Codebase",
                               subtitle: "Link to existing code") {
                        showOpenCodebaseSheet = true
                    }

                    pickerCard(icon: "bolt", title: "Quick Scratch",
                               subtitle: "No project, just design") {
                        enterScratch()
                    }
                }

                Spacer()
            }
        }
        .sheet(isPresented: $showNewProjectSheet) {
            NewProjectSheet(state: state)
        }
        .sheet(isPresented: $showOpenCodebaseSheet) {
            OpenCodebaseSheet(state: state)
        }
        .sheet(isPresented: $showOpenProjectSheet) {
            OpenProjectSheet(state: state)
        }
    }

    private func pickerCard(icon: String, title: String, subtitle: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(teal)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0xB3/255, green: 0xB3/255, blue: 0xB3/255))
            }
            .frame(width: 200, height: 120)
            .background(cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func enterScratch() {
        state.currentProject = .scratch
        state.currentProjectInfo = nil
        state.editingComponentPath = nil
        state.launchMode = .workspace
        deactivateAssetSymlink()
    }

    private func openProject(_ project: ProjectInfo) {
        var updated = project
        updated.lastOpenedAt = Date()
        saveProjectInfo(updated)
        state.currentProject = .project(project.slug)
        state.currentProjectInfo = updated
        state.editingComponentPath = nil
        state.launchMode = .workspace
        activateAssetSymlink(for: project.slug)
    }

    private func abbreviatePath(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func relativeDate(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

// MARK: - New Project Sheet

struct NewProjectSheet: View {
    @Bindable var state: AppState
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project")
                .font(.headline)

            TextField("Project name", text: $name, prompt: Text("e.g. Dashboard Redesign"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(slugify(name).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func create() {
        let project = createProject(name: name, sourcePath: nil)
        state.currentProject = .project(project.slug)
        state.currentProjectInfo = project
        state.launchMode = .workspace
        dismiss()
    }
}

// MARK: - Open Codebase Sheet

struct OpenCodebaseSheet: View {
    @Bindable var state: AppState
    @State private var selectedPath: String?
    @State private var name = ""
    @State private var detectedFramework: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Codebase")
                .font(.headline)

            if let path = selectedPath {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(path.replacingOccurrences(
                        of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change") { pickFolder() }
                        .font(.system(size: 11))
                }

                TextField("Project name", text: $name, prompt: Text("e.g. My App"))
                    .textFieldStyle(.roundedBorder)

                if let fw = detectedFramework {
                    Label("Detected: \(fw)", systemImage: "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255))
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Open & Analyze") { openAndAnalyze() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(slugify(name).isEmpty)
                }
            } else {
                Text("Select a project directory to analyze and reproduce as a visual mockup.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Choose Folder...") { pickFolder() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { pickFolder() }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"
        if panel.runModal() == .OK, let url = panel.url {
            selectedPath = url.path
            if name.isEmpty {
                name = url.lastPathComponent.replacingOccurrences(of: "-", with: " ").capitalized
            }
            detectedFramework = detectFramework(at: url.path)
        }
    }

    private func openAndAnalyze() {
        guard let path = selectedPath else { return }
        let project = createProject(name: name, sourcePath: path)
        state.currentProject = .project(project.slug)
        state.currentProjectInfo = project
        state.launchMode = .workspace
        dismiss()
    }
}

// MARK: - Open Project Sheet

struct OpenProjectSheet: View {
    @Bindable var state: AppState
    @State private var projects: [ProjectInfo] = []
    @Environment(\.dismiss) private var dismiss

    private let cardBg = Color(red: 0x38/255, green: 0x38/255, blue: 0x38/255)
    private let cardBorder = Color(red: 0x44/255, green: 0x44/255, blue: 0x44/255)
    private let teal = Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Project")
                .font(.headline)

            if projects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("No projects yet")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Create a new project to get started.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(projects) { project in
                            Button {
                                openProject(project)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: project.sourcePath != nil
                                          ? "arrow.right.doc.on.clipboard" : "rectangle.on.rectangle")
                                        .font(.system(size: 12))
                                        .foregroundStyle(teal)
                                        .frame(width: 20)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(project.displayName)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.primary)
                                        if let src = project.sourcePath {
                                            Text(src.replacingOccurrences(
                                                of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }

                                    Spacer()

                                    Text(relativeDate(project.lastOpenedAt))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(cardBg)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(cardBorder, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            projects = discoverProjects()
        }
    }

    private func openProject(_ project: ProjectInfo) {
        var updated = project
        updated.lastOpenedAt = Date()
        saveProjectInfo(updated)
        state.currentProject = .project(project.slug)
        state.currentProjectInfo = updated
        state.launchMode = .workspace
        activateAssetSymlink(for: project.slug)

        // Clear old version history and preview from disk before Coordinator starts
        let fm = FileManager.default
        let versionsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("ligma/.versions")
        if let files = try? fm.contentsOfDirectory(atPath: versionsDir.path) {
            for file in files where file.hasSuffix(".html") {
                try? fm.removeItem(at: versionsDir.appendingPathComponent(file))
            }
        }
        let previewPath = fm.homeDirectoryForCurrentUser.appendingPathComponent("ligma/preview.html").path
        if let fh = FileHandle(forWritingAtPath: previewPath) {
            fh.truncateFile(atOffset: 0)
            fh.closeFile()
        }
        state.versions.removeAll()
        state.currentVersionIndex = 0
        state.isBrowsingHistory = false
        state.previewReady = false

        dismiss()
    }

    private func relativeDate(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

// MARK: - Content View

struct ContentView: View {
    @Bindable var state: AppState
    @State private var chatVM = ChatViewModel()
    @State private var now = Date()
    @State private var previewWatcher: DispatchSourceFileSystemObject?
    @State private var previewDebounce: DispatchWorkItem?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let previewPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ligma/preview.html").path

    private var projectTitle: String {
        switch state.currentProject {
        case .none: return "Ligma"
        case .scratch: return "Ligma — Scratch"
        case .project:
            if let name = state.currentProjectInfo?.displayName {
                return "Ligma — \(name)"
            }
            return "Ligma"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Projects sidebar
            if state.showLibrary {
                ProjectsSidebar(state: state)
                    .frame(width: 220)

                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }

            // Main content: narrow chat + wide preview
            GeometryReader { geo in
                let chatWidth: CGFloat = state.showPreview
                    ? min(360, geo.size.width * 0.35) : geo.size.width
                let previewWidth = geo.size.width - chatWidth
                    - (state.showPreview ? 1 : 0)

                HStack(spacing: 0) {
                    ChatView(viewModel: chatVM)
                        .frame(width: chatWidth)

                    if state.showPreview {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: 1)

                        VStack(spacing: 0) {
                            previewToolbar
                            previewContent
                            if state.showThemeEditor {
                                Divider()
                                ThemeEditorPanel(state: state, applyChange: { name, value in
                                    NotificationCenter.default.post(
                                        name: .injectThemeChange,
                                        object: nil,
                                        userInfo: ["name": name, "value": value]
                                    )
                                }, applyAllToFile: { pairs in
                                    NotificationCenter.default.post(
                                        name: .writeThemeToFile,
                                        object: nil,
                                        userInfo: ["tokens": pairs]
                                    )
                                })
                            }
                        }
                        .frame(width: previewWidth)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.launchMode = .picker
                    state.currentProject = .none
                    state.currentProjectInfo = nil
                    state.currentSectionId = nil
                    state.editingComponentPath = nil
                    state.previewReady = false
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Close Project (\u{2318}\u{21E7}W)")
            }

            ToolbarItem {
                Button {
                    state.showLibrary.toggle()
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .help("Projects (\u{2318}L)")
            }

            if state.previewReady && !state.showPreview {
                ToolbarItem {
                    Button { state.showPreview = true } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255))
                                .frame(width: 8, height: 8)
                            Text("Preview ready")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 650)
        .navigationTitle(projectTitle)
        .onReceive(timer) { now = $0 }
        .onAppear {
            startPreviewWatcher()
            chatVM.appState = state
            chatVM.configure(for: state.currentProject)
            if chatVM._shouldShowResumePrompt {
                chatVM._shouldShowResumePrompt = false
                state.showResumePrompt = true
            }
            // Auto-extract for codebase projects
            if let info = state.currentProjectInfo,
               let sourcePath = info.sourcePath,
               !info.extracted,
               chatVM.sessionId == nil {
                chatVM.sendExtractionPrompt(sourcePath: sourcePath)
            }
        }
        .sheet(isPresented: $state.showSaveSheet) {
            SaveSheet(state: state)
        }
        .sheet(isPresented: $state.showComponentNamingSheet) {
            ComponentNamingSheet(state: state)
        }
        .sheet(isPresented: $state.showSpecSheet) {
            SpecSheet(state: state, messages: chatVM.messages)
        }
        .alert("Start New Session?", isPresented: $state.showNewSessionConfirm) {
            Button("Discard & Start New", role: .destructive) {
                chatVM.newSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current design hasn't been saved to the library and will be cleared.")
        }
        .alert("Resume Previous Session?", isPresented: $state.showResumePrompt) {
            Button("Resume") {
                chatVM.resumePreviousSession()
            }
            Button("Start Fresh", role: .destructive) {
                chatVM.startFresh()
            }
        } message: {
            Text("You have an active session from before. Would you like to continue where you left off?")
        }
        .sheet(isPresented: $state.showApplySheet) {
            ApplySheet(state: state, chatVM: chatVM)
        }
        .alert("Rebase from Source?", isPresented: $state.showRebaseConfirm) {
            Button("Rebase") {
                if let src = state.currentProjectInfo?.sourcePath {
                    chatVM.rebaseFromSource(sourcePath: src)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let src = state.currentProjectInfo?.sourcePath {
                Text("Re-analyze \(src) and update the mockup to match its current state? Your mockup edits that conflict with source changes will be noted.")
            }
        }
    }

    // MARK: Preview File Watcher (runs even when preview is hidden)

    private func startPreviewWatcher() {
        guard previewWatcher == nil else { return }
        let dirPath = (previewPath as NSString).deletingLastPathComponent
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [self] in
            previewDebounce?.cancel()
            let work = DispatchWorkItem { checkPreviewFile() }
            previewDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        previewWatcher = src

        // Also check immediately on launch
        checkPreviewFile()
    }

    private func checkPreviewFile() {
        guard !state.previewReady else { return }
        guard let html = try? String(contentsOfFile: previewPath, encoding: .utf8),
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        state.previewReady = true
        state.showPreview = true
    }

    // MARK: Preview content

    @ViewBuilder
    private var previewContent: some View {
        let raw = state.viewport.deviceSize
        let device: CGSize? = raw.map { state.viewportRotated
            ? CGSize(width: $0.height, height: $0.width) : $0 }

        GeometryReader { geo in
            if let device {
                let scaleX = geo.size.width / device.width
                let scaleY = geo.size.height / device.height
                let scale = min(scaleX, scaleY) * 0.9

                ZStack {
                    Color(red: 0x1E/255, green: 0x1E/255, blue: 0x1E/255)
                    PreviewWebView(state: state, sessionGeneration: state.sessionGeneration)
                        .overlay { SketchOverlay(state: state) }
                        .frame(width: device.width, height: device.height)
                        .clipShape(RoundedRectangle(cornerRadius: 20 / scale))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20 / scale)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1 / scale)
                        )
                        .scaleEffect(scale)
                        .frame(width: device.width * scale,
                               height: device.height * scale)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                PreviewWebView(state: state, sessionGeneration: state.sessionGeneration)
                    .overlay { SketchOverlay(state: state) }
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .onDrop(of: [.image], isTargeted: nil) { providers in
            guard case .project(let slug) = state.currentProject else { return false }
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { data, _ in
                    guard let urlData = data as? Data,
                          let sourceURL = URL(dataRepresentation: urlData, relativeTo: nil) else { return }
                    if let path = importAsset(from: sourceURL, projectSlug: slug) {
                        DispatchQueue.main.async {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(path, forType: .string)
                            state.lastImportedAssetPath = path
                            state.showAssetImportConfirmation = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                if state.lastImportedAssetPath == path {
                                    state.showAssetImportConfirmation = false
                                }
                            }
                        }
                    }
                }
            }
            return true
        }
        .overlay(alignment: .bottom) {
            if state.showAssetImportConfirmation, let path = state.lastImportedAssetPath {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Imported — \(path) copied to clipboard")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.25), value: state.showAssetImportConfirmation)
            }
        }
        .popover(isPresented: $state.showAssetsPopover) {
            AssetsPopover(state: state)
        }
        .popover(isPresented: $state.showSettingsPopover) {
            SettingsPopover(state: state)
        }
    }

    // MARK: Asset Import

    private func importAssetViaPicker() {
        guard case .project(let slug) = state.currentProject else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Select images to import into project assets"
        guard panel.runModal() == .OK else { return }

        var lastPath: String?
        for url in panel.urls {
            if let path = importAsset(from: url, projectSlug: slug) {
                lastPath = path
            }
        }
        if let lastPath {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lastPath, forType: .string)
            state.lastImportedAssetPath = lastPath
            state.showAssetImportConfirmation = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if state.lastImportedAssetPath == lastPath {
                    state.showAssetImportConfirmation = false
                }
            }
        }
    }

    private func saveComponentBack() {
        guard let componentURL = state.editingComponentPath else { return }
        let previewURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ligma/preview.html")
        guard let html = try? String(contentsOf: previewURL, encoding: .utf8) else { return }
        try? html.write(to: componentURL, atomically: true, encoding: .utf8)
        state.lastImportedAssetPath = "Component saved"
        state.showAssetImportConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if state.lastImportedAssetPath == "Component saved" {
                state.showAssetImportConfirmation = false
            }
        }
    }

    // MARK: Preview Toolbar

    private var previewToolbar: some View {
        VStack(spacing: 0) {
            if state.isBrowsingHistory {
                Rectangle()
                    .fill(Color(red: 255/255, green: 230/255, blue: 109/255))
                    .frame(height: 2)
            }

            HStack(spacing: 8) {
                Text("PREVIEW")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(.secondary)
                    .fixedSize()

                if state.isBrowsingHistory {
                    Button {
                        state.isBrowsingHistory = false
                        state.newVersionsWhileBrowsing = 0
                        NotificationCenter.default.post(name: .reloadPreview, object: nil)
                    } label: {
                        Text("Back to Live")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255))
                }

                Spacer()

                // Viewport picker
                Picker("", selection: Binding(
                    get: { state.viewport },
                    set: { state.viewport = $0 }
                )) {
                    ForEach(ViewportPreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .onChange(of: state.viewport) { _, _ in
                    state.viewportRotated = false
                }

                if state.viewport == .mobile || state.viewport == .tablet {
                    Button {
                        state.viewportRotated.toggle()
                    } label: {
                        Image(systemName: "rotate.right")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Rotate")
                }

                Spacer()

                // Nav arrows + version info
                if state.versions.count >= 2 {
                    Button {
                        NotificationCenter.default.post(name: .previousVersion, object: nil)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(state.isBrowsingHistory && state.currentVersionIndex <= 0)
                    .help("Previous (\u{2318}[)")

                    if state.isBrowsingHistory {
                        Text("\(state.currentVersionIndex + 1)/\(state.versions.count)")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    } else {
                        Text("\(state.versions.count)")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }

                    Button {
                        NotificationCenter.default.post(name: .nextVersion, object: nil)
                    } label: {
                        Image(systemName: state.isBrowsingHistory
                              && state.currentVersionIndex < state.versions.count - 1
                              ? "chevron.right" : "forward.end")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(!state.isBrowsingHistory)
                    .help("Next (\u{2318}])")
                } else if let date = state.lastUpdated {
                    Text(relativeTime(from: date))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                // Sketch controls
                Button {
                    state.isSketchMode.toggle()
                    if state.isSketchMode { state.isElementPickerActive = false }
                } label: {
                    Image(systemName: state.isSketchMode
                          ? "pencil.tip.crop.circle.fill" : "pencil.tip")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.isSketchMode
                    ? Color(red: 1.0, green: 107/255, blue: 107/255)
                    : .secondary)
                .help("Sketch Mode (\u{2318}\u{21E7}D)")
                .keyboardShortcut("d", modifiers: [.command, .shift])

                if state.isSketchMode {
                    HStack(spacing: 2) {
                        ForEach(AnnotationTool.allCases) { tool in
                            Button {
                                state.activeTool = tool
                            } label: {
                                Image(systemName: tool.iconName)
                                    .font(.system(size: 11))
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(state.activeTool == tool
                                ? Color(red: 1.0, green: 107/255, blue: 107/255)
                                : .secondary)
                            .help(tool.label)
                        }
                    }
                }

                if state.isSketchMode && !state.annotations.isEmpty {
                    Button {
                        state.undoLastAnnotation()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Undo Stroke (\u{2318}Z)")
                    .keyboardShortcut("z", modifiers: .command)
                }

                if !state.annotations.isEmpty {
                    Button {
                        state.annotations.removeAll()
                        state.currentAnnotation = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear Sketch")
                }

                // Element picker
                if case .project = state.currentProject {
                    Button {
                        if state.isElementPickerActive {
                            state.isElementPickerActive = false
                            NotificationCenter.default.post(name: .deactivateElementPicker, object: nil)
                        } else {
                            state.isSketchMode = false
                            state.isElementPickerActive = true
                            NotificationCenter.default.post(name: .activateElementPicker, object: nil)
                        }
                    } label: {
                        Image(systemName: state.isElementPickerActive ? "scope" : "scope")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(state.isElementPickerActive
                        ? Color(red: 1.0, green: 107/255, blue: 107/255)
                        : .secondary)
                    .help("Element Picker")
                }

                // Theme editor toggle
                Button {
                    if !state.showThemeEditor {
                        parseThemeTokens()
                    }
                    state.showThemeEditor.toggle()
                } label: {
                    Image(systemName: state.showThemeEditor
                          ? "paintpalette.fill" : "paintpalette")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.showThemeEditor
                    ? Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255)
                    : .secondary)
                .help("Theme Editor (\u{2318}T)")

                // Apply to Project (codebase projects only)
                if case .project = state.currentProject,
                   state.currentProjectInfo?.sourcePath != nil {
                    Button {
                        state.showApplySheet = true
                    } label: {
                        Image(systemName: "arrow.right.doc.on.clipboard")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Apply to Project")

                    Button {
                        state.showRebaseConfirm = true
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Rebase from Source")
                }

                // Import assets (project mode only)
                if case .project = state.currentProject {
                    Button {
                        importAssetViaPicker()
                    } label: {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Import Assets")
                }

                // Component editing toolbar
                if let componentURL = state.editingComponentPath {
                    Divider()
                        .frame(height: 14)

                    // Component name badge
                    Text(componentURL.deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: "-", with: " ").capitalized)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255).opacity(0.15))
                        )

                    Button {
                        saveComponentBack()
                    } label: {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255))
                    .help("Save Component")

                    // Save As (fork)
                    Button {
                        state.showSaveSheet = true
                    } label: {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Save As New Component")

                    Button {
                        state.editingComponentPath = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Exit Component Editing")
                }

                // Save to library
                Button {
                    state.showSaveSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Save to Library (\u{2318}\u{21E7}S)")

                // Overflow menu
                Menu {
                    Button {
                        state.showSpecSheet = true
                    } label: {
                        Label("Export Spec", systemImage: "doc.on.clipboard")
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])

                    if state.showCopyImageConfirmation {
                        Label("Copied", systemImage: "checkmark")
                    } else {
                        Button {
                            NotificationCenter.default.post(name: .copyPreviewAsImage, object: nil)
                        } label: {
                            Label("Copy as Image", systemImage: "photo.on.rectangle")
                        }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    }

                    Button {
                        NotificationCenter.default.post(name: .reloadPreview, object: nil)
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)

                    Button {
                        let url = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("ligma/preview.html")
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open in Browser", systemImage: "arrow.up.right.square")
                    }
                    .keyboardShortcut("o", modifiers: [.command, .shift])

                    if case .project = state.currentProject {
                        Divider()

                        Button {
                            state.showAssetsPopover = true
                        } label: {
                            Label("Project Assets", systemImage: "photo.on.rectangle")
                        }
                    }

                    Divider()

                    Button {
                        state.showSettingsPopover = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }

                    Divider()

                    Button {
                        state.showPreview = false
                    } label: {
                        Label("Close Preview", systemImage: "xmark")
                    }
                    .keyboardShortcut("d", modifiers: .command)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            // Section navigator (for multi-page mockups)
            if let sections = state.currentProjectInfo?.sections, sections.count > 1 {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(sections) { section in
                            Button {
                                state.currentSectionId = section.name
                                let js = "location.hash = '#\(section.name)'"
                                NotificationCenter.default.post(
                                    name: .reloadPreview, object: js)
                            } label: {
                                Text(section.displayName)
                                    .font(.system(size: 10, weight: state.currentSectionId == section.name ? .semibold : .regular))
                                    .foregroundStyle(state.currentSectionId == section.name
                                        ? Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255)
                                        : .secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(state.currentSectionId == section.name
                                        ? Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255).opacity(0.1)
                                        : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .background(.bar)
            }
        }
    }

    private func relativeTime(from date: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 5 { return "Just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    private func parseThemeTokens() {
        guard let html = try? String(contentsOfFile: previewPath, encoding: .utf8) else { return }
        let tokens = DesignTokens.extract(from: html)
        state.themeTokens = tokens.customProperties.map { prop in
            ThemeToken(name: prop.name, value: prop.value, originalValue: prop.value)
        }
        // Load design instructions from design-brief.md
        if case .project(let slug) = state.currentProject,
           let brief = loadDesignBrief(slug: slug) {
            // Extract instructions section from markdown
            if let range = brief.range(of: "## Design Instructions\n\n") {
                state.designInstructions = String(brief[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}

// MARK: - Assets Popover

struct SettingsPopover: View {
    @Bindable var state: AppState

    private let models = [
        ("sonnet", "Sonnet"),
        ("opus", "Opus"),
        ("haiku", "Haiku"),
    ]

    private let permissionModes = [
        ("acceptEdits", "Accept Edits"),
        ("bypassPermissions", "Bypass Permissions"),
        ("default", "Default"),
        ("plan", "Plan"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Model", selection: $state.claudeModel) {
                    ForEach(models, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Permission Mode")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Permission Mode", selection: $state.claudePermissionMode) {
                    ForEach(permissionModes, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                .labelsHidden()
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

struct AssetsPopover: View {
    @Bindable var state: AppState
    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Project Assets")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            if case .project(let slug) = state.currentProject {
                Picker("", selection: $selectedTab) {
                    Text("Images").tag(0)
                    Text("Components").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                if selectedTab == 0 {
                    assetsSection(slug: slug)
                } else {
                    componentsSection(slug: slug)
                }
            }
        }
        .padding(.bottom, 10)
        .frame(width: 280)
    }

    @ViewBuilder
    private func assetsSection(slug: String) -> some View {
        let assets = listAssets(for: slug)
        if assets.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                Text("No assets imported yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Drag images onto the preview\nor use the import button")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 72, maximum: 90), spacing: 8)
                ], spacing: 8) {
                    ForEach(assets, id: \.self) { filename in
                        let dir = assetsDir(for: slug)
                        let url = dir.appendingPathComponent(filename)
                        VStack(spacing: 4) {
                            if let nsImage = NSImage(contentsOf: url) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.quaternary)
                                    .frame(width: 64, height: 64)
                                    .overlay {
                                        Image(systemName: "photo")
                                            .foregroundStyle(.secondary)
                                    }
                            }
                            Text(filename)
                                .font(.system(size: 9))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 72)
                        }
                        .onTapGesture {
                            let path = "assets/\(filename)"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(path, forType: .string)
                            state.lastImportedAssetPath = path
                            state.showAssetImportConfirmation = true
                            state.showAssetsPopover = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                if state.lastImportedAssetPath == path {
                                    state.showAssetImportConfirmation = false
                                }
                            }
                        }
                        .help("Click to copy path: assets/\(filename)")
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(maxHeight: 300)
        }
    }

    @ViewBuilder
    private func componentsSection(slug: String) -> some View {
        let components = listComponents(for: slug)
        if components.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "curlybraces")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                Text("No components yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Use the element picker to\nextract components")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(components, id: \.self) { filename in
                        let dir = componentsDir(for: slug)
                        let url = dir.appendingPathComponent(filename)
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(filename)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Load") {
                                loadComponent(url: url)
                            }
                            .font(.system(size: 10))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(role: .destructive) {
                                try? FileManager.default.removeItem(at: url)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
    }

    private func loadComponent(url: URL) {
        guard let snippet = try? String(contentsOf: url, encoding: .utf8) else { return }
        // Wrap fragment in a full document if it's not already one
        let html: String
        if snippet.lowercased().contains("<html") || snippet.lowercased().contains("<!doctype") {
            html = snippet
        } else {
            html = """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"><style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { display: flex; align-items: center; justify-content: center;
                   min-height: 100vh; background: #1e1e1e; padding: 40px; }
            </style></head><body>
            \(snippet)
            </body></html>
            """
        }
        let previewURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ligma/preview.html")
        try? html.write(to: previewURL, atomically: true, encoding: .utf8)
        state.editingComponentPath = url
        state.showAssetsPopover = false
    }
}

// MARK: - Save Sheet

struct SaveSheet: View {
    let state: AppState
    @State private var name = ""
    @State private var project = ""
    @State private var existingProjects: [String] = []
    @State private var existingDesigns: [String] = [] // filenames like "login-form.html"
    @State private var selectedExisting: String? // filename to overwrite
    @State private var willOverwrite = false
    @State private var saveAsComponent = false
    @State private var shareGlobally = false
    @Environment(\.dismiss) private var dismiss

    private let libraryPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ligma/library")

    private var projectSlug: String? {
        let trimmed = project.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let slug = trimmed.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
        return slug.isEmpty ? nil : slug
    }

    private var destURL: URL? {
        guard let slug = projectSlug else { return nil }

        if saveAsComponent {
            if let existing = selectedExisting {
                return componentsDir(for: slug).appendingPathComponent(existing)
            }
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            guard !trimmedName.isEmpty else { return nil }
            let kebab = trimmedName.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "_", with: "-")
                .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
            guard !kebab.isEmpty else { return nil }
            return componentsDir(for: slug).appendingPathComponent("\(kebab).html")
        } else {
            if let existing = selectedExisting {
                return libraryPath.appendingPathComponent(slug).appendingPathComponent(existing)
            }
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            guard !trimmedName.isEmpty else { return nil }
            let kebab = trimmedName.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "_", with: "-")
                .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
            guard !kebab.isEmpty else { return nil }
            return libraryPath.appendingPathComponent(slug).appendingPathComponent("\(kebab).html")
        }
    }

    private var isUpdatingExisting: Bool { selectedExisting != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Save to Library")
                    .font(.headline)
                if state.isBrowsingHistory {
                    Text("Version \(state.currentVersionIndex + 1) of \(state.versions.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color(red: 255/255, green: 230/255, blue: 109/255).opacity(0.3))
                        )
                }
            }

            // Save type picker
            Picker("Save as", selection: $saveAsComponent) {
                Text("View").tag(false)
                Text("Component").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: saveAsComponent) { _, _ in
                selectedExisting = nil
                loadDesigns()
                checkOverwrite()
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Project", text: $project, prompt: Text("e.g. saas-app"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: project) { _, _ in
                        checkOverwrite()
                        loadDesigns()
                        selectedExisting = nil
                    }

                if !existingProjects.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(existingProjects, id: \.self) { proj in
                                Button(proj) { project = proj }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(project == proj
                                                  ? Color.accentColor.opacity(0.2)
                                                  : Color(nsColor: .controlBackgroundColor))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                    )
                                    .font(.system(size: 11))
                            }
                        }
                    }
                }
            }

            // Existing designs/components to update
            if !existingDesigns.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Update existing")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(existingDesigns, id: \.self) { file in
                                let displayName = file.replacingOccurrences(of: ".html", with: "")
                                    .replacingOccurrences(of: "-", with: " ")
                                    .capitalized
                                Button {
                                    if selectedExisting == file {
                                        selectedExisting = nil
                                    } else {
                                        selectedExisting = file
                                        name = ""
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: selectedExisting == file
                                              ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 11))
                                            .foregroundStyle(selectedExisting == file
                                                            ? Color.accentColor : Color.secondary)
                                        Text(displayName)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(selectedExisting == file
                                                  ? Color.accentColor.opacity(0.1)
                                                  : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
            }

            // New name field (hidden when updating existing)
            if !isUpdatingExisting {
                TextField("Name", text: $name, prompt: Text(saveAsComponent ? "e.g. Hero Button" : "e.g. Login Form"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, _ in checkOverwrite() }
            }

            if willOverwrite && !isUpdatingExisting {
                Label("A \(saveAsComponent ? "component" : "design") with this name already exists and will be replaced.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            // Share globally option (component mode only)
            if saveAsComponent {
                Toggle("Also share globally", isOn: $shareGlobally)
                    .font(.system(size: 12))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isUpdatingExisting ? "Update" : willOverwrite ? "Replace" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(destURL == nil)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            loadProjects()
            if case .project(let slug) = state.currentProject {
                project = state.currentProjectInfo?.displayName ?? slug
            }
            // If currently editing a component, default to component mode
            if state.editingComponentPath != nil {
                saveAsComponent = true
            }
            loadDesigns()
        }
    }

    private func checkOverwrite() {
        guard !isUpdatingExisting else { willOverwrite = false; return }
        guard let url = destURL else { willOverwrite = false; return }
        willOverwrite = FileManager.default.fileExists(atPath: url.path)
    }

    private func loadDesigns() {
        guard let slug = projectSlug else { existingDesigns = []; return }

        if saveAsComponent {
            existingDesigns = listComponents(for: slug)
        } else {
            let projectDir = libraryPath.appendingPathComponent(slug)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: projectDir.path) else {
                existingDesigns = []
                return
            }
            existingDesigns = files
                .filter { $0.hasSuffix(".html") }
                .sorted()
        }
    }

    private func loadProjects() {
        let fm = FileManager.default
        try? fm.createDirectory(at: libraryPath, withIntermediateDirectories: true)
        guard let contents = try? fm.contentsOfDirectory(atPath: libraryPath.path) else { return }
        var isDir: ObjCBool = false
        existingProjects = contents.filter {
            !$0.hasPrefix(".") && !$0.hasPrefix("_") &&
            fm.fileExists(
                atPath: libraryPath.appendingPathComponent($0).path,
                isDirectory: &isDir
            ) && isDir.boolValue
        }.sorted()
    }

    private func save() {
        guard let dest = destURL else { return }
        let fm = FileManager.default

        let parentDir = dest.deletingLastPathComponent()
        try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let html: String
        if state.isBrowsingHistory, state.currentVersionIndex < state.versions.count {
            html = (try? String(contentsOf: state.versions[state.currentVersionIndex], encoding: .utf8)) ?? ""
        } else {
            let previewURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("ligma/preview.html")
            html = (try? String(contentsOf: previewURL, encoding: .utf8)) ?? ""
        }

        do {
            try html.write(to: dest, atomically: true, encoding: .utf8)

            // Generate thumbnail from screenshot
            let screenshotURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("ligma/.preview-screenshot.png")
            if let srcImage = NSImage(contentsOf: screenshotURL) {
                let thumbSize = NSSize(width: 120, height: 80)
                let thumb = NSImage(size: thumbSize)
                thumb.lockFocus()
                srcImage.draw(in: NSRect(origin: .zero, size: thumbSize),
                              from: NSRect(origin: .zero, size: srcImage.size),
                              operation: .copy, fraction: 1.0)
                thumb.unlockFocus()
                if let tiff = thumb.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    let thumbName = dest.deletingPathExtension().lastPathComponent + ".thumb.png"
                    let thumbURL = dest.deletingLastPathComponent().appendingPathComponent(thumbName)
                    try? png.write(to: thumbURL)
                }
            }

            // Copy to global components if requested
            if saveAsComponent && shareGlobally {
                let globalDest = globalComponentsDir.appendingPathComponent(dest.lastPathComponent)
                try? fm.removeItem(at: globalDest) // overwrite if exists
                try? fm.copyItem(at: dest, to: globalDest)
                // Copy thumbnail too
                let thumbName = dest.deletingPathExtension().lastPathComponent + ".thumb.png"
                let srcThumb = dest.deletingLastPathComponent().appendingPathComponent(thumbName)
                let globalThumb = globalComponentsDir.appendingPathComponent(thumbName)
                try? fm.removeItem(at: globalThumb)
                try? fm.copyItem(at: srcThumb, to: globalThumb)
            }

            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            dismiss()
        } catch {
            NSSound.beep()
        }
    }
}

// MARK: - Component Naming Sheet

struct ComponentNamingSheet: View {
    @Bindable var state: AppState
    @State private var name = ""
    @State private var saveGlobally = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Component")
                .font(.headline)

            TextField("Name", text: $name, prompt: Text("e.g. Hero Button"))
                .textFieldStyle(.roundedBorder)

            Toggle("Also share globally", isOn: $saveGlobally)
                .font(.system(size: 12))

            HStack {
                Spacer()
                Button("Cancel") {
                    state.pendingComponentHTML = nil
                    state.pendingComponentTag = nil
                    state.pendingComponentPNG = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") { saveComponent() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            name = state.pendingComponentTag ?? "component"
        }
    }

    private func saveComponent() {
        guard case .project(let slug) = state.currentProject else { return }

        let kebab = name.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
        guard !kebab.isEmpty else { return }

        let compsURL = componentsDir(for: slug)

        // Save HTML
        if let html = state.pendingComponentHTML {
            let htmlPath = compsURL.appendingPathComponent("\(kebab).html")
            try? html.write(to: htmlPath, atomically: true, encoding: .utf8)

            if saveGlobally {
                let globalPath = globalComponentsDir.appendingPathComponent("\(kebab).html")
                try? html.write(to: globalPath, atomically: true, encoding: .utf8)
            }
        }

        // Save PNG as thumbnail and to assets
        if let png = state.pendingComponentPNG {
            let assetsURL = assetsDir(for: slug)
            let pngPath = assetsURL.appendingPathComponent("\(kebab).png")
            try? png.write(to: pngPath)

            // Also save as component thumbnail
            let thumbPath = compsURL.appendingPathComponent("\(kebab).thumb.png")
            try? png.write(to: thumbPath)

            if saveGlobally {
                let globalThumb = globalComponentsDir.appendingPathComponent("\(kebab).thumb.png")
                try? png.write(to: globalThumb)
            }

            // Copy path to clipboard
            let relativePath = "assets/\(kebab).png"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(relativePath, forType: .string)

            state.lastImportedAssetPath = relativePath
            state.showAssetImportConfirmation = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if state.lastImportedAssetPath == relativePath {
                    state.showAssetImportConfirmation = false
                }
            }
        }

        state.pendingComponentHTML = nil
        state.pendingComponentTag = nil
        state.pendingComponentPNG = nil
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        dismiss()
    }
}

// MARK: - Component Picker Popover

struct ComponentPickerPopover: View {
    weak var appState: AppState?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Attach Component")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if let appState {
                let slug: String? = {
                    if case .project(let s) = appState.currentProject { return s }
                    return nil
                }()
                let projectComps = slug.map { listComponents(for: $0) } ?? []
                let globalComps = listGlobalComponents()

                if projectComps.isEmpty && globalComps.isEmpty {
                    Text("No components available")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if let slug, !projectComps.isEmpty {
                                Text(slug.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 4)
                                ForEach(projectComps, id: \.self) { filename in
                                    componentPickerRow(
                                        filename: filename,
                                        dir: componentsDir(for: slug),
                                        appState: appState
                                    )
                                }
                            }
                            if !globalComps.isEmpty {
                                Text("SHARED")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 4)
                                ForEach(globalComps, id: \.self) { filename in
                                    componentPickerRow(
                                        filename: filename,
                                        dir: globalComponentsDir,
                                        appState: appState
                                    )
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 250)
                }
            }
        }
        .frame(width: 220)
    }

    @ViewBuilder
    private func componentPickerRow(filename: String, dir: URL, appState: AppState) -> some View {
        let displayName = filename.replacingOccurrences(of: ".html", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
        let isAttached = appState.attachedComponents.contains { $0.name == displayName }
        Button {
            if isAttached {
                appState.attachedComponents.removeAll { $0.name == displayName }
            } else {
                let url = dir.appendingPathComponent(filename)
                if let html = try? String(contentsOf: url, encoding: .utf8) {
                    appState.attachedComponents.append((name: displayName, html: html))
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isAttached ? "checkmark.circle.fill" : "curlybraces")
                    .font(.system(size: 11))
                    .foregroundStyle(isAttached ? Color.accentColor : .secondary)
                Text(displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Spec Sheet

enum SpecPlatform: String, CaseIterable {
    case web = "Web (HTML/CSS/JS)"
    case swiftuiIOS = "SwiftUI (iOS)"
    case swiftuiMacOS = "SwiftUI (macOS)"
    case reactNative = "React Native"
    case flutter = "Flutter"
}

// MARK: - Design Tokens

struct DesignTokens {
    // CSS custom properties (the actual theme definition)
    var customProperties: [(name: String, value: String)] = []

    // Colors grouped by role
    var backgroundColors: [String] = []
    var textColors: [String] = []
    var borderColors: [String] = []
    var otherColors: [String] = []

    // Typography
    var fonts: [String] = []
    var fontSizes: [String] = []

    // Spacing scale (individual values, sorted numerically)
    var spacingScale: [String] = []
    var radii: [String] = []

    // Effects
    var shadows: [String] = []
    var borders: [String] = []
    var transitions: [String] = []

    static func extract(from html: String) -> DesignTokens {
        var tokens = DesignTokens()

        // Extract <style> block content
        let stylePattern = try! NSRegularExpression(pattern: "<style[^>]*>([\\s\\S]*?)</style>", options: .caseInsensitive)
        let range = NSRange(html.startIndex..., in: html)
        var styleContent = ""
        stylePattern.enumerateMatches(in: html, range: range) { match, _, _ in
            if let r = match?.range(at: 1), let swiftRange = Range(r, in: html) {
                styleContent += String(html[swiftRange]) + "\n"
            }
        }

        func findMatches(_ pattern: String, in source: String, group: Int = 0) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
            let range = NSRange(source.startIndex..., in: source)
            var results: [String] = []
            regex.enumerateMatches(in: source, range: range) { match, _, _ in
                if let r = match?.range(at: group), let swiftRange = Range(r, in: source) {
                    results.append(String(source[swiftRange]))
                }
            }
            return results
        }

        // --- CSS Custom Properties ---
        // Match --name: value inside style blocks (typically in :root)
        let varPattern = "--([\\w-]+):\\s*([^;]+)"
        if let regex = try? NSRegularExpression(pattern: varPattern) {
            let r = NSRange(styleContent.startIndex..., in: styleContent)
            regex.enumerateMatches(in: styleContent, range: r) { match, _, _ in
                guard let nameRange = match?.range(at: 1), let nameSwift = Range(nameRange, in: styleContent),
                      let valRange = match?.range(at: 2), let valSwift = Range(valRange, in: styleContent) else { return }
                let name = String(styleContent[nameSwift])
                let value = String(styleContent[valSwift]).trimmingCharacters(in: .whitespaces)
                tokens.customProperties.append((name: name, value: value))
            }
        }
        // Deduplicate by name (keep last definition, which is the effective one)
        var seenVars: [String: Int] = [:]
        for (i, prop) in tokens.customProperties.enumerated() {
            seenVars[prop.name] = i
        }
        let uniqueIndices = Set(seenVars.values)
        tokens.customProperties = tokens.customProperties.enumerated()
            .filter { uniqueIndices.contains($0.offset) }
            .map { $0.element }

        // --- Color Roles ---
        var bgColors: Set<String> = []
        var txtColors: Set<String> = []
        var bdrColors: Set<String> = []
        var allColors: Set<String> = []

        let colorValue = "(?:#[0-9a-fA-F]{3,8}\\b|rgba?\\([^)]+\\)|var\\(--[\\w-]+\\))"

        // Background colors
        let bgPatterns = [
            "background-color:\\s*(\(colorValue))",
            "background:\\s*(\(colorValue))"
        ]
        for pat in bgPatterns {
            for c in findMatches(pat, in: styleContent, group: 1) {
                bgColors.insert(c.trimmingCharacters(in: .whitespaces))
            }
        }

        // Text colors (color: but not background-color: or border-color:)
        // Match "color:" preceded by start-of-line, semicolon, brace, or whitespace (not a hyphenated prefix)
        let textPat = "(?:^|[;{\\s])color:\\s*(\(colorValue))"
        for c in findMatches(textPat, in: styleContent, group: 1) {
            txtColors.insert(c.trimmingCharacters(in: .whitespaces))
        }

        // Border colors
        let bdrPatterns = [
            "border-color:\\s*(\(colorValue))",
            "border(?:-top|-right|-bottom|-left)?:\\s*[^;]*?(\\#[0-9a-fA-F]{3,8}\\b|rgba?\\([^)]+\\))"
        ]
        for pat in bdrPatterns {
            for c in findMatches(pat, in: styleContent, group: 1) {
                bdrColors.insert(c.trimmingCharacters(in: .whitespaces))
            }
        }

        // All colors (for the "other" bucket)
        let hexColors = findMatches("#[0-9a-fA-F]{3,8}\\b", in: styleContent)
        let rgbColors = findMatches("rgba?\\([^)]+\\)", in: styleContent)
        allColors = Set(hexColors + rgbColors)

        tokens.backgroundColors = bgColors.sorted()
        tokens.textColors = txtColors.sorted()
        tokens.borderColors = bdrColors.sorted()
        tokens.otherColors = allColors.subtracting(bgColors).subtracting(txtColors).subtracting(bdrColors).sorted()

        // --- Typography ---
        tokens.fonts = Array(Set(findMatches("font-family:\\s*([^;]+)", in: styleContent, group: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) })).sorted()

        let rawSizes = findMatches("font-size:\\s*([^;]+)", in: styleContent, group: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        tokens.fontSizes = sortNumerically(Array(Set(rawSizes)))

        // --- Spacing Scale ---
        let rawSpacing = findMatches("(?:padding|margin|gap)(?:-(?:top|right|bottom|left))?:\\s*([^;]+)", in: styleContent, group: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Decompose compound values into individual values
        var spacingAtoms: Set<String> = []
        for value in rawSpacing {
            let parts = value.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            for part in parts {
                // Must look like a length value (number + optional unit)
                if part.range(of: "^-?[\\d.]+", options: .regularExpression) != nil {
                    spacingAtoms.insert(part)
                }
            }
        }
        tokens.spacingScale = sortNumerically(Array(spacingAtoms))

        // Border radius
        let rawRadii = findMatches("border-radius:\\s*([^;]+)", in: styleContent, group: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        tokens.radii = sortNumerically(Array(Set(rawRadii)))

        // --- Effects ---
        tokens.shadows = Array(Set(findMatches("box-shadow:\\s*([^;]+)", in: styleContent, group: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) })).sorted()

        // Border shorthand (distinct from border-color)
        tokens.borders = Array(Set(findMatches("(?:^|[;{\\s])border:\\s*([^;]+)", in: styleContent, group: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) })).sorted()

        tokens.transitions = Array(Set(findMatches("transition:\\s*([^;]+)", in: styleContent, group: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) })).sorted()

        return tokens
    }

    /// Sort strings numerically by leading number, falling back to lexicographic
    private static func sortNumerically(_ values: [String]) -> [String] {
        values.sorted { a, b in
            let numA = Double(a.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)) ?? 0
            let numB = Double(b.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)) ?? 0
            if numA != numB { return numA < numB }
            return a < b
        }
    }
}

// MARK: - Asset Inventory

struct AssetInventory {
    var cdnScripts: [String] = []
    var cdnStyles: [String] = []
    var images: [String] = []
    var svgCount: Int = 0
    var cssUrls: [String] = []

    static func extract(from html: String) -> AssetInventory {
        var assets = AssetInventory()

        func findMatches(_ pattern: String, in source: String, group: Int = 0) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
            let range = NSRange(source.startIndex..., in: source)
            var results: [String] = []
            regex.enumerateMatches(in: source, range: range) { match, _, _ in
                if let r = match?.range(at: group), let swiftRange = Range(r, in: source) {
                    results.append(String(source[swiftRange]))
                }
            }
            return results
        }

        // External scripts: <script src="...">
        assets.cdnScripts = Array(Set(findMatches("<script[^>]+src=[\"']([^\"']+)[\"']", in: html, group: 1))).sorted()

        // External stylesheets: <link ... href="...">
        assets.cdnStyles = Array(Set(findMatches("<link[^>]+href=[\"']([^\"']+\\.css[^\"']*)[\"']", in: html, group: 1))).sorted()

        // Images: <img src="...">
        assets.images = Array(Set(findMatches("<img[^>]+src=[\"']([^\"']+)[\"']", in: html, group: 1))).sorted()

        // Inline SVGs
        let svgPattern = try! NSRegularExpression(pattern: "<svg[\\s>]", options: .caseInsensitive)
        assets.svgCount = svgPattern.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html))

        // CSS url() references (background images, etc.)
        assets.cssUrls = Array(Set(findMatches("url\\([\"']?([^)\"']+)[\"']?\\)", in: html, group: 1)
            .filter { !$0.hasPrefix("data:") })).sorted()

        return assets
    }

    var isEmpty: Bool {
        cdnScripts.isEmpty && cdnStyles.isEmpty && images.isEmpty && svgCount == 0 && cssUrls.isEmpty
    }
}

// MARK: - Component Info

struct ComponentInfo {
    let tag: String
    let id: String?
    let classes: String?
    let depth: Int

    var label: String {
        var s = tag
        if let id, !id.isEmpty { s += "#\(id)" }
        if let classes, !classes.isEmpty {
            s += "." + classes.replacingOccurrences(of: " ", with: ".")
        }
        return s
    }

    private static func extractAttribute(_ attr: String, from tag: String) -> String? {
        let pattern = "\(attr)=[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let r = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[r])
    }

    static func extract(from html: String) -> [ComponentInfo] {
        let semanticTags = Set(["nav", "header", "footer", "aside", "section", "form", "table", "dialog", "main", "article"])

        // Collect all tag events (open + close) with their positions
        struct TagEvent {
            let position: Int
            let tag: String
            let isOpen: Bool
            let isSemantic: Bool
            let id: String?
            let classes: String?
        }

        var events: [TagEvent] = []

        // Find opening semantic tags
        for tagName in semanticTags {
            let pattern = "<\(tagName)(\\s[^>]*)?"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let r = match?.range, let swiftRange = Range(r, in: html) else { return }
                let tagStr = String(html[swiftRange])
                events.append(TagEvent(
                    position: r.location, tag: tagName, isOpen: true, isSemantic: true,
                    id: extractAttribute("id", from: tagStr),
                    classes: extractAttribute("class", from: tagStr)
                ))
            }

            // Find closing semantic tags
            let closePattern = "</\(tagName)\\s*>"
            guard let closeRegex = try? NSRegularExpression(pattern: closePattern, options: .caseInsensitive) else { continue }
            closeRegex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let r = match?.range else { return }
                events.append(TagEvent(
                    position: r.location, tag: tagName, isOpen: false, isSemantic: true,
                    id: nil, classes: nil
                ))
            }
        }

        // Find id-bearing non-semantic elements (open only — treated as leaf nodes)
        let idPattern = "<([a-z][a-z0-9]*)\\s[^>]*id=[\"']([^\"']+)[\"'][^>]*"
        if let regex = try? NSRegularExpression(pattern: idPattern, options: .caseInsensitive) {
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let tagRange = match?.range(at: 1), let tagSwift = Range(tagRange, in: html),
                      let idRange = match?.range(at: 2), let idSwift = Range(idRange, in: html),
                      let fullRange = match?.range, let fullSwift = Range(fullRange, in: html) else { return }
                let tagName = String(html[tagSwift]).lowercased()
                if semanticTags.contains(tagName) { return }
                let fullStr = String(html[fullSwift])
                events.append(TagEvent(
                    position: fullRange.location, tag: tagName, isOpen: true, isSemantic: false,
                    id: String(html[idSwift]),
                    classes: extractAttribute("class", from: fullStr)
                ))
            }
        }

        // Sort by position, then closes before opens at same position
        events.sort { a, b in
            if a.position != b.position { return a.position < b.position }
            if !a.isOpen && b.isOpen { return true }
            return false
        }

        // Walk events, tracking depth via a stack of semantic tags
        var components: [ComponentInfo] = []
        var depth = 0

        for event in events {
            if event.isOpen {
                components.append(ComponentInfo(
                    tag: event.tag, id: event.id, classes: event.classes, depth: depth
                ))
                if event.isSemantic { depth += 1 }
            } else {
                depth = max(0, depth - 1)
            }
        }

        return components
    }
}

// MARK: - Chat History Serialization

func serializeChatHistory(_ messages: [ChatMessage]) -> String {
    var lines: [String] = []

    func summarizeToolUse(toolName: String, toolInput: String) -> String {
        if let data = toolInput.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let filePath = dict["file_path"] as? String ?? dict["path"] as? String {
                let name = (filePath as NSString).lastPathComponent
                switch toolName.lowercased() {
                case "write": return "Wrote \(name)"
                case "edit": return "Edited \(name)"
                case "read": return "Read \(name)"
                default: break
                }
            }
            if let command = dict["command"] as? String {
                let short = command.count > 60 ? String(command.prefix(60)) + "..." : command
                return "Ran: `\(short)`"
            }
            if let pattern = dict["pattern"] as? String {
                return "Searched for: \(pattern)"
            }
        }
        return "\(toolName)"
    }

    for message in messages {
        if message.role == .user {
            lines.append("\n### You\n")
            for block in message.blocks {
                if case .text(_, let text) = block {
                    let quoted = text.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
                    lines.append(quoted)
                }
            }
        } else {
            lines.append("\n### Assistant\n")
            for block in message.blocks {
                switch block {
                case .text(_, let text):
                    lines.append(text)
                case .toolUse(_, let toolName, let toolInput, _):
                    lines.append("_\(summarizeToolUse(toolName: toolName, toolInput: toolInput))_")
                case .toolResult(_, _, let content, let isError):
                    if isError {
                        lines.append("_Error: \(content.prefix(200))_")
                    }
                    // Skip success results
                case .componentRef(_, let names):
                    lines.append("_Attached components: \(names.joined(separator: ", "))_")
                }
            }
        }
    }

    return lines.joined(separator: "\n")
}

// MARK: - Spec Markdown Generator

func generateSpecMarkdown(
    name: String,
    userStory: String,
    platform: SpecPlatform,
    viewport: ViewportPreset,
    components: [ComponentInfo],
    tokens: DesignTokens,
    assets: AssetInventory,
    chatSummary: String
) -> String {
    var md = "# \(name)\n\n"

    if !userStory.isEmpty {
        md += "## User Story\n\n\(userStory)\n\n"
    }

    md += "## Platform\n\n\(platform.rawValue)\n\n"

    if let size = viewport.deviceSize {
        md += "## Viewport\n\n\(Int(size.width)) × \(Int(size.height)) (\(viewport.rawValue))\n\n"
    } else {
        md += "## Viewport\n\nResponsive (Auto)\n\n"
    }

    // --- Theme (CSS Custom Properties) ---
    if !tokens.customProperties.isEmpty {
        md += "## Theme\n\n"
        md += "```css\n"
        for prop in tokens.customProperties {
            md += "--\(prop.name): \(prop.value);\n"
        }
        md += "```\n\n"
    }

    // --- Component Tree ---
    if !components.isEmpty {
        md += "## Components\n\n"
        md += "```\n"
        for c in components {
            let indent = String(repeating: "  ", count: c.depth)
            md += "\(indent)\(c.label)\n"
        }
        md += "```\n\n"
        // Also a flat table for quick reference
        md += "| Tag | ID | Classes | Depth |\n"
        md += "|-----|----|---------|-------|\n"
        for c in components {
            md += "| `\(c.tag)` | \(c.id ?? "—") | \(c.classes ?? "—") | \(c.depth) |\n"
        }
        md += "\n"
    }

    // --- Design Tokens ---
    md += "## Design Tokens\n\n"

    // Color roles
    if !tokens.backgroundColors.isEmpty {
        md += "### Background Colors\n\n"
        for color in tokens.backgroundColors { md += "- `\(color)`\n" }
        md += "\n"
    }
    if !tokens.textColors.isEmpty {
        md += "### Text Colors\n\n"
        for color in tokens.textColors { md += "- `\(color)`\n" }
        md += "\n"
    }
    if !tokens.borderColors.isEmpty {
        md += "### Border Colors\n\n"
        for color in tokens.borderColors { md += "- `\(color)`\n" }
        md += "\n"
    }
    if !tokens.otherColors.isEmpty {
        md += "### Other Colors\n\n"
        for color in tokens.otherColors { md += "- `\(color)`\n" }
        md += "\n"
    }

    // Typography
    if !tokens.fonts.isEmpty {
        md += "### Fonts\n\n"
        for font in tokens.fonts { md += "- \(font)\n" }
        md += "\n"
    }
    if !tokens.fontSizes.isEmpty {
        md += "### Type Scale\n\n"
        md += tokens.fontSizes.map { "`\($0)`" }.joined(separator: " · ")
        md += "\n\n"
    }

    // Spacing & Layout
    if !tokens.spacingScale.isEmpty {
        md += "### Spacing Scale\n\n"
        md += tokens.spacingScale.map { "`\($0)`" }.joined(separator: " · ")
        md += "\n\n"
    }
    if !tokens.radii.isEmpty {
        md += "### Border Radius\n\n"
        md += tokens.radii.map { "`\($0)`" }.joined(separator: " · ")
        md += "\n\n"
    }

    // Effects
    if !tokens.shadows.isEmpty {
        md += "### Shadows\n\n"
        for s in tokens.shadows { md += "- `\(s)`\n" }
        md += "\n"
    }
    if !tokens.borders.isEmpty {
        md += "### Borders\n\n"
        for b in tokens.borders { md += "- `\(b)`\n" }
        md += "\n"
    }
    if !tokens.transitions.isEmpty {
        md += "### Transitions\n\n"
        for t in tokens.transitions { md += "- `\(t)`\n" }
        md += "\n"
    }

    // --- Assets ---
    if !assets.isEmpty {
        md += "## Assets\n\n"
        if !assets.cdnScripts.isEmpty {
            md += "### Scripts\n\n"
            for s in assets.cdnScripts { md += "- \(s)\n" }
            md += "\n"
        }
        if !assets.cdnStyles.isEmpty {
            md += "### Stylesheets\n\n"
            for s in assets.cdnStyles { md += "- \(s)\n" }
            md += "\n"
        }
        if !assets.images.isEmpty {
            md += "### Images\n\n"
            for img in assets.images { md += "- \(img)\n" }
            md += "\n"
        }
        if assets.svgCount > 0 {
            md += "### Inline SVGs\n\n\(assets.svgCount) inline SVG element\(assets.svgCount == 1 ? "" : "s")\n\n"
        }
        if !assets.cssUrls.isEmpty {
            md += "### CSS URLs\n\n"
            for u in assets.cssUrls { md += "- \(u)\n" }
            md += "\n"
        }
    }

    if !chatSummary.isEmpty {
        md += "## Design Conversation\n\n"
        md += "See `chat-history.md` for the full design conversation.\n\n"
    }

    md += "## Bundle Contents\n\n"
    md += "- `SPEC.md` — this file\n"
    md += "- `reference.html` — the original HTML mockup\n"
    md += "- `wireframe.png` — screenshot of the design\n"
    md += "- `chat-history.md` — design conversation log\n\n"

    md += "## Getting Started\n\n"
    md += "Copy-paste this into your build AI (Claude Code, Codex, etc.):\n\n"
    md += "```\n"
    md += "Read the spec bundle in specs/\(name)/ — SPEC.md has the design spec, "
    md += "reference.html is the HTML mockup, and wireframe.png shows the visual design. "
    md += "Implement this as a \(platform.rawValue) project, matching the layout and design tokens exactly.\n"
    md += "```\n"

    return md
}

// MARK: - New Spec Sheet

struct SpecSheet: View {
    let state: AppState
    let messages: [ChatMessage]
    @State private var name = ""
    @State private var project = ""
    @State private var userStory = ""
    @State private var platform: SpecPlatform = .web
    @State private var existingProjects: [String] = []
    @State private var willOverwrite = false
    @State private var exportedPath: String?
    @Environment(\.dismiss) private var dismiss

    private let libraryPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ligma/library")

    private var slug: String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
    }

    private var projectSlug: String {
        project.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
    }

    private var destDir: URL? {
        guard !slug.isEmpty, !projectSlug.isEmpty else { return nil }
        return libraryPath
            .appendingPathComponent(projectSlug)
            .appendingPathComponent("specs")
            .appendingPathComponent(slug)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Spec")
                .font(.headline)

            if let exportedPath {
                // Post-export state
                VStack(alignment: .leading, spacing: 8) {
                    Label("Spec exported", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 13, weight: .medium))

                    Text(exportedPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    HStack {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: exportedPath)
                        }
                        Spacer()
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                // Name field
                TextField("Name", text: $name, prompt: Text("e.g. dashboard-v2"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, _ in checkOverwrite() }

                // Project field with chips
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Project", text: $project, prompt: Text("e.g. saas-app"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: project) { _, _ in checkOverwrite() }

                    if !existingProjects.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(existingProjects, id: \.self) { proj in
                                    Button(proj) { project = proj }
                                        .buttonStyle(.plain)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(project == proj
                                                      ? Color.accentColor.opacity(0.2)
                                                      : Color(nsColor: .controlBackgroundColor))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                        )
                                        .font(.system(size: 11))
                                }
                            }
                        }
                    }
                }

                // User story
                VStack(alignment: .leading, spacing: 4) {
                    Text("User Story")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $userStory)
                        .font(.system(size: 12))
                        .frame(height: 80)
                        .overlay(
                            Group {
                                if userStory.isEmpty {
                                    Text("As a user, I want to...")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 8)
                                        .allowsHitTesting(false)
                                }
                            }, alignment: .topLeading
                        )
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                }

                // Platform picker
                Picker("Platform", selection: $platform) {
                    ForEach(SpecPlatform.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.radioGroup)

                if willOverwrite {
                    Label("A spec with this name already exists and will be replaced.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(willOverwrite ? "Replace" : "Export") { export() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(destDir == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            loadProjects()
            if case .project(let slug) = state.currentProject {
                project = state.currentProjectInfo?.displayName ?? slug
            }
        }
    }

    private func checkOverwrite() {
        guard let dir = destDir else { willOverwrite = false; return }
        willOverwrite = FileManager.default.fileExists(atPath: dir.appendingPathComponent("SPEC.md").path)
    }

    private func loadProjects() {
        let fm = FileManager.default
        try? fm.createDirectory(at: libraryPath, withIntermediateDirectories: true)
        guard let contents = try? fm.contentsOfDirectory(atPath: libraryPath.path) else { return }
        var isDir: ObjCBool = false
        existingProjects = contents.filter {
            !$0.hasPrefix(".") &&
            fm.fileExists(
                atPath: libraryPath.appendingPathComponent($0).path,
                isDirectory: &isDir
            ) && isDir.boolValue
        }.sorted()
    }

    private func export() {
        guard let dir = destDir else { return }
        let fm = FileManager.default

        // Create spec bundle directory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Get current HTML
        let html: String
        if state.isBrowsingHistory, state.currentVersionIndex < state.versions.count {
            html = (try? String(contentsOf: state.versions[state.currentVersionIndex], encoding: .utf8)) ?? ""
        } else {
            let previewURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("ligma/preview.html")
            html = (try? String(contentsOf: previewURL, encoding: .utf8)) ?? ""
        }

        // Write reference.html
        try? html.write(to: dir.appendingPathComponent("reference.html"), atomically: true, encoding: .utf8)

        // Copy wireframe screenshot
        let screenshotURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("ligma/.preview-screenshot.png")
        let wireframeURL = dir.appendingPathComponent("wireframe.png")
        try? fm.removeItem(at: wireframeURL)
        try? fm.copyItem(at: screenshotURL, to: wireframeURL)

        // Write chat history
        let chatMd = serializeChatHistory(messages)
        try? chatMd.write(to: dir.appendingPathComponent("chat-history.md"), atomically: true, encoding: .utf8)

        // Extract tokens, components, and assets, generate SPEC.md
        let tokens = DesignTokens.extract(from: html)
        let components = ComponentInfo.extract(from: html)
        let assets = AssetInventory.extract(from: html)
        let specMd = generateSpecMarkdown(
            name: slug,
            userStory: userStory,
            platform: platform,
            viewport: state.viewport,
            components: components,
            tokens: tokens,
            assets: assets,
            chatSummary: chatMd
        )
        try? specMd.write(to: dir.appendingPathComponent("SPEC.md"), atomically: true, encoding: .utf8)

        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        exportedPath = dir.path
    }
}

// MARK: - Projects Sidebar

struct ProjectsSidebar: View {
    @Bindable var state: AppState
    @State private var projects: [String] = []
    @State private var selectedProject: String?
    @State private var selectedMockup: String?
    @State private var selectedSpec: (project: String, name: String)?
    @State private var showDeleteConfirm = false
    @State private var showDeleteSpecConfirm = false
    @State private var showDeleteComponentConfirm = false
    @State private var renamingTag: String?
    @State private var renameText = ""
    @State private var thumbnailCache: [String: NSImage] = [:]
    @State private var renamingComponentTag: String?
    @State private var renameComponentText = ""

    private let libraryPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ligma/library")

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("LIBRARY")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            // Tab picker
            Picker("", selection: $state.sidebarTab) {
                Text("Views").tag(0)
                Text("Components").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if state.sidebarTab == 0 {
                viewsTab
            } else {
                componentsTab
            }

            // Spec detail panel
            if state.sidebarTab == 0, let spec = selectedSpec {
                Divider()
                SpecDetailView(
                    libraryPath: libraryPath,
                    project: spec.project,
                    specName: spec.name,
                    state: state
                )
            }
        }
        .onAppear { loadProjects() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            thumbnailCache.removeAll()
            loadProjects()
        }
    }

    // MARK: Views Tab

    @ViewBuilder
    private var viewsTab: some View {
        if projects.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.quaternary)
                Text("No saved designs yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Use \u{2318}\u{21E7}S to save\nyour first mockup")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(projects, id: \.self) { project in
                    Section {
                        // Source path badge for codebase projects
                        if let info = loadProjectInfo(slug: project), let src = info.sourcePath {
                            HStack(spacing: 4) {
                                Image(systemName: "link")
                                    .font(.system(size: 9))
                                Text(src.replacingOccurrences(
                                    of: FileManager.default.homeDirectoryForCurrentUser.path,
                                    with: "~"))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        }

                        // Designs
                        let items = mockupsFor(project: project)
                        ForEach(items, id: \.self) { mockup in
                            let tag = "\(project)/\(mockup)"
                            HStack(spacing: 8) {
                                if let thumb = thumbnailFor(project: project, mockup: mockup) {
                                    Image(nsImage: thumb)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 48, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                Text(displayName(for: mockup))
                                Spacer()
                                if selectedMockup == tag {
                                    Button {
                                        loadInPreview(project: project, mockup: mockup)
                                    } label: {
                                        Image(systemName: "arrow.right.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Load in Preview")
                                }
                            }
                            .tag(tag)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedMockup = tag
                                selectedSpec = nil
                            }
                            .onTapGesture(count: 2) {
                                loadInPreview(project: project, mockup: mockup)
                            }
                            .contextMenu {
                                Button("Load in Preview") {
                                    loadInPreview(project: project, mockup: mockup)
                                }
                                Divider()
                                Button("Rename...") {
                                    renamingTag = tag
                                    renameText = displayName(for: mockup)
                                }
                                Button("Delete...", role: .destructive) {
                                    selectedProject = project
                                    selectedMockup = tag
                                    showDeleteConfirm = true
                                }
                            }
                        }

                        // Specs subsection
                        let specs = specsFor(project: project)
                        if !specs.isEmpty {
                            Section("Specs") {
                                ForEach(specs, id: \.self) { specName in
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc.text")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                        Text(displayName(for: specName))
                                            .font(.system(size: 12))
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedSpec = (project: project, name: specName)
                                        selectedMockup = nil
                                    }
                                    .background(
                                        selectedSpec?.project == project && selectedSpec?.name == specName
                                            ? Color.accentColor.opacity(0.15)
                                            : Color.clear
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .contextMenu {
                                        Button("Load in Preview") {
                                            loadSpecInPreview(project: project, specName: specName)
                                        }
                                        Button("Reveal in Finder") {
                                            let specDir = libraryPath
                                                .appendingPathComponent(project)
                                                .appendingPathComponent("specs")
                                                .appendingPathComponent(specName)
                                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: specDir.path)
                                        }
                                        Divider()
                                        Button("Delete...", role: .destructive) {
                                            selectedSpec = (project: project, name: specName)
                                            showDeleteSpecConfirm = true
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(project)
                    }
                }
            }
            .listStyle(.sidebar)
            .alert("Delete Design", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { deleteMockup() }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let tag = selectedMockup {
                    let mockupFile = String(tag.split(separator: "/", maxSplits: 1).last ?? "")
                    Text("Delete \"\(displayName(for: mockupFile))\"?")
                }
            }
            .alert("Delete Spec", isPresented: $showDeleteSpecConfirm) {
                Button("Delete", role: .destructive) { deleteSpec() }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let spec = selectedSpec {
                    Text("Delete spec \"\(displayName(for: spec.name))\"?")
                }
            }
            .sheet(item: $renamingTag) { tag in
                RenameSheet(
                    currentName: renameText,
                    onRename: { newName in
                        renameMockup(tag: tag, newName: newName)
                    }
                )
            }
        }
    }

    // MARK: Components Tab

    @ViewBuilder
    private var componentsTab: some View {
        let projectsWithComps = projectsWithComponents()
        let globalComps = listGlobalComponents()

        if projectsWithComps.isEmpty && globalComps.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "curlybraces")
                    .font(.system(size: 28))
                    .foregroundStyle(.quaternary)
                Text("No components yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Use the element picker or\nsave as component")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            componentsListView(projectsWithComps: projectsWithComps, globalComps: globalComps)
        }
    }

    private func componentsListView(projectsWithComps: [String], globalComps: [String]) -> some View {
        List {
            // Per-project component sections
            ForEach(projectsWithComps, id: \.self) { project in
                Section {
                    let comps = listComponents(for: project)
                    ForEach(comps, id: \.self) { filename in
                        componentRow(filename: filename, project: project, isGlobal: false)
                    }
                } header: {
                    Text(project)
                }
            }

            // Shared / global components
            if !globalComps.isEmpty {
                Section {
                    ForEach(globalComps, id: \.self) { filename in
                        componentRow(filename: filename, project: "_components", isGlobal: true)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 9))
                        Text("Shared")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .alert("Delete Component", isPresented: $showDeleteComponentConfirm) {
            Button("Delete", role: .destructive) { deleteComponent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let tag = state.selectedComponent {
                let name = String(tag.split(separator: "/", maxSplits: 1).last ?? "")
                Text("Delete \"\(displayName(for: name))\"?")
            }
        }
        .sheet(item: $renamingComponentTag) { tag in
            RenameSheet(
                currentName: renameComponentText,
                onRename: { newName in
                    renameComponent(tag: tag, newName: newName)
                }
            )
        }
    }

    @ViewBuilder
    private func componentRow(filename: String, project: String, isGlobal: Bool) -> some View {
        let tag = "\(project)/\(filename)"
        let dir = isGlobal ? globalComponentsDir : componentsDir(for: project)
        let thumbName = filename.replacingOccurrences(of: ".html", with: ".thumb.png")
        let thumbURL = dir.appendingPathComponent(thumbName)
        HStack(spacing: 8) {
            if let thumb = NSImage(contentsOf: thumbURL) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 28)
            }
            Text(displayName(for: filename))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if state.selectedComponent == tag {
                Button {
                    loadComponentInPreview(dir: dir, filename: filename)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255))
                }
                .buttonStyle(.plain)
                .help("Load in Preview")
            }
        }
        .tag(tag)
        .contentShape(Rectangle())
        .onTapGesture {
            state.selectedComponent = tag
        }
        .onTapGesture(count: 2) {
            loadComponentInPreview(dir: dir, filename: filename)
        }
        .contextMenu {
            Button("Load in Preview") {
                loadComponentInPreview(dir: dir, filename: filename)
            }
            Button("Attach to Chat") {
                attachComponent(dir: dir, filename: filename)
            }
            Divider()
            if isGlobal {
                if case .project(let slug) = state.currentProject {
                    Button("Copy to Project") {
                        copyComponentToProject(from: dir, filename: filename, projectSlug: slug)
                    }
                }
            } else {
                Button("Share Globally") {
                    copyComponentToGlobal(from: dir, filename: filename)
                }
            }
            Button("Rename...") {
                renamingComponentTag = tag
                renameComponentText = displayName(for: filename)
            }
            Divider()
            Button("Delete...", role: .destructive) {
                state.selectedComponent = tag
                showDeleteComponentConfirm = true
            }
        }
    }

    // MARK: Helpers

    private func loadProjects() {
        let fm = FileManager.default
        try? fm.createDirectory(at: libraryPath, withIntermediateDirectories: true)
        guard let contents = try? fm.contentsOfDirectory(atPath: libraryPath.path) else { return }
        var isDir: ObjCBool = false
        projects = contents.filter {
            !$0.hasPrefix(".") && !$0.hasPrefix("_") &&
            fm.fileExists(
                atPath: libraryPath.appendingPathComponent($0).path,
                isDirectory: &isDir
            ) && isDir.boolValue
        }.sorted()
    }

    private func mockupsFor(project: String) -> [String] {
        let dir = libraryPath.appendingPathComponent(project)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files.filter { $0.hasSuffix(".html") }.sorted()
    }

    private func specsFor(project: String) -> [String] {
        let specsDir = libraryPath.appendingPathComponent(project).appendingPathComponent("specs")
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: specsDir.path) else { return [] }
        var isDir: ObjCBool = false
        return dirs.filter { name in
            !name.hasPrefix(".") &&
            fm.fileExists(atPath: specsDir.appendingPathComponent(name).path, isDirectory: &isDir) &&
            isDir.boolValue &&
            fm.fileExists(atPath: specsDir.appendingPathComponent(name).appendingPathComponent("SPEC.md").path)
        }.sorted()
    }

    private func thumbnailFor(project: String, mockup: String) -> NSImage? {
        let key = "\(project)/\(mockup)"
        if let cached = thumbnailCache[key] { return cached }
        let thumbName = mockup.replacingOccurrences(of: ".html", with: ".thumb.png")
        let thumbURL = libraryPath.appendingPathComponent(project).appendingPathComponent(thumbName)
        guard let image = NSImage(contentsOf: thumbURL) else { return nil }
        thumbnailCache[key] = image
        return image
    }

    private func displayName(for filename: String) -> String {
        filename.replacingOccurrences(of: ".html", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private func loadInPreview(project: String, mockup: String) {
        let url = libraryPath.appendingPathComponent(project).appendingPathComponent(mockup)
        guard let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        let previewURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ligma/preview.html")
        try? html.write(to: previewURL, atomically: true, encoding: .utf8)
        state.showPreview = true
    }

    private func loadSpecInPreview(project: String, specName: String) {
        let refURL = libraryPath
            .appendingPathComponent(project)
            .appendingPathComponent("specs")
            .appendingPathComponent(specName)
            .appendingPathComponent("reference.html")
        guard let html = try? String(contentsOf: refURL, encoding: .utf8) else { return }
        let previewURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ligma/preview.html")
        try? html.write(to: previewURL, atomically: true, encoding: .utf8)
        state.showPreview = true
    }

    private func loadComponentInPreview(dir: URL, filename: String) {
        let url = dir.appendingPathComponent(filename)
        guard let snippet = try? String(contentsOf: url, encoding: .utf8) else { return }
        let html: String
        if snippet.lowercased().contains("<html") || snippet.lowercased().contains("<!doctype") {
            html = snippet
        } else {
            html = """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"><style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { display: flex; align-items: center; justify-content: center;
                   min-height: 100vh; background: #1e1e1e; padding: 40px; }
            </style></head><body>
            \(snippet)
            </body></html>
            """
        }
        let previewURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ligma/preview.html")
        try? html.write(to: previewURL, atomically: true, encoding: .utf8)
        state.editingComponentPath = url
        state.showPreview = true
    }

    private func attachComponent(dir: URL, filename: String) {
        let url = dir.appendingPathComponent(filename)
        guard let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        let name = displayName(for: filename)
        // Avoid duplicates
        if !state.attachedComponents.contains(where: { $0.name == name }) {
            state.attachedComponents.append((name: name, html: html))
        }
    }

    private func copyComponentToProject(from dir: URL, filename: String, projectSlug: String) {
        let src = dir.appendingPathComponent(filename)
        let dest = componentsDir(for: projectSlug).appendingPathComponent(filename)
        try? FileManager.default.copyItem(at: src, to: dest)
        // Copy thumbnail too
        let thumbName = filename.replacingOccurrences(of: ".html", with: ".thumb.png")
        let srcThumb = dir.appendingPathComponent(thumbName)
        let destThumb = componentsDir(for: projectSlug).appendingPathComponent(thumbName)
        try? FileManager.default.copyItem(at: srcThumb, to: destThumb)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    private func copyComponentToGlobal(from dir: URL, filename: String) {
        let src = dir.appendingPathComponent(filename)
        let dest = globalComponentsDir.appendingPathComponent(filename)
        try? FileManager.default.copyItem(at: src, to: dest)
        let thumbName = filename.replacingOccurrences(of: ".html", with: ".thumb.png")
        let srcThumb = dir.appendingPathComponent(thumbName)
        let destThumb = globalComponentsDir.appendingPathComponent(thumbName)
        try? FileManager.default.copyItem(at: srcThumb, to: destThumb)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    private func renameComponent(tag: String, newName: String) {
        let parts = tag.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return }
        let project = String(parts[0])
        let oldFilename = String(parts[1])
        let dir = project == "_components" ? globalComponentsDir : componentsDir(for: project)
        let oldURL = dir.appendingPathComponent(oldFilename)

        let kebab = newName.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
        guard !kebab.isEmpty else { return }
        let newURL = dir.appendingPathComponent("\(kebab).html")

        guard oldURL != newURL else { return }
        try? FileManager.default.moveItem(at: oldURL, to: newURL)

        let oldThumbName = oldFilename.replacingOccurrences(of: ".html", with: ".thumb.png")
        let newThumbName = "\(kebab).thumb.png"
        try? FileManager.default.moveItem(
            at: dir.appendingPathComponent(oldThumbName),
            to: dir.appendingPathComponent(newThumbName)
        )

        state.selectedComponent = nil
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    private func deleteComponent() {
        guard let tag = state.selectedComponent else { return }
        let parts = tag.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return }
        let project = String(parts[0])
        let filename = String(parts[1])
        let dir = project == "_components" ? globalComponentsDir : componentsDir(for: project)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(filename))
        let thumbName = filename.replacingOccurrences(of: ".html", with: ".thumb.png")
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(thumbName))
        state.selectedComponent = nil
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    private func renameMockup(tag: String, newName: String) {
        let parts = tag.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return }
        let project = String(parts[0])
        let oldMockup = String(parts[1])
        let projectDir = libraryPath.appendingPathComponent(project)
        let oldURL = projectDir.appendingPathComponent(oldMockup)

        let kebab = newName.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
        guard !kebab.isEmpty else { return }
        let newURL = projectDir.appendingPathComponent("\(kebab).html")

        guard oldURL != newURL else { return }
        try? FileManager.default.moveItem(at: oldURL, to: newURL)

        // Move thumbnail alongside HTML
        let oldThumbName = oldMockup.replacingOccurrences(of: ".html", with: ".thumb.png")
        let newThumbName = "\(kebab).thumb.png"
        let oldThumbURL = projectDir.appendingPathComponent(oldThumbName)
        let newThumbURL = projectDir.appendingPathComponent(newThumbName)
        try? FileManager.default.moveItem(at: oldThumbURL, to: newThumbURL)

        selectedMockup = nil
        loadProjects()
    }

    private func deleteMockup() {
        guard let tag = selectedMockup else { return }
        let parts = tag.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return }
        let project = String(parts[0])
        let mockup = String(parts[1])
        let projectDir = libraryPath.appendingPathComponent(project)
        let url = projectDir.appendingPathComponent(mockup)
        try? FileManager.default.removeItem(at: url)

        // Delete associated thumbnail
        let thumbName = mockup.replacingOccurrences(of: ".html", with: ".thumb.png")
        try? FileManager.default.removeItem(at: projectDir.appendingPathComponent(thumbName))

        selectedMockup = nil

        // Remove project directory if only hidden files or specs remain
        if let remaining = try? FileManager.default.contentsOfDirectory(atPath: projectDir.path),
           remaining.allSatisfy({ $0.hasPrefix(".") || $0 == "specs" }) {
            // Check if specs dir is also empty
            let specsDir = projectDir.appendingPathComponent("specs")
            let specContents = (try? FileManager.default.contentsOfDirectory(atPath: specsDir.path)) ?? []
            if specContents.isEmpty || remaining.allSatisfy({ $0.hasPrefix(".") }) {
                try? FileManager.default.removeItem(at: projectDir)
            }
        }
        loadProjects()
    }

    private func deleteSpec() {
        guard let spec = selectedSpec else { return }
        let specDir = libraryPath
            .appendingPathComponent(spec.project)
            .appendingPathComponent("specs")
            .appendingPathComponent(spec.name)
        try? FileManager.default.removeItem(at: specDir)
        selectedSpec = nil
        loadProjects()
    }
}

// MARK: - Spec Detail View

struct SpecDetailView: View {
    let libraryPath: URL
    let project: String
    let specName: String
    let state: AppState

    @State private var userStory = ""
    @State private var platformBadge = ""
    @State private var themeVars: [(name: String, value: String)] = []
    @State private var components: [(label: String, depth: Int)] = []
    @State private var bgColors: [String] = []
    @State private var textColors: [String] = []
    @State private var borderColorsList: [String] = []
    @State private var otherColorsList: [String] = []
    @State private var fonts: [String] = []
    @State private var spacingScale: [String] = []
    @State private var shadows: [String] = []
    @State private var assets: [String] = []

    private var specDir: URL {
        libraryPath
            .appendingPathComponent(project)
            .appendingPathComponent("specs")
            .appendingPathComponent(specName)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(specName.replacingOccurrences(of: "-", with: " ").capitalized)
                    .font(.system(size: 13, weight: .semibold))

                if !platformBadge.isEmpty {
                    Text(platformBadge)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }

                if !userStory.isEmpty {
                    Text(userStory)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                // Theme variables
                if !themeVars.isEmpty {
                    sectionHeader("Theme")
                    ForEach(Array(themeVars.enumerated()), id: \.offset) { _, v in
                        HStack(spacing: 6) {
                            // Show color swatch if value looks like a color
                            if v.value.hasPrefix("#") || v.value.hasPrefix("rgb") {
                                Circle()
                                    .fill(Color(nsColor: NSColor(hex: v.value)))
                                    .frame(width: 10, height: 10)
                                    .overlay(Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                            }
                            Text("--\(v.name)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                            Text(v.value)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Component tree
                if !components.isEmpty {
                    sectionHeader("Components")
                    ForEach(Array(components.enumerated()), id: \.offset) { _, comp in
                        Text(comp.label)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.leading, CGFloat(comp.depth) * 12)
                    }
                }

                // Colors by role
                colorSwatchRow("Background", colors: bgColors)
                colorSwatchRow("Text", colors: textColors)
                colorSwatchRow("Borders", colors: borderColorsList)
                colorSwatchRow("Other", colors: otherColorsList)

                if !fonts.isEmpty {
                    sectionHeader("Fonts")
                    ForEach(fonts, id: \.self) { font in
                        Text(font)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                if !spacingScale.isEmpty {
                    sectionHeader("Spacing")
                    Text(spacingScale.joined(separator: " · "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if !shadows.isEmpty {
                    sectionHeader("Shadows")
                    ForEach(shadows, id: \.self) { s in
                        Text(s)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if !assets.isEmpty {
                    sectionHeader("Assets")
                    ForEach(assets, id: \.self) { a in
                        Text(a)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                // Actions
                HStack(spacing: 8) {
                    Button("Load in Preview") {
                        let refURL = specDir.appendingPathComponent("reference.html")
                        guard let html = try? String(contentsOf: refURL, encoding: .utf8) else { return }
                        let previewURL = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("ligma/preview.html")
                        try? html.write(to: previewURL, atomically: true, encoding: .utf8)
                        state.showPreview = true
                    }
                    .font(.system(size: 11))

                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: specDir.path)
                    }
                    .font(.system(size: 11))
                }
                .padding(.top, 4)
            }
            .padding(12)
        }
        .frame(maxHeight: 300)
        .onAppear { parseSpec() }
        .onChange(of: specName) { _, _ in parseSpec() }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .heavy))
            .tracking(1)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func colorSwatchRow(_ label: String, colors: [String]) -> some View {
        if !colors.isEmpty {
            sectionHeader(label)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(colors, id: \.self) { color in
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: color)))
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                            .help(color)
                    }
                }
            }
        }
    }

    private func parseSpec() {
        let specURL = specDir.appendingPathComponent("SPEC.md")
        guard let content = try? String(contentsOf: specURL, encoding: .utf8) else { return }

        let sections = parseSections(content)

        userStory = sections["User Story"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        platformBadge = sections["Platform"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Parse theme (CSS custom properties from code block)
        if let themeSection = sections["Theme"] {
            themeVars = themeSection.components(separatedBy: "\n")
                .filter { $0.contains(":") && $0.hasPrefix("--") }
                .compactMap { line in
                    let cleaned = line.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: ";", with: "")
                    let parts = cleaned.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "--", with: "")
                    let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    return (name: name, value: value)
                }
        }

        // Parse component tree (from code block)
        if let compSection = sections["Components"] {
            // Extract lines from the code block (indented tree)
            let codeBlockLines = compSection.components(separatedBy: "\n")
                .drop(while: { !$0.contains("```") })
                .dropFirst()
                .prefix(while: { !$0.contains("```") })

            components = codeBlockLines.compactMap { line in
                let trimmed = line.replacingOccurrences(of: "  ", with: "\t")
                let depth = trimmed.prefix(while: { $0 == "\t" }).count
                let label = line.trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty else { return nil }
                return (label: label, depth: depth)
            }
        }

        // Parse design tokens section
        if let tokensSection = sections["Design Tokens"] {
            bgColors = extractSubsectionItems(tokensSection, header: "### Background Colors")
            textColors = extractSubsectionItems(tokensSection, header: "### Text Colors")
            borderColorsList = extractSubsectionItems(tokensSection, header: "### Border Colors")
            otherColorsList = extractSubsectionItems(tokensSection, header: "### Other Colors")

            fonts = extractSubsectionItems(tokensSection, header: "### Fonts")

            // Spacing/type scales are inline (backtick·separated)
            spacingScale = extractInlineScale(tokensSection, header: "### Spacing Scale")
            shadows = extractSubsectionItems(tokensSection, header: "### Shadows")
        }

        // Parse assets section
        if let assetsSection = sections["Assets"] {
            assets = assetsSection.components(separatedBy: "\n")
                .filter { $0.hasPrefix("- ") }
                .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
    }

    private func extractSubsectionItems(_ section: String, header: String) -> [String] {
        guard let start = section.range(of: header) else { return [] }
        let after = String(section[start.upperBound...])
        let end = after.range(of: "###")?.lowerBound ?? after.endIndex
        return String(after[after.startIndex..<end])
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "`", with: "") }
    }

    private func extractInlineScale(_ section: String, header: String) -> [String] {
        guard let start = section.range(of: header) else { return [] }
        let after = String(section[start.upperBound...])
        let end = after.range(of: "###")?.lowerBound ?? after.endIndex
        let line = String(after[after.startIndex..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return [] }
        return line.components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "`", with: "") }
            .filter { !$0.isEmpty }
    }

    private func parseSections(_ content: String) -> [String: String] {
        var sections: [String: String] = [:]
        let lines = content.components(separatedBy: "\n")
        var currentKey = ""
        var currentContent: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if !currentKey.isEmpty {
                    sections[currentKey] = currentContent.joined(separator: "\n")
                }
                currentKey = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentContent = []
            } else if !currentKey.isEmpty {
                currentContent.append(line)
            }
        }
        if !currentKey.isEmpty {
            sections[currentKey] = currentContent.joined(separator: "\n")
        }
        return sections
    }
}

// MARK: - NSColor hex helper

extension NSColor {
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        if h.count == 3 {
            h = h.map { "\($0)\($0)" }.joined()
        }
        guard h.count >= 6 else {
            self.init(white: 0.5, alpha: 1.0)
            return
        }
        var rgb: UInt64 = 0
        Scanner(string: String(h.prefix(6))).scanHexInt64(&rgb)
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

// MARK: - Rename Sheet

extension String: @retroactive Identifiable {
    public var id: String { self }
}

struct RenameSheet: View {
    let currentName: String
    let onRename: (String) -> Void
    @State private var name: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Design")
                .font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    onRename(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear { name = currentName }
    }
}

// MARK: - Apply Sheet

struct ApplySheet: View {
    @Bindable var state: AppState
    let chatVM: ChatViewModel
    @State private var branchName: String
    @State private var step: ApplyStep = .preview
    @Environment(\.dismiss) private var dismiss

    private let teal = Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255)

    enum ApplyStep { case preview, applying, done }

    init(state: AppState, chatVM: ChatViewModel) {
        self.state = state
        self.chatVM = chatVM
        let dateStr = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        _branchName = State(initialValue: "ligma/design-update-\(dateStr)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apply to Project")
                .font(.headline)

            switch step {
            case .preview:
                if let info = state.currentProjectInfo, let src = info.sourcePath {
                    Text("These design changes will be applied to:")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Label(src.replacingOccurrences(
                        of: FileManager.default.homeDirectoryForCurrentUser.path,
                        with: "~"), systemImage: "folder")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    // Changed tokens summary
                    let dirty = state.themeTokens.filter { $0.isDirty }
                    if !dirty.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Changed theme tokens:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            ForEach(dirty) { token in
                                HStack(spacing: 4) {
                                    Text("--\(token.name)")
                                        .font(.system(size: 10, design: .monospaced))
                                    Text("\(token.originalValue) → \(token.value)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    TextField("Branch name", text: $branchName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    HStack {
                        Spacer()
                        Button("Cancel") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Button("Apply Changes") {
                            step = .applying
                            let changes = dirty.map { "--\($0.name): \($0.originalValue) → \($0.value)" }
                                .joined(separator: "\n")
                            chatVM.applyToProject(
                                branchName: branchName,
                                sourcePath: src,
                                changes: changes.isEmpty ? "Visual/layout changes from the mockup" : changes
                            )
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }

            case .applying:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Applying changes...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

            case .done:
                Label("Changes applied to branch `\(branchName)`",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                HStack(spacing: 8) {
                    if let src = state.currentProjectInfo?.sourcePath {
                        Button("Open in Terminal") {
                            let script = "cd \"\(src)\" && git diff"
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(script, forType: .string)
                        }

                        Button("Open in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: src)
                        }
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Chat Data Models

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    var blocks: [ContentBlock]

    enum MessageRole { case user, assistant }
}

enum ContentBlock: Identifiable {
    case text(id: UUID = UUID(), text: String)
    case toolUse(id: UUID = UUID(), toolName: String, toolInput: String, toolUseId: String)
    case toolResult(id: UUID = UUID(), toolUseId: String, content: String, isError: Bool)
    case componentRef(id: UUID = UUID(), names: [String])

    var id: UUID {
        switch self {
        case .text(let id, _): return id
        case .toolUse(let id, _, _, _): return id
        case .toolResult(let id, _, _, _): return id
        case .componentRef(let id, _): return id
        }
    }
}

enum ConversationState: Equatable {
    case idle, launching, streaming, toolRunning(String), error(String)
}

// MARK: - Chat View Model

@MainActor @Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var inputText = ""
    var state: ConversationState = .idle
    var sessionId: String?
    var modelName: String?
    var totalCost: Double?
    weak var appState: AppState?

    // Image attachment
    var attachedImage: NSImage?
    var attachedImagePath: String?

    private var currentProcess: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    @ObservationIgnored var _shouldShowResumePrompt = false

    private let claudePath: String = {
        // Try `which` via the user's login shell to get the real PATH
        let shells = ["/bin/zsh", "/bin/bash"]
        for shell in shells {
            let pipe = Pipe()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: shell)
            proc.arguments = ["-lc", "which claude"]
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            proc.standardInput = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty,
                   FileManager.default.fileExists(atPath: path) {
                    return path
                }
            } catch {}
        }
        // Check well-known locations
        let knownPaths = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/claude").path,
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        for path in knownPaths {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "/usr/local/bin/claude"
    }()
    private let workingDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ligma").path

    private func saveAnnotatedScreenshotSync() {
        let base = URL(fileURLWithPath: workingDir)
        let cleanURL = base.appendingPathComponent(".preview-screenshot.png")
        let annotatedURL = base.appendingPathComponent(".preview-screenshot-annotated.png")

        guard let annotations = appState?.annotations, !annotations.isEmpty else {
            // No sketches — remove stale annotated file
            try? FileManager.default.removeItem(at: annotatedURL)
            return
        }

        guard let cleanImage = NSImage(contentsOf: cleanURL) else { return }
        let annotated = PreviewWebView.Coordinator.compositeSketch(onto: cleanImage, annotations: annotations)
        guard let tiff = annotated.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: annotatedURL)
    }

    // Accumulators for streaming
    private var pendingTextBlockId: UUID?
    private var pendingToolName: String?
    private var pendingToolInput: String = ""
    private var pendingToolUseId: String?

    private var projectContext: ProjectContext = .none

    private var sessionStatePath: String {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ligma")
        switch projectContext {
        case .project(let slug):
            return base.appendingPathComponent("library/\(slug)/.session-state.json").path
        case .scratch, .none:
            return base.appendingPathComponent(".session-state.json").path
        }
    }

    var versionsDir: String {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ligma")
        switch projectContext {
        case .project(let slug):
            return base.appendingPathComponent("library/\(slug)/.versions").path
        case .scratch, .none:
            return base.appendingPathComponent(".versions").path
        }
    }

    private func saveSessionState() {
        guard let sid = sessionId else { return }
        let dict: [String: String] = [
            "sessionId": sid,
            "modelName": modelName ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: URL(fileURLWithPath: sessionStatePath))
        }
    }

    private func deleteSessionState() {
        try? FileManager.default.removeItem(atPath: sessionStatePath)
    }

    func resumePreviousSession() {
        // Load saved session state
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sessionStatePath)),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            startFresh()
            return
        }
        sessionId = dict["sessionId"]
        modelName = dict["modelName"]
    }

    func startFresh() {
        deleteSessionState()
        NotificationCenter.default.post(name: .clearSession, object: nil)
    }

    init() {
        // Defer session logic to configure(for:)
    }

    /// Configure for a project context. Called when entering the workspace.
    func configure(for context: ProjectContext) {
        projectContext = context

        let base = URL(fileURLWithPath: workingDir)
        let previewFile = base.appendingPathComponent("preview.html")
        let hasSession = FileManager.default.fileExists(atPath: sessionStatePath)

        if hasSession {
            // Restore preview.html from this project's latest version snapshot
            // (preview.html is shared and may contain stale content from another project)
            let versDir = URL(fileURLWithPath: versionsDir)
            if let files = try? FileManager.default.contentsOfDirectory(atPath: versDir.path),
               let lastVersion = files.filter({ $0.hasSuffix(".html") })
                   .sorted(by: { a, b in
                       (Int(a.replacingOccurrences(of: ".html", with: "")) ?? 0) <
                       (Int(b.replacingOccurrences(of: ".html", with: "")) ?? 0)
                   }).last,
               let html = try? String(contentsOf: versDir.appendingPathComponent(lastVersion), encoding: .utf8) {
                try? html.write(to: previewFile, atomically: true, encoding: .utf8)
                self._shouldShowResumePrompt = true
            } else {
                // Session exists but no versions — clear stale preview
                if let fh = FileHandle(forWritingAtPath: previewFile.path) {
                    fh.truncateFile(atOffset: 0)
                    fh.closeFile()
                }
            }
        } else if !hasSession {
            // Clean slate for this context — skip if starter preview was just written
            if let skip = appState?.skipInitialPreviewClear, skip {
                appState?.skipInitialPreviewClear = false
            } else if let fh = FileHandle(forWritingAtPath: previewFile.path) {
                fh.truncateFile(atOffset: 0)
                fh.closeFile()
            }
            let versDir = URL(fileURLWithPath: versionsDir)
            if let files = try? FileManager.default.contentsOfDirectory(atPath: versDir.path) {
                for file in files where file.hasSuffix(".html") {
                    try? FileManager.default.removeItem(at: versDir.appendingPathComponent(file))
                }
            }
            try? FileManager.default.removeItem(at: base.appendingPathComponent(".preview-screenshot-annotated.png"))
        }
    }

    /// Send extraction prompt for codebase projects
    func sendExtractionPrompt(sourcePath: String) {
        let prompt = """
        Analyze the source code at \(sourcePath). Generate a complete HTML mockup in \
        preview.html that faithfully reproduces each screen/view in the application. \
        Use <section id="page-name"> with client-side routing for each screen. \
        Match the real design system — colors, typography, spacing, component styles. \
        Use realistic data from the actual app domain.
        """
        sendMessage(prompt)
    }

    /// Send apply-to-project prompt
    func applyToProject(branchName: String, sourcePath: String, changes: String) {
        let prompt = """
        Create a new git branch "\(branchName)" in \(sourcePath) and apply the \
        following design changes to the actual source code:

        \(changes)

        Also read the current preview.html and compare it to the original extraction \
        to identify any layout/component changes. Apply those changes to the \
        corresponding source files.

        Do NOT modify preview.html. Work only in \(sourcePath).
        Do NOT modify files outside \(sourcePath).
        Make atomic, reviewable commits.
        """
        sendMessage(prompt)
    }

    /// Send rebase prompt to re-sync mockup with current source
    func rebaseFromSource(sourcePath: String) {
        let prompt = """
        The source code at \(sourcePath) has changed since the mockup was last generated. \
        Re-read the source code and update preview.html to match the current state of \
        the application. Preserve any design changes I made in the mockup that don't \
        conflict with source changes. If there are conflicts (I changed something in the \
        mockup that also changed in source), keep the source version and note what was \
        overridden in your response.
        """
        sendMessage(prompt)
    }

    var isRunning: Bool {
        switch state {
        case .idle, .error: return false
        case .launching, .streaming, .toolRunning: return true
        }
    }

    func newSession() {
        stop()
        messages.removeAll()
        sessionId = nil
        modelName = nil
        totalCost = nil
        state = .idle
        deleteSessionState()
        NotificationCenter.default.post(name: .clearSession, object: nil)
    }

    func sendMessage(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        inputText = ""

        // Prepend image attachment reference if present
        if let _ = attachedImage, let imgPath = attachedImagePath {
            trimmed = "[Reference image saved at \(imgPath) — read it for visual context]\n\n" + trimmed
            attachedImage = nil
            attachedImagePath = nil
        }

        // Prepend design brief on first message of a new session
        if sessionId == nil,
           case .project(let slug) = projectContext,
           let brief = loadDesignBrief(slug: slug) {
            trimmed = "[Design Brief:\n\(brief)]\n\n" + trimmed
        }

        // Prepend attached component HTML (only to prompt, not displayed message)
        let displayText = trimmed
        var componentNames: [String] = []
        if let components = appState?.attachedComponents, !components.isEmpty {
            componentNames = components.map { $0.name }
            var componentContext = "[Referenced Components:\n"
            for comp in components {
                componentContext += "## \(comp.name)\n```html\n\(comp.html)\n```\n\n"
            }
            componentContext += "Use these components as building blocks in the design.]\n\n"
            trimmed = componentContext + trimmed
            appState?.attachedComponents.removeAll()
        }

        var blocks: [ContentBlock] = []
        if !componentNames.isEmpty {
            blocks.append(.componentRef(names: componentNames))
        }
        blocks.append(.text(text: displayText))
        messages.append(ChatMessage(role: .user, blocks: blocks))
        state = .launching

        // Save annotated screenshot synchronously before launching claude
        saveAnnotatedScreenshotSync()

        var args = [
            "-p", trimmed,
            "--output-format", "stream-json",
            "--verbose",
            "--model", appState?.claudeModel ?? "sonnet",
            "--permission-mode", appState?.claudePermissionMode ?? "acceptEdits"
        ]
        if let sid = sessionId {
            args += ["--resume", sid]
        }

        let outPipe = Pipe()
        let errPipe = Pipe()

        // Strip Claude Code env vars to avoid nested-session detection
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        env["TERM"] = "dumb"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        proc.environment = env
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        currentProcess = proc

        do {
            try proc.run()
        } catch {
            state = .error("Failed to launch: \(error.localizedDescription)")
            return
        }

        state = .streaming

        // Read stdout on a background thread
        let outHandle = outPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var lineBuffer = ""
            while true {
                let data = outHandle.availableData
                if data.isEmpty { break } // EOF
                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                lineBuffer += chunk
                while let range = lineBuffer.range(of: "\n") {
                    let line = String(lineBuffer[lineBuffer.startIndex..<range.lowerBound])
                    lineBuffer = String(lineBuffer[range.upperBound...])
                    if !line.isEmpty {
                        DispatchQueue.main.async { self?.handleStreamLine(line) }
                    }
                }
            }
            if !lineBuffer.isEmpty {
                let remaining = lineBuffer
                DispatchQueue.main.async { self?.handleStreamLine(remaining) }
            }
            DispatchQueue.main.async { self?.processDidExit() }
        }

        // Log stderr for debugging
        let errHandle = errPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            let data = errHandle.readDataToEndOfFile()
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                NSLog("[Ligma] stderr: %@", text)
            }
        }
    }

    func stop() {
        currentProcess?.terminate()
        currentProcess = nil
        state = .idle
    }

    private func processDidExit() {
        currentProcess = nil
        if case .error = state { return }
        state = .idle
    }

    private func handleStreamLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = json["type"] as? String ?? ""

        switch type {
        case "system":
            if let sid = json["session_id"] as? String {
                sessionId = sid
                saveSessionState()
            }
            if let model = json["model"] as? String {
                modelName = model
                saveSessionState()
            }

        case "assistant":
            // Full assistant message — create/update with content blocks
            handleAssistantMessage(json)

        case "user":
            // Tool result message
            handleUserMessage(json)

        case "result":
            if let costInfo = json["total_cost_usd"] as? Double {
                totalCost = costInfo
            }
            state = .idle

        default:
            break
        }
    }

    private func handleAssistantMessage(_ json: [String: Any]) {
        // Content is nested under "message" key from CLI output
        let messageObj = json["message"] as? [String: Any] ?? json
        guard let contentArray = messageObj["content"] as? [[String: Any]] else { return }

        var blocks: [ContentBlock] = []
        for item in contentArray {
            let itemType = item["type"] as? String ?? ""
            switch itemType {
            case "text":
                let text = item["text"] as? String ?? ""
                blocks.append(.text(text: text))
            case "tool_use":
                let name = item["name"] as? String ?? "tool"
                let toolId = item["id"] as? String ?? ""
                let inputDict = item["input"] as? [String: Any] ?? [:]
                let inputStr: String
                if let inputData = try? JSONSerialization.data(withJSONObject: inputDict, options: [.prettyPrinted, .sortedKeys]),
                   let s = String(data: inputData, encoding: .utf8) {
                    inputStr = s
                } else {
                    inputStr = "{}"
                }
                blocks.append(.toolUse(toolName: name, toolInput: inputStr, toolUseId: toolId))
                state = .toolRunning(friendlyToolName(name))
            default:
                break
            }
        }

        if !blocks.isEmpty {
            // Replace the last assistant message or create a new one
            if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx].blocks = blocks
            } else {
                messages.append(ChatMessage(role: .assistant, blocks: blocks))
            }
            // If there's text, we're streaming
            if blocks.contains(where: { if case .text = $0 { return true }; return false }) {
                if case .toolRunning = state {} else {
                    state = .streaming
                }
            }
        }
    }

    private func handleUserMessage(_ json: [String: Any]) {
        let messageObj = json["message"] as? [String: Any] ?? json
        guard let contentArray = messageObj["content"] as? [[String: Any]] else { return }

        for item in contentArray {
            let itemType = item["type"] as? String ?? ""
            if itemType == "tool_result" {
                let toolUseId = item["tool_use_id"] as? String ?? ""
                let isError = item["is_error"] as? Bool ?? false
                var resultText = ""
                if let content = item["content"] as? String {
                    resultText = content
                } else if let contentArr = item["content"] as? [[String: Any]] {
                    resultText = contentArr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }

                // Append tool result to the last assistant message
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages[lastIdx].blocks.append(
                        .toolResult(toolUseId: toolUseId, content: resultText, isError: isError)
                    )
                }
            }
        }
        state = .streaming
    }

    private func friendlyToolName(_ name: String) -> String {
        switch name.lowercased() {
        case "write": return "Writing file"
        case "edit": return "Editing file"
        case "read": return "Reading file"
        case "bash": return "Running command"
        case "glob": return "Searching files"
        case "grep": return "Searching code"
        case "webfetch": return "Fetching URL"
        case "websearch": return "Searching web"
        default: return name
        }
    }
}

// MARK: - Chat View

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel

    private let bgColor = Color(red: 0x2C/255, green: 0x2C/255, blue: 0x2C/255)
    private let accentTeal = Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255)

    var body: some View {
        VStack(spacing: 0) {
            // Activity indicator bar
            if viewModel.isRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(activityLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0xB3/255, green: 0xB3/255, blue: 0xB3/255))
                    Spacer()
                    Button {
                        viewModel.stop()
                    } label: {
                        Text("Stop")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(red: 255/255, green: 107/255, blue: 107/255))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(red: 0x33/255, green: 0x33/255, blue: 0x33/255))
            }

            // Error banner
            if case .error(let msg) = viewModel.state {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(msg)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange)
            }

            if viewModel.messages.isEmpty {
                welcomeView
            } else {
                messageList
            }

            ChatInputBar(viewModel: viewModel)
        }
        .background(bgColor)
    }

    private var activityLabel: String {
        switch viewModel.state {
        case .launching: return "Starting..."
        case .streaming: return "Responding..."
        case .toolRunning(let tool): return tool + "..."
        default: return ""
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Describe a UI")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(red: 0xB3/255, green: 0xB3/255, blue: 0xB3/255))

            VStack(spacing: 8) {
                examplePromptButton("A SaaS analytics dashboard with sidebar nav")
                examplePromptButton("An iOS onboarding flow with 3 steps")
                examplePromptButton("A settings page with toggle switches")
            }
            .padding(.horizontal, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func examplePromptButton(_ prompt: String) -> some View {
        Button {
            viewModel.inputText = prompt
        } label: {
            Text(prompt)
                .font(.system(size: 12))
                .foregroundStyle(accentTeal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(accentTeal.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(accentTeal.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.messages.last?.blocks.count) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            if let last = viewModel.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // statusBar removed — cost counter dropped, new session button moved to ChatInputBar
}

// MARK: - Message Row

struct MessageRow: View {
    let message: ChatMessage

    private let userBubbleBg = Color(red: 0x38/255, green: 0x38/255, blue: 0x38/255)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if message.role == .user {
                Text("You")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0x8C/255, green: 0x8C/255, blue: 0x8C/255))
                    .padding(.horizontal, 10)
            }

            ForEach(message.blocks) { block in
                blockView(block)
                    .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func blockView(_ block: ContentBlock) -> some View {
        switch block {
        case .text(_, let text):
            if message.role == .user {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(userBubbleBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            } else {
                MarkdownText(text: text)
            }
        case .toolUse(_, let toolName, let toolInput, _):
            ToolUseCard(toolName: toolName, toolInput: toolInput)
        case .toolResult(_, _, let content, let isError):
            ToolResultCard(content: content, isError: isError)
        case .componentRef(_, let names):
            HStack(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 4) {
                        Image(systemName: "curlybraces")
                            .font(.system(size: 9))
                        Text(name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255).opacity(0.2))
                    )
                    .foregroundStyle(Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255))
                }
            }
        }
    }
}

// MARK: - Markdown Text (minimal)

struct MarkdownText: View {
    let text: String

    private let textColor = Color.white
    private let codeBlockBg = Color(red: 0x1E/255, green: 0x1E/255, blue: 0x1E/255)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseSegments().enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let t):
                    Text(parseInlineMarkdown(t))
                        .font(.system(size: 13))
                        .foregroundStyle(textColor)
                        .textSelection(.enabled)
                case .code(let lang, let code):
                    VStack(alignment: .leading, spacing: 0) {
                        if !lang.isEmpty {
                            Text(lang)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(red: 0x8C/255, green: 0x8C/255, blue: 0x8C/255))
                                .padding(.horizontal, 8)
                                .padding(.top, 4)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color(red: 0xB3/255, green: 0xB3/255, blue: 0xB3/255))
                                .padding(8)
                                .textSelection(.enabled)
                        }
                    }
                    .background(codeBlockBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private enum Segment {
        case prose(String)
        case code(lang: String, code: String)
    }

    private func parseSegments() -> [Segment] {
        var segments: [Segment] = []
        let parts = text.components(separatedBy: "```")
        for (i, part) in parts.enumerated() {
            if i % 2 == 0 {
                // Prose
                let trimmed = part.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty {
                    segments.append(.prose(trimmed))
                }
            } else {
                // Code block
                let lines = part.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                let lang = lines.first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                let code: String
                if lines.count > 1 {
                    code = String(lines[1]).trimmingCharacters(in: .newlines)
                } else {
                    code = ""
                }
                segments.append(.code(lang: lang, code: code))
            }
        }
        return segments
    }

    private func parseInlineMarkdown(_ text: String) -> AttributedString {
        var result = AttributedString()
        let boldPattern = try! Regex(#"\*\*(.+?)\*\*"#)
        var remaining = text[...]
        while let match = remaining.firstMatch(of: boldPattern) {
            let before = String(remaining[remaining.startIndex..<match.range.lowerBound])
            if !before.isEmpty {
                result.append(AttributedString(before))
            }
            var bold = AttributedString(String(match.output[1].substring ?? ""))
            bold.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            result.append(bold)
            remaining = remaining[match.range.upperBound...]
        }
        let tail = String(remaining)
        if !tail.isEmpty {
            result.append(AttributedString(tail))
        }
        return result
    }
}

// MARK: - Tool Use Card

struct ToolUseCard: View {
    let toolName: String
    let toolInput: String
    @State private var expanded = false

    private let bgColor = Color(red: 0x33/255, green: 0x33/255, blue: 0x33/255)
    private let teal = Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: toolIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(teal)

                    Text(friendlyLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0xB3/255, green: 0xB3/255, blue: 0xB3/255))

                    Spacer()

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(red: 0x8C/255, green: 0x8C/255, blue: 0x8C/255))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().opacity(0.3)
                ScrollView {
                    Text(toolInput)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(red: 0xB3/255, green: 0xB3/255, blue: 0xB3/255))
                        .padding(10)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
        }
        .background(bgColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(red: 0x44/255, green: 0x44/255, blue: 0x44/255), lineWidth: 1)
        )
    }

    private var friendlyLabel: String {
        // Extract file path from tool input if possible
        if let data = toolInput.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let filePath = dict["file_path"] as? String ?? dict["path"] as? String {
                let name = (filePath as NSString).lastPathComponent
                switch toolName.lowercased() {
                case "write": return "Writing \(name)"
                case "edit": return "Editing \(name)"
                case "read": return "Reading \(name)"
                default: break
                }
            }
            if let command = dict["command"] as? String {
                let short = command.count > 50 ? String(command.prefix(50)) + "..." : command
                return "Running: \(short)"
            }
            if let pattern = dict["pattern"] as? String {
                return "Searching: \(pattern)"
            }
        }
        switch toolName.lowercased() {
        case "write": return "Writing file..."
        case "edit": return "Editing file..."
        case "read": return "Reading file..."
        case "bash": return "Running command..."
        case "glob": return "Searching files..."
        case "grep": return "Searching code..."
        default: return "\(toolName)..."
        }
    }

    private var toolIcon: String {
        switch toolName.lowercased() {
        case "write": return "doc.badge.plus"
        case "edit": return "pencil"
        case "read": return "doc.text"
        case "bash": return "terminal"
        case "glob", "grep": return "magnifyingglass"
        case "webfetch", "websearch": return "globe"
        default: return "wrench"
        }
    }
}

// MARK: - Tool Result Card

struct ToolResultCard: View {
    let content: String
    let isError: Bool
    @State private var expanded = false

    var body: some View {
        if !content.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(isError
                                ? Color(red: 255/255, green: 107/255, blue: 107/255)
                                : Color(red: 0x8C/255, green: 0x8C/255, blue: 0x8C/255))

                        Text(previewText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(red: 0xB3/255, green: 0xB3/255, blue: 0xB3/255))
                            .lineLimit(1)

                        Spacer()

                        if content.count > 80 {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Color(red: 0x8C/255, green: 0x8C/255, blue: 0x8C/255))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)

                if expanded {
                    Divider().opacity(0.2)
                    ScrollView {
                        Text(content)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(red: 0xB3/255, green: 0xB3/255, blue: 0xB3/255))
                            .padding(10)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
            }
            .background(Color(red: 0x30/255, green: 0x30/255, blue: 0x30/255))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var previewText: String {
        let firstLine = content.components(separatedBy: .newlines).first ?? content
        return firstLine.count > 80 ? String(firstLine.prefix(80)) + "..." : firstLine
    }
}

// MARK: - Chat Input Bar

struct ChatInputBar: View {
    @Bindable var viewModel: ChatViewModel
    @State private var colorPanelDelegate: ColorPanelDelegate?
    @State private var showComponentPicker = false

    private let bgColor = Color(red: 0x2C/255, green: 0x2C/255, blue: 0x2C/255)
    private let inputBg = Color(red: 0x38/255, green: 0x38/255, blue: 0x38/255)
    private let teal = Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255)
    private let coral = Color(red: 255/255, green: 107/255, blue: 107/255)

    var body: some View {
        VStack(spacing: 0) {
            // Attachment preview
            if let img = viewModel.attachedImage {
                HStack(spacing: 6) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button {
                        viewModel.attachedImage = nil
                        viewModel.attachedImagePath = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(white: 0.5))
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }

            // Attached components chips
            if let appState = viewModel.appState, !appState.attachedComponents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(appState.attachedComponents.enumerated()), id: \.offset) { idx, comp in
                            HStack(spacing: 4) {
                                Image(systemName: "curlybraces")
                                    .font(.system(size: 9))
                                Text(comp.name)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Button {
                                    viewModel.appState?.attachedComponents.remove(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color(white: 0.5))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(teal.opacity(0.2))
                            )
                            .foregroundStyle(teal)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }

            HStack(spacing: 8) {
                TextField("Describe a design...", text: $viewModel.inputText, axis: .vertical)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onKeyPress(.return) {
                        if NSEvent.modifierFlags.contains(.shift) {
                            return .ignored // let the newline through
                        }
                        viewModel.sendMessage(viewModel.inputText)
                        return .handled
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(inputBg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onPasteCommand(of: [.png, .tiff]) { providers in
                        guard let provider = providers.first else { return }
                        _ = provider.loadDataRepresentation(for: .png) { data, error in
                            guard let data, error == nil,
                                  let image = NSImage(data: data) else { return }
                            let url = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent("ligma/.user-attachment.png")
                            try? data.write(to: url)
                            DispatchQueue.main.async {
                                viewModel.attachedImage = image
                                viewModel.attachedImagePath = ".user-attachment.png"
                            }
                        }
                    }

                // Attach component
                if case .project = viewModel.appState?.currentProject {
                    Button {
                        showComponentPicker.toggle()
                    } label: {
                        Image(systemName: "curlybraces")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(red: 0x8C/255, green: 0x8C/255, blue: 0x8C/255))
                    }
                    .buttonStyle(.plain)
                    .help("Attach component to message")
                    .popover(isPresented: $showComponentPicker) {
                        ComponentPickerPopover(appState: viewModel.appState)
                    }
                }

                // Eyedropper color picker
                Button {
                    showColorPanel()
                } label: {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(red: 0x8C/255, green: 0x8C/255, blue: 0x8C/255))
                }
                .buttonStyle(.plain)
                .help("Pick a color to reference in chat")

                Button {
                    if viewModel.isRunning {
                        viewModel.stop()
                    } else {
                        viewModel.sendMessage(viewModel.inputText)
                    }
                } label: {
                    Image(systemName: viewModel.isRunning ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(viewModel.isRunning ? coral : teal)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.isRunning && viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(!viewModel.isRunning && viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.3 : 1.0)

                // New session button
                if viewModel.sessionId != nil {
                    Button {
                        if viewModel.appState?.previewReady == true {
                            viewModel.appState?.showNewSessionConfirm = true
                        } else {
                            viewModel.newSession()
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color(white: 0.4))
                    }
                    .buttonStyle(.plain)
                    .help("New Session")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(bgColor)
    }

    private func showColorPanel() {
        let delegate = ColorPanelDelegate { [self] color in
            insertColorIntoInput(color)
        }
        colorPanelDelegate = delegate
        let panel = NSColorPanel.shared
        panel.setTarget(delegate)
        panel.setAction(#selector(ColorPanelDelegate.colorChanged(_:)))
        panel.isContinuous = false
        panel.orderFront(nil)
    }

    private func insertColorIntoInput(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return }
        let r = Int(srgb.redComponent * 255)
        let g = Int(srgb.greenComponent * 255)
        let b = Int(srgb.blueComponent * 255)
        let hex = String(format: "#%02X%02X%02X", r, g, b)
        if !viewModel.inputText.isEmpty && !viewModel.inputText.hasSuffix(" ") {
            viewModel.inputText += " "
        }
        viewModel.inputText += "[color: \(hex)]"
    }
}

// MARK: - Sketch Overlay

// Sets the base cursor for the sketch area via cursor rects (flicker-free)
struct SketchCursorRegion: NSViewRepresentable {
    var isActive: Bool

    func makeNSView(context: Context) -> SketchCursorNSView {
        SketchCursorNSView()
    }

    func updateNSView(_ nsView: SketchCursorNSView, context: Context) {
        nsView.isActive = isActive
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    class SketchCursorNSView: NSView {
        var isActive = false

        // Transparent to clicks/drags — only provides cursor rects
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            if isActive {
                addCursorRect(bounds, cursor: .crosshair)
            }
        }
    }
}

struct SketchOverlay: View {
    @Bindable var state: AppState
    @FocusState private var textFieldFocused: Bool
    @State private var draggingAnnotationId: UUID?
    @State private var dragStartPoints: [CGPoint]?
    private let strokeColor = Color(red: 1.0, green: 107/255, blue: 107/255) // coral #FF6B6B
    private let hitThreshold: CGFloat = 12
    private let fontSize: CGFloat = 16

    var body: some View {
        ZStack {
            Canvas { context, _ in
                for annotation in state.annotations {
                    // Skip the one being edited — the TextField overlay handles it
                    if annotation.id == state.editingAnnotationId { continue }
                    drawAnnotation(annotation, in: &context)
                }
                if let current = state.currentAnnotation {
                    drawAnnotation(current, in: &context)
                }
            }
            .allowsHitTesting(state.isSketchMode && state.editingAnnotationId == nil)
            .background {
                SketchCursorRegion(isActive: state.isSketchMode && state.editingAnnotationId == nil)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let shiftHeld = NSEvent.modifierFlags.contains(.shift)

                        // Shift+drag on an annotation → move it
                        if shiftHeld && state.currentAnnotation == nil && draggingAnnotationId == nil {
                            if let hitId = hitTest(point: value.startLocation),
                               let idx = state.annotations.firstIndex(where: { $0.id == hitId }) {
                                draggingAnnotationId = hitId
                                dragStartPoints = state.annotations[idx].points
                                NSCursor.closedHand.push()
                                return
                            }
                        }

                        // Continue moving
                        if let dragId = draggingAnnotationId,
                           let startPoints = dragStartPoints,
                           let idx = state.annotations.firstIndex(where: { $0.id == dragId }) {
                            let dx = value.location.x - value.startLocation.x
                            let dy = value.location.y - value.startLocation.y
                            state.annotations[idx].points = startPoints.map {
                                CGPoint(x: $0.x + dx, y: $0.y + dy)
                            }
                            return
                        }

                        // Drawing a new annotation
                        switch state.activeTool {
                        case .freehand:
                            if state.currentAnnotation == nil {
                                state.currentAnnotation = Annotation(tool: .freehand, points: [value.startLocation])
                            }
                            state.currentAnnotation?.points.append(value.location)
                        case .text:
                            break // handled in onEnded
                        case .rectangle, .ellipse, .arrow, .line:
                            state.currentAnnotation = Annotation(
                                tool: state.activeTool,
                                points: [value.startLocation, value.location]
                            )
                        }
                    }
                    .onEnded { value in
                        if let dragId = draggingAnnotationId, let startPoints = dragStartPoints {
                            state.pushAnnotationUndo(.moved(dragId, startPoints))
                            draggingAnnotationId = nil
                            dragStartPoints = nil
                            NSCursor.pop()
                            return
                        }
                        if state.activeTool == .text {
                            let annotation = Annotation(tool: .text, points: [value.location])
                            state.annotations.append(annotation)
                            state.pushAnnotationUndo(.added)
                            state.editingAnnotationId = annotation.id
                            state.editingText = ""
                            textFieldFocused = true
                        } else if let annotation = state.currentAnnotation {
                            state.annotations.append(annotation)
                            state.pushAnnotationUndo(.added)
                            state.currentAnnotation = nil
                        }
                    }
            )

            // Text editing overlay
            if let editId = state.editingAnnotationId,
               let annotation = state.annotations.first(where: { $0.id == editId }) {
                TextField("Type...", text: $state.editingText)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(strokeColor)
                    .textFieldStyle(.plain)
                    .frame(width: 200)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .position(annotation.points[0])
                    .focused($textFieldFocused)
                    .onSubmit {
                        commitTextAnnotation()
                    }
                    .onExitCommand {
                        // Escape cancels
                        if let idx = state.annotations.firstIndex(where: { $0.id == editId }) {
                            state.annotations.remove(at: idx)
                        }
                        state.editingAnnotationId = nil
                        state.editingText = ""
                    }
            }
        }
        .onKeyPress(characters: .init(charactersIn: "123456")) { press in
            guard state.isSketchMode, state.editingAnnotationId == nil else { return .ignored }
            let tools = AnnotationTool.allCases
            if let idx = Int(String(press.characters.first ?? "0")),
               idx >= 1, idx <= tools.count {
                state.activeTool = tools[idx - 1]
                return .handled
            }
            return .ignored
        }
    }

    private func commitTextAnnotation() {
        guard let editId = state.editingAnnotationId,
              let idx = state.annotations.firstIndex(where: { $0.id == editId }) else { return }
        if state.editingText.trimmingCharacters(in: .whitespaces).isEmpty {
            state.annotations.remove(at: idx)
        } else {
            state.annotations[idx].text = state.editingText
        }
        state.editingAnnotationId = nil
        state.editingText = ""
    }

    private func hitTest(point: CGPoint) -> UUID? {
        // Check in reverse order so topmost annotation is hit first
        for annotation in state.annotations.reversed() {
            switch annotation.tool {
            case .text:
                guard let pos = annotation.points.first else { continue }
                // Approximate text bounding box
                let textWidth = CGFloat(annotation.text.count) * fontSize * 0.6
                let rect = CGRect(x: pos.x - 4, y: pos.y - fontSize / 2 - 4,
                                  width: max(textWidth, 40) + 8, height: fontSize + 8)
                if rect.contains(point) { return annotation.id }

            case .freehand:
                for p in annotation.points {
                    if hypot(p.x - point.x, p.y - point.y) < hitThreshold {
                        return annotation.id
                    }
                }

            case .rectangle, .ellipse:
                guard annotation.points.count == 2 else { continue }
                let rect = CGRect(
                    x: min(annotation.points[0].x, annotation.points[1].x) - hitThreshold,
                    y: min(annotation.points[0].y, annotation.points[1].y) - hitThreshold,
                    width: abs(annotation.points[1].x - annotation.points[0].x) + hitThreshold * 2,
                    height: abs(annotation.points[1].y - annotation.points[0].y) + hitThreshold * 2
                )
                if rect.contains(point) { return annotation.id }

            case .arrow, .line:
                guard annotation.points.count == 2 else { continue }
                let dist = distanceToSegment(point: point,
                                             a: annotation.points[0],
                                             b: annotation.points[1])
                if dist < hitThreshold { return annotation.id }
            }
        }
        return nil
    }

    private func distanceToSegment(point: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lenSq))
        let projX = a.x + t * dx, projY = a.y + t * dy
        return hypot(point.x - projX, point.y - projY)
    }

    private func drawAnnotation(_ annotation: Annotation, in context: inout GraphicsContext) {
        switch annotation.tool {
        case .text:
            guard !annotation.text.isEmpty, let pos = annotation.points.first else { return }
            let resolved = context.resolve(
                Text(annotation.text)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(strokeColor)
            )
            context.draw(resolved, at: pos, anchor: .leading)
            return

        default:
            break
        }

        var path = Path()

        switch annotation.tool {
        case .freehand:
            guard annotation.points.count >= 2 else { return }
            path.move(to: annotation.points[0])
            for i in 1..<annotation.points.count {
                path.addLine(to: annotation.points[i])
            }

        case .rectangle:
            guard annotation.points.count == 2 else { return }
            let origin = CGPoint(
                x: min(annotation.points[0].x, annotation.points[1].x),
                y: min(annotation.points[0].y, annotation.points[1].y)
            )
            let size = CGSize(
                width: abs(annotation.points[1].x - annotation.points[0].x),
                height: abs(annotation.points[1].y - annotation.points[0].y)
            )
            path.addRect(CGRect(origin: origin, size: size))

        case .ellipse:
            guard annotation.points.count == 2 else { return }
            let origin = CGPoint(
                x: min(annotation.points[0].x, annotation.points[1].x),
                y: min(annotation.points[0].y, annotation.points[1].y)
            )
            let size = CGSize(
                width: abs(annotation.points[1].x - annotation.points[0].x),
                height: abs(annotation.points[1].y - annotation.points[0].y)
            )
            path.addEllipse(in: CGRect(origin: origin, size: size))

        case .arrow:
            guard annotation.points.count == 2 else { return }
            let start = annotation.points[0]
            let end = annotation.points[1]
            path.move(to: start)
            path.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let headLen: CGFloat = 15
            let headAngle: CGFloat = .pi / 6
            path.move(to: end)
            path.addLine(to: CGPoint(
                x: end.x - headLen * cos(angle - headAngle),
                y: end.y - headLen * sin(angle - headAngle)
            ))
            path.move(to: end)
            path.addLine(to: CGPoint(
                x: end.x - headLen * cos(angle + headAngle),
                y: end.y - headLen * sin(angle + headAngle)
            ))

        case .line:
            guard annotation.points.count == 2 else { return }
            path.move(to: annotation.points[0])
            path.addLine(to: annotation.points[1])

        case .text:
            return // handled above
        }

        context.stroke(path, with: .color(strokeColor), lineWidth: 5)
    }
}

// MARK: - Theme Editor Panel

struct ThemeEditorPanel: View {
    @Bindable var state: AppState
    var applyChange: (String, String) -> Void
    var applyAllToFile: ([(String, String)]) -> Void

    @State private var showAddRow = false
    @State private var newName = ""
    @State private var newValue = ""
    @State private var selectedFont: FontChoice = .system
    @State private var selectedTemplate: ThemeTemplate?

    private var hasDirtyTokens: Bool {
        state.themeTokens.contains { $0.isDirty }
    }

    private func submitNewToken() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let val = newValue.trimmingCharacters(in: .whitespaces)
        state.themeTokens.append(ThemeToken(name: trimmed, value: val, originalValue: ""))
        applyChange(trimmed, val)
        newName = ""
        newValue = ""
        showAddRow = false
    }

    private func applyTemplate(_ template: ThemeTemplate) {
        selectedTemplate = template
        // Determine font choice from template
        if let font = FontChoice.allCases.first(where: { $0.cssValue == template.fontFamily }) {
            selectedFont = font
        }
        let tokens: [(String, String)] = [
            ("color-bg", template.bgColor),
            ("color-surface", template.surfaceColor),
            ("color-text", template.textColor),
            ("color-accent", template.accentColor),
            ("font-family", template.fontFamily),
        ]
        state.themeTokens = tokens.map { ThemeToken(name: $0.0, value: $0.1, originalValue: "") }
        for (name, value) in tokens {
            applyChange(name, value)
        }
    }

    private func applySetup() {
        // Write design brief if in a project
        if case .project(let slug) = state.currentProject {
            writeDesignBrief(slug: slug, tokens: state.themeTokens, instructions: state.designInstructions)
        }
        // Write starter preview
        state.skipInitialPreviewClear = true
        writeStarterPreview(tokens: state.themeTokens)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("THEME")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(.secondary)

                Spacer()

                if hasDirtyTokens {
                    Button {
                        let dirty = state.themeTokens.filter { $0.isDirty }
                            .map { ($0.name, $0.value) }
                        applyAllToFile(dirty)
                    } label: {
                        Text("Apply to File")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255))
                }

                Button {
                    showAddRow = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    state.showThemeEditor = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if state.themeTokens.isEmpty && !showAddRow {
                // Setup mode — template picker, font, instructions
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Pick a starting palette")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)

                        // Template cards
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(themeTemplates) { tmpl in
                                    Button {
                                        applyTemplate(tmpl)
                                    } label: {
                                        VStack(spacing: 4) {
                                            HStack(spacing: 2) {
                                                RoundedRectangle(cornerRadius: 2)
                                                    .fill(Color(nsColor: NSColor(hex: tmpl.bgColor)))
                                                    .frame(width: 14, height: 14)
                                                RoundedRectangle(cornerRadius: 2)
                                                    .fill(Color(nsColor: NSColor(hex: tmpl.surfaceColor)))
                                                    .frame(width: 14, height: 14)
                                                RoundedRectangle(cornerRadius: 2)
                                                    .fill(Color(nsColor: NSColor(hex: tmpl.textColor)))
                                                    .frame(width: 14, height: 14)
                                                RoundedRectangle(cornerRadius: 2)
                                                    .fill(Color(nsColor: NSColor(hex: tmpl.accentColor)))
                                                    .frame(width: 14, height: 14)
                                            }
                                            Text(tmpl.displayName)
                                                .font(.system(size: 9))
                                                .foregroundStyle(.primary)
                                        }
                                        .padding(6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(selectedTemplate?.id == tmpl.id
                                                    ? Color.accentColor.opacity(0.1)
                                                    : Color.clear)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(selectedTemplate?.id == tmpl.id
                                                    ? Color.accentColor : Color.secondary.opacity(0.2),
                                                    lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 12)
                        }

                        // Font picker
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Font")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Picker("Font", selection: $selectedFont) {
                                ForEach(FontChoice.allCases) { font in
                                    Text(font.rawValue.capitalized).tag(font)
                                }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: selectedFont) { _, newFont in
                                // Update or add font-family token
                                if let idx = state.themeTokens.firstIndex(where: { $0.name == "font-family" }) {
                                    state.themeTokens[idx] = ThemeToken(
                                        name: "font-family", value: newFont.cssValue, originalValue: "")
                                } else if !state.themeTokens.isEmpty {
                                    state.themeTokens.append(
                                        ThemeToken(name: "font-family", value: newFont.cssValue, originalValue: ""))
                                }
                                applyChange("font-family", newFont.cssValue)
                            }
                        }
                        .padding(.horizontal, 12)

                        // Design instructions
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Design instructions")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            TextEditor(text: $state.designInstructions)
                                .font(.system(size: 11))
                                .frame(height: 56)
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(.background)
                                        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                                )
                                .overlay(
                                    Group {
                                        if state.designInstructions.isEmpty {
                                            Text("e.g. Minimal, lots of whitespace, rounded corners...")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.tertiary)
                                                .padding(.leading, 8)
                                                .padding(.top, 8)
                                                .allowsHitTesting(false)
                                        }
                                    }, alignment: .topLeading
                                )
                        }
                        .padding(.horizontal, 12)

                        // Apply button
                        if selectedTemplate != nil {
                            Button {
                                applySetup()
                            } label: {
                                Text("Apply Theme")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255))
                            )
                            .padding(.horizontal, 12)
                        }
                    }
                    .padding(.bottom, 8)
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if showAddRow {
                            HStack(spacing: 6) {
                                Text("--")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                TextField("name", text: $newName)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(minWidth: 60)
                                    .onSubmit { submitNewToken() }
                                TextField("value", text: $newValue)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(minWidth: 60)
                                    .onSubmit { submitNewToken() }
                                Button {
                                    submitNewToken()
                                } label: {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color(red: 0x0C/255, green: 0x8C/255, blue: 0xE9/255))
                                Button {
                                    newName = ""
                                    newValue = ""
                                    showAddRow = false
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            Divider().opacity(0.3)
                        }
                        ForEach($state.themeTokens) { $token in
                            ThemeTokenRow(token: $token, onChanged: { name, value in
                                applyChange(name, value)
                            })
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
        .frame(height: 240)
    }
}

struct ThemeTokenRow: View {
    @Binding var token: ThemeToken
    var onChanged: (String, String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("--\(token.name)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(minWidth: 80, alignment: .leading)

            Spacer()

            if token.isColor {
                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 24, height: 24)

                Text(token.value)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
            } else {
                TextField("", text: $token.value)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .onSubmit {
                        onChanged(token.name, token.value)
                    }
            }

            if token.isDirty {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var colorBinding: Binding<Color> {
        Binding<Color>(
            get: { Color(nsColor: NSColor(hex: token.value)) },
            set: { newColor in
                guard let srgb = NSColor(newColor).usingColorSpace(.sRGB) else { return }
                let r = Int(srgb.redComponent * 255)
                let g = Int(srgb.greenComponent * 255)
                let b = Int(srgb.blueComponent * 255)
                let hex = String(format: "#%02X%02X%02X", r, g, b)
                token.value = hex
                onChanged(token.name, hex)
            }
        )
    }
}

// MARK: - Color Panel Delegate

class ColorPanelDelegate: NSObject {
    var callback: (NSColor) -> Void

    init(callback: @escaping (NSColor) -> Void) {
        self.callback = callback
        super.init()
    }

    @objc func colorChanged(_ sender: NSColorPanel) {
        callback(sender.color)
    }
}

// MARK: - Preview WebView

struct PreviewWebView: NSViewRepresentable {
    let state: AppState
    var sessionGeneration: Int

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "elementPicker")
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.start(webView: webView, state: state)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var source: DispatchSourceFileSystemObject?
        var debounceWork: DispatchWorkItem?
        var snapshotDebounceWork: DispatchWorkItem?
        var reloadObserver: Any?
        var prevVersionObserver: Any?
        var nextVersionObserver: Any?
        var copyImageObserver: Any?
        var clearSessionObserver: Any?
        var sketchObserver: Any?
        var themeChangeObserver: Any?
        var themeWriteObserver: Any?
        var elementPickerObserver: Any?
        var elementPickerDeactivateObserver: Any?
        weak var webView: WKWebView?
        weak var state: AppState?

        var lastSessionGeneration = 0
        var isSnapshotting = false
        var lastSnapshotHash: String?
        var lastLoadedHTMLHash: String?
        var versionCounter = 1

        let home = FileManager.default.homeDirectoryForCurrentUser
        let previewPath: String
        let versionsDir: URL
        let maxVersions = 200

        override init() {
            previewPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("ligma/preview.html").path
            versionsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("ligma/.versions")
            super.init()
        }

        func start(webView: WKWebView, state: AppState) {
            self.webView = webView
            self.state = state

            let fm = FileManager.default
            if !fm.fileExists(atPath: previewPath) {
                fm.createFile(atPath: previewPath, contents: nil)
            }

            try? fm.createDirectory(at: versionsDir, withIntermediateDirectories: true)
            rediscoverVersions()

            loadPreview()
            watchDirectory()

            reloadObserver = NotificationCenter.default.addObserver(
                forName: .reloadPreview, object: nil, queue: .main
            ) { [weak self] _ in
                self?.state?.isBrowsingHistory = false
                self?.state?.newVersionsWhileBrowsing = 0
                self?.loadPreview()
            }

            prevVersionObserver = NotificationCenter.default.addObserver(
                forName: .previousVersion, object: nil, queue: .main
            ) { [weak self] _ in self?.navigateVersion(delta: -1) }

            nextVersionObserver = NotificationCenter.default.addObserver(
                forName: .nextVersion, object: nil, queue: .main
            ) { [weak self] _ in self?.navigateVersion(delta: 1) }

            copyImageObserver = NotificationCenter.default.addObserver(
                forName: .copyPreviewAsImage, object: nil, queue: .main
            ) { [weak self] _ in self?.copyAsImage() }

            clearSessionObserver = NotificationCenter.default.addObserver(
                forName: .clearSession, object: nil, queue: .main
            ) { [weak self] _ in self?.clearVersionHistory() }

            themeChangeObserver = NotificationCenter.default.addObserver(
                forName: .injectThemeChange, object: nil, queue: .main
            ) { [weak self] note in
                guard let info = note.userInfo,
                      let name = info["name"] as? String,
                      let value = info["value"] as? String else { return }
                self?.injectThemeCSS(name: name, value: value)
            }

            themeWriteObserver = NotificationCenter.default.addObserver(
                forName: .writeThemeToFile, object: nil, queue: .main
            ) { [weak self] note in
                guard let info = note.userInfo,
                      let tokens = info["tokens"] as? [(String, String)] else { return }
                self?.rewriteThemeInFile(tokens: tokens)
            }

            elementPickerObserver = NotificationCenter.default.addObserver(
                forName: .activateElementPicker, object: nil, queue: .main
            ) { [weak self] _ in self?.injectElementPickerJS() }

            elementPickerDeactivateObserver = NotificationCenter.default.addObserver(
                forName: .deactivateElementPicker, object: nil, queue: .main
            ) { [weak self] _ in self?.deactivateElementPickerJS() }

        }

        // MARK: Clear Version History

        func clearVersionHistory() {
            let fm = FileManager.default

            // Remove version files
            if let files = try? fm.contentsOfDirectory(atPath: versionsDir.path) {
                for file in files where file.hasSuffix(".html") {
                    try? fm.removeItem(at: versionsDir.appendingPathComponent(file))
                }
            }
            try? fm.removeItem(at: home.appendingPathComponent("ligma/.preview-screenshot-annotated.png"))

            // Truncate preview.html using FileHandle (works when String.write fails)
            if let fh = FileHandle(forWritingAtPath: previewPath) {
                fh.truncateFile(atOffset: 0)
                fh.closeFile()
            }

            // Clear AppState
            state?.versions.removeAll()
            state?.currentVersionIndex = 0
            state?.isBrowsingHistory = false
            state?.newVersionsWhileBrowsing = 0
            state?.annotations.removeAll()
            state?.currentAnnotation = nil
            state?.previewReady = false

            versionCounter = 1
            lastSnapshotHash = nil
            lastLoadedHTMLHash = nil

            // Cancel pending file-watcher reload and load placeholder
            debounceWork?.cancel()
            let placeholder = """
            <html><body style="display:flex;align-items:center;justify-content:center;\
            height:100vh;margin:0;font-family:system-ui;background:#2C2C2C;color:#555">\
            <div style="text-align:center">\
            <p style="font-size:0.9rem;font-weight:500;color:#444">Preview</p>\
            </div></body></html>
            """
            webView?.loadHTMLString(placeholder, baseURL: nil)
        }

        // MARK: Copy as Image

        func copyAsImage() {
            guard let webView, let state else { return }
            let annotations = state.annotations
            let config = WKSnapshotConfiguration()
            webView.takeSnapshot(with: config) { image, error in
                guard let image, error == nil else {
                    NSSound.beep()
                    return
                }
                let final = Self.compositeSketch(onto: image, annotations: annotations)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([final])

                state.showCopyImageConfirmation = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    state.showCopyImageConfirmation = false
                }
            }
        }

        // MARK: Version Management

        func rediscoverVersions() {
            guard let state else { return }
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(atPath: versionsDir.path) else { return }

            let htmlFiles = files
                .filter { $0.hasSuffix(".html") }
                .sorted { a, b in
                    let numA = Int(a.replacingOccurrences(of: ".html", with: "")) ?? 0
                    let numB = Int(b.replacingOccurrences(of: ".html", with: "")) ?? 0
                    return numA < numB
                }

            state.versions = htmlFiles.map { versionsDir.appendingPathComponent($0) }

            if let last = htmlFiles.last,
               let num = Int(last.replacingOccurrences(of: ".html", with: "")) {
                versionCounter = num + 1
            }

            if let lastURL = state.versions.last,
               let data = try? Data(contentsOf: lastURL) {
                lastSnapshotHash = sha256(data)
            }

            state.currentVersionIndex = max(0, state.versions.count - 1)
        }

        func scheduleSnapshot(html: String) {
            snapshotDebounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.saveSnapshot(html: html)
            }
            snapshotDebounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        }

        func saveSnapshot(html: String) {
            guard let state else { return }
            let data = Data(html.utf8)
            let hash = sha256(data)

            if hash == lastSnapshotHash { return }
            lastSnapshotHash = hash

            isSnapshotting = true
            let filename = String(format: "%03d.html", versionCounter)
            let url = versionsDir.appendingPathComponent(filename)
            try? html.write(to: url, atomically: true, encoding: .utf8)
            versionCounter += 1
            isSnapshotting = false

            state.versions.append(url)

            while state.versions.count > maxVersions {
                let oldest = state.versions.removeFirst()
                try? FileManager.default.removeItem(at: oldest)
                if state.isBrowsingHistory {
                    state.currentVersionIndex = max(0, state.currentVersionIndex - 1)
                }
            }

            if state.isBrowsingHistory {
                state.newVersionsWhileBrowsing += 1
            } else {
                state.currentVersionIndex = state.versions.count - 1
            }
        }

        func navigateVersion(delta: Int) {
            guard let state, let webView, state.versions.count >= 2 else { return }

            let newIndex: Int
            if !state.isBrowsingHistory {
                if delta < 0 {
                    newIndex = state.versions.count - 2
                    state.isBrowsingHistory = true
                } else {
                    return
                }
            } else {
                newIndex = state.currentVersionIndex + delta
            }

            if newIndex >= state.versions.count {
                state.isBrowsingHistory = false
                state.newVersionsWhileBrowsing = 0
                state.currentVersionIndex = state.versions.count - 1
                loadPreview()
                return
            }

            guard newIndex >= 0, newIndex < state.versions.count else { return }

            state.isBrowsingHistory = true
            state.currentVersionIndex = newIndex

            if let html = try? String(contentsOf: state.versions[newIndex], encoding: .utf8) {
                webView.loadHTMLString(
                    html,
                    baseURL: URL(fileURLWithPath: previewPath).deletingLastPathComponent()
                )
            }
        }

        // MARK: Preview Loading

        func loadPreview() {
            guard let webView else { return }

            guard let html = try? String(contentsOfFile: previewPath, encoding: .utf8),
                  !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Only show placeholder if we haven't loaded real content yet.
                // Transient empty reads during file edits should not reset the preview.
                if !(state?.previewReady ?? false) {
                    let placeholder = """
                    <html><body style="display:flex;align-items:center;justify-content:center;
                    height:100vh;margin:0;font-family:system-ui;background:#2C2C2C;color:#555">
                    <div style="text-align:center">
                    <p style="font-size:0.9rem;font-weight:500;color:#444">Preview</p>
                    </div></body></html>
                    """
                    webView.loadHTMLString(placeholder, baseURL: nil)
                }
                return
            }

            let wasReady = state?.previewReady ?? false
            state?.previewReady = true
            state?.lastUpdated = Date()

            // Mark codebase project as extracted on first preview load
            if !wasReady,
               let info = state?.currentProjectInfo,
               info.sourcePath != nil, !info.extracted {
                state?.currentProjectInfo?.extracted = true
                if let updated = state?.currentProjectInfo {
                    saveProjectInfo(updated)
                }
            }

            // Only clear sketches when the HTML content actually changes
            let htmlHash = sha256(Data(html.utf8))
            if htmlHash != lastLoadedHTMLHash {
                lastLoadedHTMLHash = htmlHash
                state?.annotations.removeAll()
                state?.currentAnnotation = nil
                state?.annotationUndoStack.removeAll()
                state?.isElementPickerActive = false
            }

            if !wasReady {
                state?.showPreview = true
            }

            scheduleSnapshot(html: html)

            if !(state?.isBrowsingHistory ?? false) {
                webView.loadHTMLString(
                    html,
                    baseURL: URL(fileURLWithPath: previewPath).deletingLastPathComponent()
                )

                // Auto-save screenshot for Claude's visual context
                scheduleScreenshot()
            }
        }

        // MARK: Section Extraction (WKNavigationDelegate)

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let js = """
            Array.from(document.querySelectorAll('section[id]')).map(s => ({
                id: s.id, title: s.getAttribute('data-title') || s.id
            }))
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let sections = result as? [[String: String]] else { return }
                let sectionInfos = sections.compactMap { dict -> SectionInfo? in
                    guard let name = dict["id"] else { return nil }
                    return SectionInfo(name: name, displayName: dict["title"] ?? name)
                }
                DispatchQueue.main.async {
                    self?.state?.currentProjectInfo?.sections = sectionInfos
                    if let info = self?.state?.currentProjectInfo {
                        saveProjectInfo(info)
                    }
                }
            }
        }

        // MARK: Auto Screenshot

        var screenshotDebounceWork: DispatchWorkItem?

        func scheduleScreenshot() {
            screenshotDebounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.saveScreenshot()
            }
            screenshotDebounceWork = work
            // Wait for WebView to finish rendering (longer than preview debounce)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }

        func saveScreenshot() {
            guard let webView else { return }
            let config = WKSnapshotConfiguration()
            webView.takeSnapshot(with: config) { image, error in
                guard let image, error == nil else { return }
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { return }
                let screenshotURL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("ligma/.preview-screenshot.png")
                try? png.write(to: screenshotURL)
            }
        }

        func saveAnnotatedScreenshot() {
            guard let webView, let state else { return }
            let annotations = state.annotations
            let config = WKSnapshotConfiguration()
            webView.takeSnapshot(with: config) { image, error in
                guard let image, error == nil else { return }
                let home = FileManager.default.homeDirectoryForCurrentUser
                if annotations.isEmpty {
                    // No sketches — remove annotated file so Claude doesn't read stale markups
                    try? FileManager.default.removeItem(
                        at: home.appendingPathComponent("ligma/.preview-screenshot-annotated.png"))
                } else {
                    let annotated = Self.compositeSketch(onto: image, annotations: annotations)
                    guard let tiff = annotated.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff),
                          let png = bitmap.representation(using: .png, properties: [:]) else { return }
                    try? png.write(to: home.appendingPathComponent("ligma/.preview-screenshot-annotated.png"))
                }
            }
        }

        // MARK: Theme Injection

        func injectThemeCSS(name: String, value: String) {
            let js = "document.documentElement.style.setProperty('--\(name)', '\(value)')"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        func rewriteThemeInFile(tokens: [(String, String)]) {
            guard var html = try? String(contentsOfFile: previewPath, encoding: .utf8) else { return }

            // Separate existing (regex-replace) vs new (insert) tokens
            let existingNames = Set(
                (state?.themeTokens ?? [])
                    .filter { !$0.originalValue.isEmpty }
                    .map { $0.name }
            )
            let existingTokens = tokens.filter { existingNames.contains($0.0) }
            let newTokens = tokens.filter { !existingNames.contains($0.0) }

            // Replace existing variables via regex
            for (name, value) in existingTokens {
                let pattern = "--\(NSRegularExpression.escapedPattern(for: name)):\\s*[^;]+"
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let range = NSRange(html.startIndex..., in: html)
                    html = regex.stringByReplacingMatches(
                        in: html, range: range,
                        withTemplate: "--\(name): \(value)"
                    )
                }
            }

            // Insert new variables into the HTML
            if !newTokens.isEmpty {
                let declarations = newTokens.map { "  --\($0.0): \($0.1);" }.joined(separator: "\n")

                if let rootMatch = html.range(of: ":root\\s*\\{[^}]*\\}", options: .regularExpression) {
                    // Insert before the closing } of :root
                    let closingBrace = html[rootMatch].lastIndex(of: "}")!
                    html.insert(contentsOf: "\n\(declarations)\n", at: closingBrace)
                } else if let styleClose = html.range(of: "</style>", options: .caseInsensitive) {
                    // No :root block — insert one before </style>
                    let block = "\n:root {\n\(declarations)\n}\n"
                    html.insert(contentsOf: block, at: styleClose.lowerBound)
                } else if let headClose = html.range(of: "</head>", options: .caseInsensitive) {
                    // No <style> block — insert one before </head>
                    let block = "<style>\n:root {\n\(declarations)\n}\n</style>\n"
                    html.insert(contentsOf: block, at: headClose.lowerBound)
                } else if let bodyOpen = html.range(of: "<body", options: .caseInsensitive) {
                    // No </head> — insert before <body>
                    let block = "<style>\n:root {\n\(declarations)\n}\n</style>\n"
                    html.insert(contentsOf: block, at: bodyOpen.lowerBound)
                }
            }

            isSnapshotting = true
            try? html.write(toFile: previewPath, atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.isSnapshotting = false
            }

            // Reset dirty state
            if let state {
                for i in state.themeTokens.indices {
                    if tokens.contains(where: { $0.0 == state.themeTokens[i].name }) {
                        let newVal = state.themeTokens[i].value
                        state.themeTokens[i] = ThemeToken(
                            name: state.themeTokens[i].name,
                            value: newVal,
                            originalValue: newVal
                        )
                    }
                }
            }
        }

        // MARK: File Watching

        func watchDirectory() {
            let dirPath = (previewPath as NSString).deletingLastPathComponent
            let fd = open(dirPath, O_EVTONLY)
            guard fd >= 0 else { return }

            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: .write,
                queue: .main
            )
            src.setEventHandler { [weak self] in
                guard let self, !self.isSnapshotting else { return }
                self.debouncedReload()
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            source = src
        }

        func debouncedReload() {
            debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.loadPreview() }
            debounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        // MARK: Helpers

        static func compositeSketch(onto image: NSImage, annotations: [Annotation]) -> NSImage {
            guard !annotations.isEmpty else { return image }
            let size = image.size
            let result = NSImage(size: size)
            result.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: size))

            let coral = NSColor(red: 1.0, green: 107/255, blue: 107/255, alpha: 1.0)
            coral.setStroke()

            func flipY(_ p: CGPoint) -> NSPoint {
                NSPoint(x: p.x, y: size.height - p.y)
            }

            for annotation in annotations {
                let bp = NSBezierPath()
                bp.lineWidth = 5
                bp.lineCapStyle = .round
                bp.lineJoinStyle = .round

                switch annotation.tool {
                case .text:
                    guard !annotation.text.isEmpty, let pos = annotation.points.first else { continue }
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.boldSystemFont(ofSize: 16),
                        .foregroundColor: coral
                    ]
                    let str = NSAttributedString(string: annotation.text, attributes: attrs)
                    let textSize = str.size()
                    let drawPoint = NSPoint(x: pos.x, y: size.height - pos.y - textSize.height / 2)
                    str.draw(at: drawPoint)
                    continue

                case .freehand:
                    guard annotation.points.count >= 2 else { continue }
                    bp.move(to: flipY(annotation.points[0]))
                    for i in 1..<annotation.points.count {
                        bp.line(to: flipY(annotation.points[i]))
                    }

                case .rectangle:
                    guard annotation.points.count == 2 else { continue }
                    let p0 = flipY(annotation.points[0])
                    let p1 = flipY(annotation.points[1])
                    let rect = NSRect(
                        x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                        width: abs(p1.x - p0.x), height: abs(p1.y - p0.y)
                    )
                    bp.appendRect(rect)

                case .ellipse:
                    guard annotation.points.count == 2 else { continue }
                    let p0 = flipY(annotation.points[0])
                    let p1 = flipY(annotation.points[1])
                    let rect = NSRect(
                        x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                        width: abs(p1.x - p0.x), height: abs(p1.y - p0.y)
                    )
                    bp.appendOval(in: rect)

                case .arrow:
                    guard annotation.points.count == 2 else { continue }
                    let start = flipY(annotation.points[0])
                    let end = flipY(annotation.points[1])
                    bp.move(to: start)
                    bp.line(to: end)
                    // Arrowhead
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    let headLen: CGFloat = 15
                    let headAngle: CGFloat = .pi / 6
                    bp.move(to: end)
                    bp.line(to: NSPoint(
                        x: end.x - headLen * cos(angle - headAngle),
                        y: end.y - headLen * sin(angle - headAngle)
                    ))
                    bp.move(to: end)
                    bp.line(to: NSPoint(
                        x: end.x - headLen * cos(angle + headAngle),
                        y: end.y - headLen * sin(angle + headAngle)
                    ))

                case .line:
                    guard annotation.points.count == 2 else { continue }
                    bp.move(to: flipY(annotation.points[0]))
                    bp.line(to: flipY(annotation.points[1]))
                }

                bp.stroke()
            }

            result.unlockFocus()
            return result
        }

        private func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        // MARK: Element Picker

        func injectElementPickerJS() {
            let js = """
            (function() {
                if (window.__elementPickerActive) return;
                window.__elementPickerActive = true;

                var overlay = document.createElement('div');
                overlay.id = '__ep_overlay';
                overlay.style.cssText = 'position:fixed;pointer-events:none;border:2px solid rgba(255,107,107,0.9);background:rgba(255,107,107,0.1);z-index:2147483647;display:none;transition:all 0.05s ease;';
                document.body.appendChild(overlay);

                var label = document.createElement('div');
                label.id = '__ep_label';
                label.style.cssText = 'position:fixed;pointer-events:none;background:rgba(255,107,107,0.95);color:#fff;font:bold 10px/1 system-ui;padding:2px 6px;border-radius:3px;z-index:2147483647;display:none;white-space:nowrap;';
                document.body.appendChild(label);

                function getInlinedHTML(el) {
                    var clone = el.cloneNode(true);
                    var props = ['margin','padding','width','height','min-width','min-height','max-width','max-height','display','flex-direction','justify-content','align-items','gap','font-family','font-size','font-weight','line-height','letter-spacing','color','background','background-color','background-image','border','border-radius','box-shadow','text-align','text-decoration','text-transform','opacity','overflow','position','top','left','right','bottom','transform','cursor','outline','white-space','object-fit'];
                    function applyStyles(orig, cloned) {
                        var cs = window.getComputedStyle(orig);
                        var inline = '';
                        for (var i = 0; i < props.length; i++) {
                            var v = cs.getPropertyValue(props[i]);
                            if (v) inline += props[i] + ':' + v + ';';
                        }
                        cloned.setAttribute('style', inline);
                        for (var j = 0; j < orig.children.length; j++) {
                            if (cloned.children[j]) applyStyles(orig.children[j], cloned.children[j]);
                        }
                    }
                    applyStyles(el, clone);
                    return clone.outerHTML;
                }

                function onMove(e) {
                    var t = e.target;
                    if (!t || !t.getBoundingClientRect || t.id === '__ep_overlay' || t.id === '__ep_label') return;
                    var r = t.getBoundingClientRect();
                    overlay.style.left = r.left + 'px';
                    overlay.style.top = r.top + 'px';
                    overlay.style.width = r.width + 'px';
                    overlay.style.height = r.height + 'px';
                    overlay.style.display = 'block';
                    label.textContent = t.tagName.toLowerCase() + (t.className && typeof t.className === 'string' ? '.' + t.className.split(' ')[0] : '');
                    label.style.left = r.left + 'px';
                    label.style.top = Math.max(0, r.top - 18) + 'px';
                    label.style.display = 'block';
                }

                function onClick(e) {
                    e.preventDefault();
                    e.stopImmediatePropagation();
                    var t = e.target;
                    if (!t || !t.getBoundingClientRect || t.id === '__ep_overlay' || t.id === '__ep_label') return;
                    var r = t.getBoundingClientRect();
                    var tag = t.tagName.toLowerCase();
                    var html = getInlinedHTML(t);
                    var multiPick = e.altKey;
                    window.webkit.messageHandlers.elementPicker.postMessage({
                        rect: { x: r.left, y: r.top, width: r.width, height: r.height },
                        html: html,
                        tag: tag,
                        multiPick: multiPick
                    });
                    if (!multiPick) cleanup();
                }

                function onKey(e) {
                    if (e.key === 'Escape') {
                        cleanup();
                        window.webkit.messageHandlers.elementPicker.postMessage({ cancelled: true });
                    }
                }

                function cleanup() {
                    window.__elementPickerActive = false;
                    document.removeEventListener('mousemove', onMove, true);
                    document.removeEventListener('click', onClick, true);
                    document.removeEventListener('keydown', onKey, true);
                    var o = document.getElementById('__ep_overlay');
                    var l = document.getElementById('__ep_label');
                    if (o) o.remove();
                    if (l) l.remove();
                }

                document.addEventListener('mousemove', onMove, true);
                document.addEventListener('click', onClick, true);
                document.addEventListener('keydown', onKey, true);
            })();
            """
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        func deactivateElementPickerJS() {
            let js = """
            (function() {
                window.__elementPickerActive = false;
                var o = document.getElementById('__ep_overlay');
                var l = document.getElementById('__ep_label');
                if (o) o.remove();
                if (l) l.remove();
            })();
            """
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "elementPicker",
                  let body = message.body as? [String: Any] else { return }

            if body["cancelled"] as? Bool == true {
                DispatchQueue.main.async { self.state?.isElementPickerActive = false }
                return
            }

            guard let rectDict = body["rect"] as? [String: CGFloat],
                  let html = body["html"] as? String,
                  let tag = body["tag"] as? String else { return }

            let multiPick = body["multiPick"] as? Bool ?? false
            let rect = CGRect(
                x: rectDict["x"] ?? 0,
                y: rectDict["y"] ?? 0,
                width: rectDict["width"] ?? 0,
                height: rectDict["height"] ?? 0
            )
            captureElement(rect: rect, html: html, tag: tag, multiPick: multiPick)
        }

        func captureElement(rect: CGRect, html: String, tag: String, multiPick: Bool) {
            guard let webView, let state else { return }
            guard case .project = state.currentProject else { return }

            if !multiPick {
                DispatchQueue.main.async { state.isElementPickerActive = false }
            }

            // Snapshot the element region
            let config = WKSnapshotConfiguration()
            config.rect = rect
            webView.takeSnapshot(with: config) { image, error in
                guard let image, error == nil else { return }
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { return }

                // Store pending data and show naming sheet
                DispatchQueue.main.async {
                    state.pendingComponentHTML = html
                    state.pendingComponentTag = tag
                    state.pendingComponentPNG = png
                    state.showComponentNamingSheet = true
                }
            }
        }

        deinit {
            source?.cancel()
            if let obs = reloadObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = prevVersionObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = nextVersionObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = copyImageObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = clearSessionObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = sketchObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = themeChangeObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = themeWriteObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = elementPickerObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = elementPickerDeactivateObserver { NotificationCenter.default.removeObserver(obs) }
        }
    }
}
