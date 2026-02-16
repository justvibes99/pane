<p align="center">
  <img src="Sources/ligma-logo.png" width="120" />
</p>

<h1 align="center">Ligma</h1>

<p align="center">
  AI-powered design mockup tool for macOS.<br>
  Describe a UI, get a live preview. Iterate with chat.
</p>

---

Ligma is a native macOS app that pairs a chat interface with a live preview pane. You describe what you want, Claude builds it as a self-contained HTML file, and you see it render in real-time. Then you iterate — adjust colors, move elements, swap layouts — all through conversation.

## How it works

1. **Describe a design** — type what you want in the chat (e.g. "A SaaS analytics dashboard with sidebar nav")
2. **See it live** — Claude generates HTML/CSS/JS and the preview pane updates instantly
3. **Iterate** — ask for changes, sketch annotations on the preview, attach reference images
4. **Save & organize** — save views and components to a project library

## Features

- **Live preview** with auto-refresh on file changes
- **Sketch annotations** — draw directly on the preview to point at what you want changed (freehand, rectangles, circles, arrows, lines, text)
- **Element picker** — click any element in the preview to extract it as a reusable component
- **Component library** — save, name, browse, and attach components to chat so Claude can reference them
- **Project system** — organize designs by project, each with its own assets, components, and design brief
- **Design briefs** — set color palettes and design instructions that get prepended to every conversation
- **Version history** — browse through every iteration with back/forward navigation
- **Save to library** — save full views or individual components with thumbnails
- **Build specs** — export structured specs with component trees, color palettes, and typography
- **Asset management** — import images, drag & drop onto the preview
- **Viewport presets** — Auto, Mobile, Tablet, Desktop
- **Codebase extraction** — point Ligma at a real codebase and it'll analyze the design system

## Requirements

- macOS 14+
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated

## Install

```bash
git clone https://github.com/justvibes99/ligma.git
cd ligma
./install.sh
```

This builds a release binary and assembles `Ligma.app` in `~/Applications/`.

## Development

```bash
# Run debug build directly
./start.sh

# Or build release and install
./install.sh
```

The app is a single Swift file (`Sources/MockupApp.swift`) built with Swift Package Manager. No Xcode project needed.

## Architecture

- **SwiftUI + WebKit** — native macOS app with a WKWebView for the live preview
- **Claude Code CLI** — chat messages are sent to `claude` as a subprocess with `--output-format stream-json`
- **File-based** — designs are plain `.html` files in `~/ligma/library/{project}/`
- **Single file** — the entire app is one `MockupApp.swift` file (~7k lines)

## License

MIT
