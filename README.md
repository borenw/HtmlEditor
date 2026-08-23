# HtmlEditor

A small native macOS app for editing `.html` files, built so that **pasting a picture just works**:
the image is written to disk next to the HTML file and an `<img>` tag is inserted at the cursor.

No Electron, no dependencies — AppKit and WebKit only.

## Install

Paste this into Terminal — it builds from source and drops the app in `/Applications`, then opens it:

```sh
curl -fsSL https://raw.githubusercontent.com/borenw/HtmlEditor/main/install.sh | bash
```

The only requirement is the Xcode Command Line Tools (`xcode-select --install`); full Xcode is not
needed. Re-run the same line any time to update. To uninstall, drag `HtmlEditor.app` to the Trash.

## What it does

1. **Open an existing `.html` file** — File ▸ Open… (⌘O), or drop the file on the app icon.
2. **Edit the markup** — the left pane is a plain-text HTML editor, and it's where you start by default.
3. **Paste a picture** — ⌃V (or ⌘V). The image is saved into the same folder as the `.html` file
   and `<img src="the-image.png" alt="">` is inserted where the cursor is.
4. **Save** — ⌘S.

The right pane is a live preview, and it's editable too — type in it and the markup pane updates to
match. Clicking in either pane scrolls the other to the matching spot. The app reopens whatever you
had open last time.

## Build from a clone

```sh
git clone https://github.com/borenw/HtmlEditor.git
cd HtmlEditor
./build.sh              # builds into build/HtmlEditor.app, doesn't install
open build/HtmlEditor.app
```

`./install.sh` from a clone does the same but installs to `/Applications`.

Both scripts ad-hoc sign the bundle and clear the quarantine flag, so there's no Gatekeeper detour.

`Package.swift` is also included for `swift build`, but that path needs full Xcode — SwiftPM
can't resolve a platform SDK from the Command Line Tools alone. `build.sh` is the supported route.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New | ⌘N |
| Open… | ⌘O |
| Save | ⌘S |
| Save As… | ⇧⌘S |
| Paste (incl. images) | ⌃V or ⌘V |
| Toggle preview | ⇧⌘P |
| Refresh preview | ⌘R |
| Find / Find Next / Previous | ⌘F / ⌘G / ⇧⌘G |
| Edit in preview (on/off) | ⌥⌘E |

## Two-way editing

The preview runs with `designMode` on, so you can type directly into the rendered page. Edits are
serialized back into the markup pane (as one undoable step, so ⌘Z works), and pasting a picture there
saves the file next to the document exactly as it does in the markup pane.

One caveat worth knowing: when you edit in the preview, the markup is re-serialized by WebKit, which
normalizes it — indentation and attribute order are WebKit's, not yours. Editing in the markup pane
never touches your formatting. Turn preview editing off with ⌥⌘E if you want the rendered pane to
stay strictly read-only.

Panes stay in sync through a `data-he-pos` attribute stamped onto each opening tag when the preview
is rendered. It records the tag's character offset in the source, which is what lets a click on either
side find its counterpart. The attribute exists only in the rendered copy — it is stripped before
markup comes back from the preview, and it never reaches your saved file.

## How image pasting works

`PastedImage` reads the pasteboard in this order:

- **A copied image file** — the original file is copied over, keeping its name (sanitized) and format.
- **Raw PNG or JPEG data** — screenshots and "Copy Image" from a browser — written as `pasted-image.png`.
- **Anything else `NSImage` understands** — re-encoded to PNG.

Names never collide: an existing `pasted-image.png` makes the next one `pasted-image-1.png`.
Non-image pasteboard content falls through to a normal text paste.

Because images are stored beside the document, the file needs a location on disk first. Pasting into
an unsaved document prompts you to Save As, then completes the paste.

## Layout

```
Sources/HtmlEditor/
  main.swift                   app entry point
  AppDelegate.swift            menu bar
  EditorWindowController.swift window, open/save, preview, paste handling
  MarkupTextView.swift         plain-text editor that intercepts image pastes
  PastedImage.swift            pasteboard → image file on disk
```

## License

MIT — see [LICENSE](LICENSE).
