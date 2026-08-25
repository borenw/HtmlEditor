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

The right pane is a live preview you can type straight into, on any page. Clicking in either pane
scrolls the other to the matching spot. The app reopens whatever you had open last time.

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
| Deselect a picture | Esc |

## Editing in the preview (⌥⌘E)

Type in the rendered page and the markup pane follows. The edit is applied **surgically**: only the
element you actually touched is rewritten, located by its recorded source offset. Everything else in
the file — indentation, attribute order, scripts, the elements you didn't touch — is left byte for
byte as you wrote it.

That precision is what makes this safe. Serializing the whole rendered document back into the file
would reformat all of it and, worse, bake in whatever the page's scripts had built at runtime: a copy
button created by a script would be written into the markup *without* the `onclick` its script
assigned in JavaScript, leaving one dead button plus a fresh one on the next load. Patching a single
element avoids all of that.

Two things to know:

- The element you edit is re-serialized by WebKit, so its own indentation and attribute order may
  change. Its neighbours are untouched.
- `designMode` routes clicks to the editor, so the page's own buttons don't respond while editing is
  on. ⌥⌘E turns it off for a live browser view where scripts and buttons behave normally.

Pasting a picture into the preview saves it next to the document exactly as it does in the markup pane.

### Moving and resizing pictures

While preview editing is on, click a picture to select it — a frame with eight handles appears.

- **Drag the picture** to place it anywhere on the page. The first drag lifts it out of the text flow
  and writes `position:absolute` with `left`/`top`; after that it stays exactly where you put it.
- **Drag a corner handle** to resize with the proportions kept; **edge handles** stretch one axis.
  Dragging a top or left handle grows the picture the other way and keeps the anchored corner put.
- **Esc** deselects, and so does leaving edit mode.

Offsets are measured from whatever the picture's real containing block is — a positioned ancestor if
there is one, otherwise the page itself. `offsetParent` is *not* what decides this: it reports `<body>`
when nothing above is positioned, while the actual containing block is then the initial one anchored at
the document corner, and trusting it shifts every picture by the body margin on the first drag.

The handles are drawn in a fixed overlay tagged `data-he-ui`, stripped on the way back with the offset
stamps, so no editor chrome ever reaches your file. Each drop or resize is one undoable step (⌘Z),
and only the `<img>` tag itself is rewritten.

Panes stay in sync through a `data-he-pos` attribute stamped onto each opening tag when the preview
is rendered. It records the tag's character offset in the source, which is what lets a click on either
side find its counterpart and what tells a preview edit which element to patch. The attribute exists
only in the rendered copy — it is stripped before markup comes back from the preview, and it never
reaches your saved file.

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
