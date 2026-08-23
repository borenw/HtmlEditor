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

The right pane is a live preview, and on an ordinary page you can type straight into it. A page
containing `<script>` opens read-only instead, so its buttons and scripts keep working like they do
in a browser — ⌥⌘E overrides the choice either way. Clicking in either pane scrolls the other to the
matching spot. The app reopens whatever you had open last time.

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

## Editing in the preview (⌥⌘E)

The preview is editable by default, except on pages that contain `<script>`, where it starts
read-only. ⌥⌘E flips it for the current document. Here is why the distinction exists.

Editing the rendered page means putting it in `designMode`, and that has two consequences. Clicks go
to the editor instead of the page, so interactive controls — a click-to-copy button, say — stop
responding while it's on. And when you type, the markup pane is rewritten by serializing the *live*
document, which is not the same text you wrote:

- WebKit normalizes it. Indentation and attribute order become WebKit's.
- Anything the page's own scripts built at runtime becomes permanent markup. A copy button generated
  by a script gets written into the file, without the `onclick` the script assigned in JavaScript —
  so on the next load you have one dead button plus a fresh one the script adds. This is why the app
  warns you before enabling preview editing on a page that contains `<script>`.

Editing in the markup pane never touches your formatting, and the preview stays a faithful render of
it. That is the whole reason for the split default: script-free pages round-trip through the DOM
safely and open ready to edit on both sides, while scripted ones stay read-only until you say
otherwise.

Edits sync back as one undoable step (⌘Z restores), and pasting a picture into the preview saves it
next to the document exactly as it does in the markup pane.

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
