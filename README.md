# Recents

A macOS menu-bar app that replaces the Apple menu's **Recent Items** with a
browsable deck of cards — each one showing the app's actual last window or the
document's actual first page, rather than a name and a generic icon.

Press **⇧⌘Space** anywhere. There is no Dock icon.

```bash
./build.sh            # debug build → Recents.app
./build.sh release    # optimised build
open ./Recents.app
```

Requires macOS 14+. Liquid Glass needs macOS 26; below that the glass mode falls
back to `NSVisualEffectView` vibrancy.

---

## What it is

The deck is not a list that resembles the Apple menu — it reads the same files
the Apple menu reads, and preserves their order exactly. Three sources are
merged, each covering the others' gaps:

| Source | Contributes |
|---|---|
| `RecentApplications.sfl4` | Apps in true recency order — the deck's headline cards |
| `ApplicationRecentDocuments/com.apple.preview.sfl4` | The main deck's documents: the last few files you read in Preview, in Preview's order |
| `RecentServers.sfl4` | Network volumes, the menu's third list |
| Spotlight (`NSMetadataQuery`) | Real timestamps for those documents, and the change feed that says when to look again |
| `ApplicationRecentDocuments/*.sfl4` + Office's private MRUs | What each app card expands into, one swipe behind it |

Applications lead, then documents, then servers. Within each group the shared
file list's own order is preserved and never re-sorted, and nothing is
interleaved into it. `--parity` exists to prove that claim has not drifted.

The main deck carries **only Preview's documents** — seven by default, adjustable
in Settings — because every other app's recents already sit one swipe behind that
app's own card. Preview is the app with nothing else to expand into: a PDF opened
there belongs to no project and no workspace, so it earns a place in the main
rail. Everything else is reached by finding the app and swiping.

That swipe has to be known about to be used, though, so the flat rail is there
for anyone who wants it: **Settings → Show → All files** puts every app's recents
on the main deck, newest first. It is the one place the deck departs from macOS's
own order, because across sixty per-app lists there is no macOS order to
copy — so those cards are marked as timestamp-ordered and `--parity` reports them
as unchecked rather than passing them on a meaningless comparison.

---

## Features

### Browsing

- **Circular rail** — past the last card it continues into the first. Distance
  from centre is measured the short way around the ring, so wrapping slides
  forward one step rather than rewinding the whole rail. Auto-disabled below
  three items.
- **Card geometry as one continuous number** — tilt, depth, scale, dimming and
  parallax are all functions of a card's fractional distance from centre, which
  is what keeps keyboard and trackpad navigation on one code path.
- **Two card shapes** — documents portrait (page preview), applications landscape
  (their last window at ≈25% of real size).
- **The deck grows with the window** — height drives card size, width reveals
  more of the rail. Scale is quantised to 0.05 steps so a resize drag does not
  mint a new thumbnail render per pixel.

### Previews

- **App window screenshots** — each app card shows *your* work, not an icon,
  re-read whenever a window appears rather than only when one is already there.
- **Live previews** — moving thumbnails of windows that are minimised, hidden or
  buried, read from the window server because the public capture APIs cannot
  reach them.
- **Quit apps keep their last frame**, with an age badge.
- **Document thumbnails** via QuickLook, through a three-tier cache (memory LRU →
  disk → render) keyed on modification date, size, point size and display scale,
  so editing a file invalidates its thumbnail for free.
- **Peek (Space)** — the *whole* document, not the cropped card: real
  `QLPreviewView` and `PDFView`, with gesture paging, a page counter, and
  scrollers replaced by ambient cues.

### Dock previews

- **Hover a Dock icon and its windows appear above it** — one live thumbnail per
  window, minimised ones included, drawn by the same engine as the deck's cards.
  macOS shows a static Exposé grid only after a click-and-hold; this is the
  moving thumbnail Windows has had since Vista, so a video in a minimised window
  keeps playing in the preview.
- **Click one to bring that window forward.** ✕ closes it and ⤢ maximises it,
  on the highlighted thumbnail only — controls pinned over every picture would
  turn a glance into a form. No minimise button: a Dock preview is already where
  minimised windows live.
- **A running app with nothing open** shows the last frame Recents ever saw of
  it, labelled with what a click will really do — reopen the document in the
  picture, or start a fresh window. An app that is not running gets no panel.
- **Off by default**, and the one feature that needs Accessibility as well as
  Screen Recording. Neither degrades into something useful: without the first
  the Dock cannot be asked what the pointer is over, without the second there
  are no pixels.

### Acting on an item

- **Open** — ↩, click the centred card, or double-click any card. Double-click
  works inside a peek too.
- **Clear Menu (⇧⌘⌫, or the menu bar item)** — performs the Apple menu's own
  *Recent Items ▸ Clear Menu* for real, emptying macOS's lists system-wide.
  Confirms first; no undo. Deliberately not on a bare arrow key: it is an
  irreversible change to the system, and it used to sit on ↑, one key away from
  the two that merely move between cards.
- **Forget** — flick a card up (the iPhone app-switcher gesture), press ↑, or
  press ✕.
  Recorded in Recents' own suppression list, undoable with ⌘Z. A flick is dated,
  and using the item again overrules it — forgetting VLC does not hide VLC
  forever, only until you next reach for it.
- **Pin** — ⌘P. Pinned items hold the front of the deck in pin order, even while
  filtering.
- **Reveal in Finder**, **copy path** — from the card's hover bar.
- **All files (opt-in)** — every app's recent documents on the main rail instead
  of only Preview's, ordered by when you last opened each one, each card badged
  with the app that actually opened it. Off by default.
- **The count stops where the deck does** — the *Show n documents* stepper cannot
  be raised past the number of documents that actually exist, and says so
  underneath: "All 8 there are." A stored number above that ceiling is held down
  for display rather than overwritten, since the list will be longer again.
- **Type-to-filter** — subsequence matching across filename, owning app and
  extension, so `bus709` finds `BUS709_OReillys_Sustainability_Presentation.pptx`
  and `word` narrows to Word documents though no filename contains it.

### Appearance

- **Liquid Glass** (macOS 26) — `NSGlassEffectView` for the window ground and
  `.glassEffect(_:in:)` for every card, chip and pill. Regular or Clear material,
  with an optional tint.
- **Solid** — an opaque window in a colour of your choosing, given an explicit
  light or dark appearance matched to its luminance so captions stay readable.
- Switching is immediate and reconfigures the *window*, not just its fill.

### Degradation

The app says what it is missing rather than failing quietly. Without Full Disk
Access the deck shows only what is running and no documents at all, with a banner
saying so; without Screen Recording, app cards show icons instead of windows.
Dock previews are the one feature that cannot degrade — they need both
Accessibility and Screen Recording, and Settings names whichever is absent.

---

## Keyboard

| Key | Action |
|---|---|
| **⇧⌘Space** | Open / close the deck (configurable) |
| **←** / **→** | Move between cards |
| **↩** | Open the centred item |
| **↓** | Expand an app card into that app's own recents |
| **↑** | Forget the centred item, or back out of a sub-deck — the same as flicking the card up |
| **Space** | Peek — full document preview |
| **Home** / **End** | First / last card |
| **⎋** | Close peek → clear filter → close window, in that order |
| **any letter** | Start filtering |
| **⌫** | Delete the last filter character |
| **⌘⌫** | Clear the whole filter |
| **⌘R** | Refresh the deck now |
| **⇧⌘⌫** | Clear Menu — empties macOS's Recent Items system-wide. Asks first. |
| **⌘Z** | Undo the last forget |
| **⌘P** | Pin / unpin |
| **⌘,** | Settings |
| **⌘W** | Close the deck |

With a Dock preview on screen:

| Key | Action |
|---|---|
| **←** / **→** | Move along the row of thumbnails |
| **↩** / **Space** | Act on the highlighted one |
| **⎋** | Dismiss the preview |

The panel never takes keyboard focus, so those keys are read from an event tap
that exists exactly as long as the panel does. Anything with ⌘, ⌥ or ⌃ held goes
straight through to the app in front — ⌘← is Back in a browser, and a preview has
no business eating it.

Trackpad: two-finger swipe scrubs the rail with momentum and snap; a card dragged
more than 90pt up — or flicked with >220pt of projected momentum — is forgotten.

---

## Settings (⌘,)

| Setting | Default |
|---|---|
| Shortcut | ⇧⌘Space (at least one modifier required) |
| Trackpad gesture | Off — a three-finger tap, or four/five fingers, or a double tap |
| Loop endlessly | On |
| Appearance | Liquid Glass — with glass style and tint, or a solid colour |
| Live window previews | On |
| Dock previews | Off — needs Accessibility and Screen Recording |
| Show Applications / Documents / Servers | On |
| All files (every app's recents, not just Preview's) | Off |
| Show _n_ documents | 7 — or 25 under All files, never more than exist |
| Show Folders | Off |
| Restore Forgotten Items | — |
| Clear Captured Window Images | — |

---

## Developer commands

| Command | Does |
|---|---|
| `swift test` | Run the unit suite — pure logic, readers, and the rail's arithmetic |
| `Recents --dump` | Print the merged deck as text, then exit |
| `Recents --dump --watch` | Keep printing on every change |
| `Recents --parity` | Compare the deck against macOS's lists; non-zero on divergence |
| `Recents --selftest-watcher` | Prove the file watcher re-arms (exit 0 = pass) |
| `Recents --selftest-live` | List every window, which are minimised, which are drawing |
| `Recents --selftest-live --verbose` | …preceded by the raw, unfiltered window list |
| `Recents --selftest-dock` | Check the Dock still exposes its tiles through Accessibility, and that hovering one would resolve to real windows |
| `Recents --selftest-dock --panel [app]` | Put a real preview panel on screen for ten seconds and print the `screencapture` line that photographs it |
| `Recents --selftest-dock-close` | Click the close button on a real preview thumbnail, against a scratch window the test makes |
| `Recents --selftest-dock-keys` | Press the arrow keys at a real preview and read back which thumbnail highlighted |
| `Recents --selftest-dock-sweep` | Sweep the pointer along a real preview's row and measure how far the highlight runs behind it |
| `Recents --selftest-menu` | Press ↓ at the real status item menu and read back what it highlighted |
| `Recents --selftest-office` | Check Word/Excel/PowerPoint recents against their private stores (exit 0 = match) |
| `Recents --selftest-gesture [--fingers N] [--taps N]` | Score the bound trackpad gesture live for 45s; the flags try another shape without changing the setting |
| `Recents --render out.png [--flat] [--solid\|--glass] [--size WxH]` | Render the deck offscreen to a PNG |
| `Recents --render-settings out.png` | Render the Settings window offscreen |
| `Recents --show` | Open the deck immediately on launch |

`--render` exists because `screencapture` needs a Screen Recording grant a build
script has no business demanding. `--flat` disables the 3D card tilt, which
`cacheDisplay` cannot composite.

The two kinds of test answer different questions and neither replaces the other.
`swift test` is hermetic: it builds its own `.sfl4` archives, Office bookmark
stores and state files in a scratch directory, so it says whether the code is
right without saying anything about this machine. The `--selftest-*` harnesses
are the opposite — they make no assertions about the code and instead check that
the undocumented surfaces it stands on (the Dock's accessibility tree, Office's
private MRU, minimised windows having readable pixels) are still where they were
on the machine in front of you.

---

## File structure

```
.
├── README.md
├── Package.swift                      SPM manifest (Swift 6 tools, macOS 14+)
├── build.sh                           compile → bundle → sign
├── Resources/
│   └── Info.plist                     LSUIElement, bundle id com.recents.deck
├── Tests/RecentsTests/                unit suite — `swift test`
│   ├── TestSupport.swift              item builders, scratch dirs, fixture writers
│   ├── FuzzyFilterTests.swift         matching and ranking
│   ├── DeckRailTests.swift            the rail's modular arithmetic
│   ├── DeckMetricsTests.swift         card geometry and its quantisation
│   ├── RecentItemTests.swift          identity, naming, staleness
│   ├── UserStateTests.swift           pins, dated flicks, migration
│   ├── PreferencesTests.swift         defaults, clamping, surviving a bad plist
│   ├── PersistedIdentifiersTests.swift  the defaults keys and paths that must not drift
│   ├── SharedFileListReaderTests.swift  .sfl4 decode and the ok/denied/missing verdict
│   ├── OfficeRecentsReaderTests.swift   the private MRU parse
│   ├── RecentsStoreOrderingTests.swift  recency ordering and sub-deck pruning
│   ├── DockPreviewLayoutTests.swift   fitting the preview row to its screen
│   ├── DockPreviewSelectionTests.swift  the highlight the pointer and keys share
│   └── ChromeTests.swift              shortcut glyphs, colours, render flags
└── Sources/Recents/
    ├── main.swift                     entry point; CLI harnesses
    ├── AppDelegate.swift              wiring, hotkey rebinding, first-run prompt
    ├── Model/
    │   ├── RecentItem.swift           one entry; .application, .document or .server
    │   ├── SharedFileListReader.swift .sfl4 parsing — macOS's own lists
    │   ├── OfficeRecentsReader.swift  Word/Excel/PowerPoint private MRUs
    │   ├── AppleMenuRecents.swift     Clear Menu — empties those lists for real
    │   ├── SpotlightSource.swift      live NSMetadataQuery feed
    │   ├── RecentsStore.swift         the merge; single source of truth for the UI
    │   ├── ParityReport.swift         --parity; deck order vs. the lists
    │   ├── UserState.swift            pins + suppressions (JSON)
    │   ├── Preferences.swift          settings + shortcut (UserDefaults)
    │   ├── FileWatcher.swift          re-arming watcher, survives atomic replace
    │   ├── WatcherSelfTest.swift      proves the watcher survives replacement
    │   └── OfficeSelfTest.swift       --selftest-office
    ├── Thumbnails/
    │   ├── ThumbnailCache.swift       QuickLook previews, three-tier cache
    │   ├── AppWindowCapture.swift     window screenshots + capture lifecycle
    │   ├── LiveWindowPreview.swift    moving previews, attention-driven refresh
    │   ├── WindowServerCapture.swift  reads minimised/hidden/buried windows
    │   └── LivePreviewSelfTest.swift  --selftest-live
    ├── Dock/
    │   ├── DockHoverWatcher.swift     which tile the pointer is over
    │   ├── DockProbe.swift            the Dock's own accessibility tree
    │   ├── DockWindows.swift          a tile's windows, and what acting on one does
    │   ├── DockPreviewController.swift  panel lifecycle, placement, subscriptions
    │   ├── DockPreviewView.swift      the hover panel itself
    │   ├── DockPreviewLayout.swift    fitting the row to the screen it opens on
    │   ├── DockPreviewSelection.swift the highlight the pointer and keys share
    │   ├── DockPreviewKeys.swift      the event tap that reads ←/→/↩/⎋
    │   ├── DockSelfTest.swift         --selftest-dock
    │   ├── DockCloseSelfTest.swift    --selftest-dock-close
    │   ├── DockKeySelfTest.swift      --selftest-dock-keys
    │   └── DockSweepSelfTest.swift    --selftest-dock-sweep
    ├── Input/
    │   ├── HotKey.swift               Carbon global shortcut (no Accessibility)
    │   ├── TrackpadGesture.swift      private multitouch tap-to-summon
    │   ├── TrackpadGestureSelfTest.swift  --selftest-gesture
    │   ├── MenuBarItem.swift          status bar item and its menu
    │   └── MenuSelfTest.swift         --selftest-menu
    └── UI/
        ├── DeckWindow.swift           the window, its controller, appearance switch
        ├── DeckView.swift             layout, keyboard, trackpad
        ├── DeckRail.swift             the rail's arithmetic, with no view attached
        ├── CardView.swift             one card: geometry, quick actions, flick
        ├── ClearMenuPrompt.swift      the Clear Menu confirmation, shared by both doors
        ├── DeckMetrics.swift          card geometry scaled to the window's size
        ├── DeckAppearance.swift       glass/solid modes and the derived palette
        ├── GlassBackground.swift      the window ground in either mode
        ├── ThumbnailImage.swift       async preview with instant icon fallback
        ├── PeekView.swift             full-document preview and its scroll cues
        ├── FuzzyFilter.swift          subsequence scoring for type-to-filter
        ├── SettingsWindow.swift       settings UI and the shortcut recorder
        ├── DeckSnapshot.swift         --render, for development
        └── RenderOptions.swift        development-only render switches
```

Generated, not source: `.build/` (SPM), `Recents.app` (the built bundle).

---

## Storage

| Path | Contents |
|---|---|
| `~/Library/Application Support/Recents/state.json` | Pins, and suppressions with the date each was made |
| `~/Library/Caches/Recents/thumbnails/` | Document previews, SHA256-keyed |
| `~/Library/Caches/Recents/windows/` | App window screenshots plus a JSON sidecar per bundle |
| `UserDefaults` (`com.recents.deck`) | Shortcut, display and appearance settings |

Deleting `thumbnails/` is always safe — it rebuilds on demand. Deleting
`windows/` is safe but lossy in one direction: those frames are the only record
of what a minimised or quit app last looked like, and a window that is no longer
on screen cannot be re-captured. They return one app at a time, as each is
next used.

---

## Permissions

| Permission | Buys | Without it |
|---|---|---|
| Full Disk Access | Reading `.sfl4` — true recent-items order, and Clear Menu | Running apps only, no documents, with a banner saying so |
| Screen Recording | App cards showing their last window, and Dock previews | App cards show icons; no Dock previews |
| Accessibility | Which Dock tile the pointer is over, the keys a preview answers, and re-capturing a window the moment it is restored or opened | No Dock previews; window captures refresh less precisely |

Nothing leaves the machine. No network code, no telemetry; every cache is
user-private.

Recents signs with a local identity (see `build.sh`) rather than ad-hoc, because
TCC keys grants to a bundle's **designated requirement** — and an ad-hoc
requirement contains the binary's cdhash, which changes on every build. That is
why permissions used to vanish after each rebuild.
