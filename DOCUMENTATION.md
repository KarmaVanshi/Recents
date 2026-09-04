# Recents — Full System Documentation

An interactive replacement for the Apple menu's **Recent Items**: a card deck of
the applications and documents you actually used, summoned by a global shortcut.

> The real Apple menu is SIP-protected — no public or private API can add to or
> restyle it. Recents does not modify the Apple menu. It stands beside it as a
> faster surface reading the *same underlying data*, which is what makes it a
> genuine replacement rather than a separate list that drifts out of sync.

That claim is load-bearing, so it is stated precisely in § 3 and checked
mechanically by `Recents --parity` (§ 8).

---

## 1. Quick start

```bash
./build.sh            # debug build → Recents.app
./build.sh release    # optimised build
open ./Recents.app
```

Press **⇧⌘Space** anywhere. Recents lives in the menu bar (clock icon); it has
no Dock icon. A **three-finger tap** on the trackpad does the same thing, once
switched on in Settings — where the tap can also be changed to four or five
fingers, or to a double tap.

---

## 2. Every keyboard shortcut

### Global

| Shortcut | Action |
|---|---|
| **⇧⌘Space** | Open / close the deck. Configurable in Settings. |
| **Three-finger tap** | The same, from the trackpad. Off by default, and the tap itself is configurable — see Settings. |

### Inside the deck

| Key | Action |
|---|---|
| **←** / **→** | Move between cards. Wraps around when looping is on. |
| **↩** Return | Open the centred item, then close the deck |
| **↓** | Expand an app card into that app's own recents (§ 4.3b) |
| **↑** | Forget the centred item, or back out of a sub-deck — the same as flicking the card up |
| **Space** | Peek — full document preview. Press again to close. |
| **Home** | Jump to the first card |
| **End** | Jump to the last card |
| **⎋** Escape | Close peek → clear filter → close window (in that order) |
| **Any letter/number** | Start filtering. Filter appears as a pill under the title. |
| **⌫** Delete | Delete the last filter character |
| **⌘⌫** | Clear the whole filter |
| **⌘R** | Refresh the deck now |
| **⇧⌘⌫** | Clear Menu — empties macOS's own Recent Items, system-wide. Asks first. |
| **⌘Z** | Undo the last "forget" |
| **⌘P** | Pin / unpin the centred item |
| **⌘,** | Open Settings |
| **⌘W** | Close the deck |

Escape is deliberately layered: it dismisses the most specific thing first, so it
never closes the whole window when you only meant to close a preview.

### Inside a Dock preview

| Key | Action |
|---|---|
| **←** / **→** | Move the highlight along the row of thumbnails |
| **↩** Return / **Space** | Act on the highlighted thumbnail |
| **⎋** Escape | Dismiss the preview |

These four are read from an event tap that exists exactly as long as the panel
does, because the panel never takes keyboard focus — see § 4.9. Anything with ⌘,
⌥ or ⌃ held is passed straight through to the application in front.

### Trackpad and mouse

| Gesture | Action |
|---|---|
| **Two-finger swipe** (horizontal) | Scrub the rail, with momentum and snap |
| **Swipe / drag a card up** | Forget it — the iPhone app-switcher gesture |
| **Click** a side card | Select and centre it |
| **Click** the centred card | Open it |
| **Double-click** any card | Open it |
| **Double-click** while peeking | Open the document being previewed |
| **Hover** a card | Sharpen its live preview and light its expand chevron |
| **Hover** a Dock icon | Open that app's window previews, if Dock previews are on (§ 4.9) |

Vertical swipes also scrub the rail, so the gesture works regardless of how
"natural scrolling" is configured.

A card is forgotten when the drag travels more than **90pt** upward, *or* when
its projected momentum exceeds **220pt** — so a short, fast flick counts, exactly
like the iPhone.

---

## 3. What the deck shows

### The data source, and what "mirrors the Apple menu" means

Recents reads the same three files the Apple menu's Recent Items reads, in
`~/Library/Application Support/com.apple.sharedfilelist/`:

| List | File | Shown as |
|---|---|---|
| Recent Applications | `com.apple.LSSharedFileList.RecentApplications.sfl4` | app cards |
| Preview's recents | `…/ApplicationRecentDocuments/com.apple.preview.sfl4` | document cards |
| Recent Servers | `com.apple.LSSharedFileList.RecentServers.sfl4` | server cards |

**The order of entries inside those files is the order macOS itself shows, and it
is reproduced exactly.** Nothing downstream re-sorts them — not by Spotlight
timestamp, not by launch date, not by anything. Everything the lists do not
contain is *appended after* them, never interleaved:

- **Running applications** macOS has not recorded yet. A freshly launched app
  takes a moment to appear in `RecentApplications.sfl4`. Between the list and
  this pass, **every app currently open in the Dock has a card** — the deck
  watches `NSWorkspace` for launches and quits, so that stays true while it is
  on screen rather than only at the moment it was summoned.

Note the middle row. By default the main deck's documents are **not** the Apple
menu's global `RecentDocuments.sfl4`, and deliberately so — see *Documents*
below, which also covers the **All files** opt-in that widens that row to every
app's recents.
Spotlight still runs, but only to supply real `kMDItemLastUsedDate` timestamps
and to notice when something changed; it no longer contributes cards of its own.
When any list cannot be read, a banner says so, because the deck can no longer
claim parity with the list it mirrors. Run `Recents --parity` to check the claim
mechanically (§ 8).

### Applications (first)

- **Card:** the app's **last window**, captured live — not a generic icon.
- **Size:** 378 × 236pt — roughly **25% of a normal window**, landscape.
- **Fallback:** the app icon on a soft gradient, when no capture has ever existed.
- **Minimised or quit apps keep their last frame** rather than reverting to an
  icon, with a badge saying how old it is. See § 6.

### Documents (after)

**The last few files you read in Preview — and only those.** By default seven of
them, adjustable from 1 to 25 under Settings → Show. Settings → Show → **All
files** widens this to every app's recents; see *All files* at the end of this
section.

The main deck used to carry the Apple menu's global recent-documents list plus a
week of Spotlight, which meant every file every app had touched landed in the
main rail. That was the same information twice: each of those apps already
carries its own recents one swipe behind its card (§ 4.2), attributed and in that
app's own order, and the main rail's flat copy was the less useful of the two.

Preview is the exception that earns a place beside the app cards, because it is
the app with nothing to expand into — a PDF opened there belongs to no project
and no workspace. Everything else is reached the way it was always meant to be:
find the app, swipe.

- **Source:** `ApplicationRecentDocuments/com.apple.preview.sfl4`, read directly
  and in its own order. Not filtered out of the cached ownership index, which is
  only authoritative about *which* app claimed a URL, not about order — and which
  is built in the background, so the first summon after launch would have had no
  documents at all.
- **Card:** a real QuickLook page preview — 300 × 380pt portrait.
- **Aspect-fitted, never cropped or stretched.** The whole page is kept; a
  preview smaller than the card is centred at its own size rather than enlarged.
- **Timestamps** come from Spotlight where it has them and from a direct
  `kMDItemLastUsedDate` read where it does not — Spotlight's window is a week,
  and a document read a fortnight ago is still perfectly real.
- **Folders are hidden by default.** Preview does not open folders, so this rule
  is very nearly moot here; it is still applied, because a rule that quietly
  stops holding in one place is worse than a redundant check. Under **All files**
  it stops being moot at all — editors put their project directories in these
  lists, which is what the preference was written for.

#### All files (opt-in, off by default)

The narrow rail is a design decision, not a limitation. But the swipe has to be
*known about* to be used, and a deck that will not simply show you the file you
had open five minutes ago — because it happened to be open in Numbers — is
answering a question its own name does not ask. So the flat rail is available,
as an opt-in, under Settings → Show → **All files**.

- **Source:** every per-app list in `ApplicationRecentDocuments/`, plus Office's
  private MRUs, plus the Apple menu's global `RecentDocuments.sfl4`, unioned.
  The global list is not enough on its own and measurably so: on a real machine
  it holds a handful of entries from one or two editors and **nothing from
  Preview**, so reading it alone produced an "all files" rail *shorter* than the
  Preview-only one it replaced.
- **Order:** `kMDItemLastUsedDate`, newest first. This is the one place the deck
  departs from macOS's own sequence, and it does so because there is no sequence
  to copy: within one app's list there is a real recency order, but no list ranks
  another app's entries against it. Files with no timestamp at all sort last, in
  a stable order, rather than being dropped.
- **Marked as what it is.** These cards carry `origin: .spotlight`, not
  `.sharedFileList`, so `isAppleMenuAuthoritative` is false for them and
  `--parity` reports the document group as *unchecked* rather than passing it on
  a comparison that would have been meaningless. Applications and servers either
  side of it are still held to the Apple menu's order.
- **Attribution is per card**, from the same ownership index that badges an app
  card's sub-deck — which app *did* open the file, not which app would. When the
  index has not been built yet, LaunchServices answers instead; an unbadged card
  is worse than one badged with the default app.
- **Built off the main thread.** The union runs to several hundred URLs, each
  needing a metadata lookup before it can be ordered. That happens on the same
  background pass that builds the ownership index, and the result is cached; the
  first summon after launch shows what it has and the build folds the rest in
  with a second refresh, exactly as the app-card chevrons do.
- **Count:** stored separately from the Preview-only count (default 25, up to
  100), because the two numbers answer different questions — seven is a morning's
  reading, this is a day's work across every app — and sharing one value would
  throw the user's choice away on every toggle.

#### The counter stops where the deck does

The *Show n documents* stepper cannot be raised past the number of documents the
deck could actually put on the rail. Asking for fifty on a machine whose recents
hold twelve sets a number nothing can satisfy, and a deck that then stops at
twelve reads as though it were ignoring the setting above it. `RecentsStore`
publishes `availableDocumentCount` — the survivors of every filter, uncapped —
and Settings uses it as the ceiling and says the number out loud underneath
("All 8 there are.", "31 available.").

A stored value above that ceiling is **held down for display, not written down**:
the list was longer when the number was chosen and will be again, so the
preference is left alone until the user actually moves the control.

Counting them costs a full pass where the old code stopped dead at the cap. Past
the cap the questions are answered as cheaply as they can be — two stats, no
card built, and no timestamp lookup unless a flick is on file for that URL and
might have expired.

### Servers (last)

Network volumes from `RecentServers.sfl4` — the Apple menu's third list. There is
nothing to preview (an unmounted share has no contents, and reaching for them
would mean a blocking network round trip), so the card shows the network icon and
the host name. Usually this list is empty.

### Thumbnail resolution

Every preview is requested at the card's **physical pixel size** — its point size
times the backing scale of the screen the deck is actually on, not
`NSScreen.main`, which differs on a mixed Retina/non-Retina setup. Two rules keep
it sharp:

1. **Ask for enough pixels.** The cache key includes the display scale, so a 1×
   render is never served to a Retina card, and the disk tier reloads a PNG at the
   scale it was rendered for rather than letting the point size collapse.
2. **Never enlarge past native.** QuickLook substitutes a small enriched icon for
   file types it cannot render; drawing a 128px icon across a 300pt card is what
   made those cards look broken. Anything smaller than the card is drawn 1:1.

App window captures follow the same rules, at the display's true backing scale,
capped at 2600px on the long edge.

### Ordering

1. **Pinned items**, in the order they were pinned
2. **Applications** — `RecentApplications.sfl4` order, then running apps it has
   not caught up with
3. **Documents** — `com.apple.preview.sfl4` order, capped at Settings → Show →
   *Show N documents* (default 7). Under **All files**, every app's recents
   ordered by `kMDItemLastUsedDate` instead, capped at its own count (default 25)
4. **Servers** — `RecentServers.sfl4` order

---

## 4. Features

### 4.1 Circular browsing

When **Loop endlessly** is on (default), the deck has no ends: past the last card
it continues into the first. Each card's distance from centre is measured the
short way around the ring, so wrapping slides forward by one step rather than
rewinding the entire rail.

Automatically disabled below three items, where wrapping would just make two
cards jitter.

### 4.2 Peek (Space)

Opens the **whole** document, not the cropped thumbnail the card shows. This
embeds AppKit's `QLPreviewView` — the same renderer Finder's Quick Look uses —
so multi-page documents scroll and page normally, and media plays.

For applications, peek shows the captured window at full size.

**Opening from a peek.** ↩ and a **double-click** both open the item you are
previewing — the same two gestures that open a card in the deck, so looking at
something and then deciding to open it needs no detour back out.

> The double-click is read by the deck's own event monitor rather than by a
> SwiftUI tap. The peek's renderers (`PDFView`, `QLPreviewView`) are real AppKit
> views and consume clicks before any gesture layered over them sees anything, so
> there is no modifier to attach. Only double-clicks are taken; single clicks
> still reach the renderer for text selection, video controls, and the tap on the
> surrounding scrim that closes the peek.

Opening always closes the peek first. The deck window is ordered out rather than
torn down, so its view — and every piece of `@State` on it — survives dismissal;
a peek left standing would still be standing on the next summon. The same reset
now happens however the deck is dismissed (⌘W, the red button, the hotkey), which
also clears a stale filter.

### 4.3 Forget, and undo

Flicking a card up — or the ✕ button on the card — removes it from the deck and
keeps it out across relaunches.

It does not keep it out forever. Each flick is stored with the moment it
happened, and any later use of the item — a Spotlight `kMDItemLastUsedDate`
newer than the flick, or an application launched since — supersedes it: the
entry is dropped and the card comes back at whatever rank macOS gives it.

> **Why it lapses.** An undated flick outlives every subsequent use, so an app
> forgotten once stayed invisible while it was running in front of you and macOS
> itself had it at the top of `RecentApplications.sfl4`. That is a permanent
> blocklist, and the gesture promises "not this, not now". Items with no
> timestamp to test — servers, documents Spotlight never indexed — keep the old
> behaviour, because there is no evidence on which to lapse them.

> **What this does and does not do.** There is no supported API to remove a
> single entry from macOS's recent items, and `sharedfilelistd` owns those files
> in memory — writing to them gets clobbered or corrupts your real lists. So
> "forget" records the item in Recents' own suppression list and filters it from
> this deck. It does **not** purge the Apple menu — for that, see Clear Menu
> below.

Undo with **⌘Z** or the Undo button, which stays for 4 seconds. Undo history is
in-memory only and does not survive a relaunch. Restore everything at once via
**Settings → Maintenance → Restore Forgotten Items**.

Pinning an item you previously forgot brings it back, so a pin never silently
does nothing.

### 4.3a Clear Menu (⇧⌘⌫)

**⇧⌘⌫** — and *Clear Apple Menu Recent Items…* in the menu bar — performs the
Apple menu's own **Recent Items ▸ Clear Menu**, for real. It
empties macOS's recent applications, recent documents and recent servers lists,
so every app's  menu is cleared, not just this deck. It asks for confirmation
first, and there is no undo — the menu item it mirrors has none either.

> **How it works.** `LSSharedFileListRemoveAllItems` was the supported route
> until 10.11; `LSSharedFileListCreate` no longer vends the recent-items lists,
> and its `SharedFileList.framework` replacement is private. So Recents does what
> every "clear my recents" recipe does: kill `sharedfilelistd` so nothing is
> holding the lists in memory, delete the three `.sfl4` files, then kill it again
> in case launchd relaunched it mid-deletion and reloaded the old contents. The
> next launch reads three absent files as three empty lists.
>
> Requires Full Disk Access, the same grant that lets Recents read those lists.
> Without it the footer says so rather than silently doing nothing.

Per-app **Open Recent** menus (`ApplicationRecentDocuments/`) are deliberately
left alone, because the real Clear Menu does not touch them either.

The deck will not usually look empty afterwards. Currently-running applications
are not in those lists and remain, and neither are the document cards: those come
from Preview's own per-app list, which Clear Menu leaves alone for the same
reason macOS does.

### 4.3b An app's own recents (↓)

Application cards carry a chevron when the app has recents of its own. **↓**, or
a two-finger swipe down, expands that card into a sub-deck of what that app has
been opening; **↑** or ⎋ backs out to exactly where you were. Opening anything
inside a sub-deck opens it *in that app*, not in whatever the system would
otherwise choose — drilling in from the VS Code card and pressing Return hands
the file to VS Code, not to Finder.

Folders are deliberately kept here, unlike in the main deck. The `includeFolders`
preference exists because editors register project directories as recent
documents and flood the deck with folders duplicating the app cards above them;
inside one app's own list that reasoning inverts, since VS Code's recents are
almost entirely folders and a sub-deck that hid them would be empty.

**Six cards, most recent first.** These lists run to three figures and a sub-deck
you have to scrub through is not a shortcut. The cap is applied after dead
entries are dropped, so it is six documents that open rather than six candidates
of which half no longer exist — and an app whose every recorded document has been
moved or deleted gets no chevron at all rather than one that expands into
nothing.

The chevron appears for Word, Excel and PowerPoint too, which keep their recents
outside the shared file lists entirely — see § 7, *The Office store*.

### 4.4 Pinning

**⌘P** or the pin button. Pinned items hold the front of the deck in the order
you pinned them, and keep that position even while filtering.

### 4.5 Type-to-filter

Start typing. Matching is subsequence-based and scored, searching the filename,
the owning app's name, and the extension — so `bus709` finds
`BUS709_OReillys_Sustainability_Presentation.pptx`, and `word` narrows to Word
documents even though no filename contains it.

Filename matches outrank app-name matches, so typing `pdf` surfaces the PDF you
are reaching for rather than Preview's entire history.

### 4.6 Quick actions

The card at the front of the rail carries a small bar in its top-right corner:

| Button | Action |
|---|---|
| 📌 Pin | Pin / unpin |
| 📁 Reveal | Show in Finder (closes the deck) |
| 📋 Copy path | Copy the full POSIX path |
| ✕ Forget | Remove from the deck |

Only the centred card has it. Hovering a neighbour does not raise one: the bar
acts on the current item, and the current item is what ⌘P, Space and ↩ act on
too — one idea of "this card", not two. To act on a neighbour, centre it first.

The bar also waits for the deck to be the front window. The deck is an ordinary
window that can be left open behind other apps, and a background window spends
its first click on activation rather than on whatever is under the pointer — so a
bar offered on a buried deck would be one whose buttons did nothing until the
second click. Click the deck first, then the button.

### 4.7 Menu bar

- **Left click** — open the deck
- **Right click** (or ctrl-click) — menu: shortcut reminder, app/file counts,
  permission shortcuts, Restore Forgotten Items, Settings, Quit

### 4.8 The deck grows with the window

Resize the window and the cards resize with it, along with the rail spacing, the
corner radii, the app badges and the captions. Everything is one scale factor
away from the base constants, and the factor comes from the area the rail has —
see `DeckMetrics`.

**Height drives size; width drives how much rail you see.** A taller window makes
the cards bigger, because height is what a portrait page preview is short of. A
wider one does not — it reveals more of the rail instead, which is what extra
width is actually good for. Width acts only as a ceiling, so a window dragged
wide but left short cannot grow cards it has no room to show.

| | |
|---|---|
| Scale at the default 1180×660 window | exactly **1.0** — the deck looks precisely as it always has |
| Range | **0.75×** to **2.0×** |
| Step | **0.05** |

The step is not cosmetic. `ThumbnailCache` keys every render on the exact point
size requested, so a card size that tracked the window continuously would mint a
fresh cache entry — and a fresh QuickLook render, and a fresh PNG on disk — for
every pixel of a resize drag. Quantising means a drag crosses a handful of sizes
rather than hundreds, and the ones it lands on are hit again the next time the
window is that big.

Chrome does not scale. The header, footer key hints and the cards' quick-action
buttons keep their size, because they are controls with hit targets to preserve,
not content.

Check it with `--render out.png --size WxH` rather than by eye.

### 4.9 Dock previews (off by default)

Rest the pointer on an app's Dock icon and a row of **live** window thumbnails
opens above the tile — one per window, minimised ones included. macOS shows a
static Exposé grid for a Dock tile only after a click-and-hold; Windows has shown
a moving thumbnail on plain hover since Vista, and that is the behaviour this
reproduces. It draws from the same `LiveWindowPreview` engine as the deck's
cards, so a window looks the same in both places and a video in a minimised
window keeps playing here too.

| Doing this | Does this |
|---|---|
| **Click** a thumbnail | Brings that window forward, restoring it if it was minimised |
| **✕** on the highlighted thumbnail | Closes that window |
| **⤢** on the highlighted thumbnail | Maximises it |
| **←** / **→** | Move the highlight along the row |
| **↩** / **Space** | Act on the highlighted thumbnail |
| **⎋** | Dismiss the preview |

There is deliberately **no minimise button**. A Dock preview is already the place
minimised windows live, so a button that puts one back there is the one action
the panel makes pointless; the two worth having are the two you would otherwise
have to raise the window to reach. Both appear only on the chosen
thumbnail — under the pointer, or wherever the arrow keys have stepped
to — because controls pinned over every picture take space from the picture they
sit on and turn a glance into a form.

**The panel belongs to the pointer.** It is a non-activating `NSPanel` that never
becomes key: hovering the Dock must not take focus from whatever you are working
in, and a panel that stole key status would make looking at a window more
disruptive than switching to it. It appears where the pointer is, follows the
pointer between tiles, and leaves **0.22s** after the pointer commits to
something else — long enough to cross the gap between tile and panel without it
vanishing mid-reach. Dismissal is not driven by mouse events alone: a global
monitor stops reporting the moment the pointer crosses into one of this app's own
windows, so the panel would never hear the pointer enter it and, having heard
nothing, would never hear it leave. A 10 Hz poll while the panel is up answers
both, and costs nothing the rest of the time because it does not run.

> **Why the keys come from an event tap.** The panel never becomes key and this
> app never activates, so every keystroke is being delivered to the application
> in front. A *local* `NSEvent` monitor sees nothing, because nothing is
> delivered here. A *global* monitor would see the keys but cannot swallow
> one — → would step the preview and move the insertion point in the user's
> editor at the same time, which is worse than not answering the key at all. A
> `CGEventTap` can decline to pass an event on, so exactly the keys the preview
> uses are the keys the app in front does not get. Everything else is returned
> untouched, including anything with ⌘, ⌥ or ⌃ held. The tap is created on show
> and torn down on hide: one that outlived the panel would be this process
> reading every keystroke on the system for no reason.
>
> A tap the system switches off for taking too long announces itself with
> `tapDisabledByTimeout`, and is re-enabled on the spot — without that the
> preview would answer keys until the machine was briefly busy and then silently
> stop for the rest of the session.

**What a tile resolves to.** An app that is **not running** gets no panel at all.
A running app with **every window closed** gets one thumbnail: the last frame
Recents ever saw of it, badged as remembered and labelled with what a click will
actually do — because a still cannot lead back to the window it shows. At best it
reopens the document in the picture; otherwise the app simply starts a new
window. When a tile has more windows than the row shows, the panel says so
("6 of 11 windows") rather than silently dropping them.

**Labels sit beside the picture, not on it.** The panel opens over the spot the
Dock's own tooltip would have used, and carries the app's name in a header the
way that tooltip did. Window titles, the minimised badge and the window count are
placed around the thumbnails rather than across them: the labels used to sit
exactly over a window's title bar and tab strip, which is the part of a
screenshot people actually read.

**The row is fitted to the screen it opens on.** `DockPreviewLayout` sizes the
thumbnails against the width the panel's own display allows. It used to lay out
at a fixed thumbnail height whatever it contained, so six windows came to about
1550pt — wider than the laptop screen it was drawn on — and the placement code
can only slide a panel that does not fit, not shrink it, so the far thumbnails
were simply off the display. The same fitted result decides where a thumbnail's
buttons land, which is what lets `--selftest-dock-close` aim at a real close
button instead of reconstructing where it probably went.

**Both permissions are required, and neither degrades.** Without Accessibility
the Dock cannot be asked what the pointer is over; without Screen Recording the
window server returns no pixels. Settings names whichever is missing rather than
leaving a switch that looks broken. Turning the preference on or off takes effect
immediately, so the switch can be judged from the Settings window you are
standing in.

---

## 5. Settings (⌘,)

| Setting | Default | Effect |
|---|---|---|
| **Shortcut** | ⇧⌘Space | Click the field, press any combination. At least one modifier is required. |
| **Trackpad gesture** | Off | Tap the trackpad to open or close the deck |
| **Gesture** | Three-finger tap | Which tap does it: three-, four- or five-finger tap, or a three- or four-finger double tap. Two fingers are not offered — a two-finger tap is the secondary click and a two-finger double tap is smart zoom. The line under the menu says what the shape costs, and warns when this Mac has already bound it (Look Up, three-finger drag). |
| **Loop endlessly** | On | Circular browsing |
| **Appearance** | Liquid Glass | Glass or Solid — see below |
| **Background colour** | System | Solid mode only; follows light/dark until you pick one |
| **Show Applications** | On | Include app cards |
| **Show Documents** | On | Include file cards (Preview's recents only, unless All files is on) |
| **All files** | Off | Every app's recents on one rail, newest first, instead of only Preview's |
| **Show _n_ documents** | 7 / 25 | How many of them — 1–25 for Preview, 1–100 for All files, and never more than actually exist. Disabled when Show Documents is off. |
| **Show Servers** | On | Include network volumes |
| **Show Folders** | Off | Include directories among documents |
| **Live window previews** | On | Moving thumbnails of minimised, hidden and buried windows, read from the window server. Needs Screen Recording. |
| **Dock previews** | Off | Rest the pointer on an app's Dock icon to see live thumbnails of its windows. Needs Accessibility *and* Screen Recording; the line under it says which is missing. |
| **Restore Forgotten Items** | — | Clears the suppression list |
| **Clear Captured Window Images** | — | Deletes all cached screenshots |

Settings persist in `UserDefaults`. Recording a new shortcut rebinds it
immediately — no relaunch.

### Appearance: Liquid Glass and Solid

These are different **window** configurations, not two fills painted into the
same window, which is why the setting reaches AppKit rather than staying in
SwiftUI:

Liquid Glass here means **Apple's Liquid Glass**, the macOS 26 (Tahoe) material —
`NSGlassEffectView` for the window ground and SwiftUI's `.glassEffect(_:in:)` for
every card, chip, capsule and hint pill — not a frosted blur that resembles it.
The difference is visible: real Liquid Glass lenses and refracts the backdrop at
its edges, carries a specular highlight along its rim, and adapts its own
contrast to what is behind it.

| | Liquid Glass | Solid |
|---|---|---|
| Window | `isOpaque = false`, clear background | `isOpaque = true`, filled with the chosen colour |
| Backdrop | `NSGlassEffectView` (macOS 26+) | none — the effect view is torn down, not hidden |
| Cards, chips, peek | `.glassEffect()`, grouped in `GlassEffectContainer` | opaque colours derived from the ground |
| Controls | `.glassEffect(.regular.interactive())` | opaque chip colour |
| Scrim | a whisper for Regular, more for Clear | none; the ground already guarantees contrast |

**Glass style** — the two materials Apple actually ships:

- **Regular** — the standard material. Adapts its contrast to the backdrop.
- **Clear** — thinner and far more transparent, intended for media-rich
  backdrops. It protects legibility much less, so the deck lays down a heavier
  scrim behind captions and key hints when it is chosen.

**Tint** — Liquid Glass tints rather than fills: the colour bends the light the
material is already refracting instead of painting over it. Optional, and
separate from the Solid mode colour picker.

On **macOS 14 and 15** there is no Liquid Glass, so this mode falls back to
`NSVisualEffectView` vibrancy and `Material`. The Settings copy says so rather
than claiming a material the OS does not have, and the Regular/Clear and tint
controls are hidden.

Changing any of it **takes effect immediately** — the deck is not rebuilt, only
its ground. In Solid mode the colour defaults to the system window background, so
it follows light and dark mode on its own; pick a custom colour and the window is
given an explicit light or dark appearance to match its luminance, so captions
stay readable on a dark colour chosen while macOS is in light mode.

---

## 6. Permissions

### Code signing, and why permissions used to vanish

Every rebuild used to revoke Screen Recording and Full Disk Access. That was not
macOS being awkward — it was a consequence of ad-hoc signing.

TCC records a grant against the bundle's **designated requirement**. Ad-hoc
signing (`codesign -s -`) builds that requirement out of the binary's cdhash, so
the stored requirement for Recents was literally:

```
cdhash H"dffd29847ba4ccf7a89679794455c8ed4a2161e9"
```

Every build produces a different cdhash, so the grant stopped matching and macOS
ignored it — while still *showing* the app as allowed in System Settings, which
is what made it confusing.

Signing with a real identity, even a self-signed one, changes the requirement to:

```
identifier "com.recents.deck" and certificate root = H"<certificate hash>"
```

There is no cdhash in it. It is byte-identical across every rebuild, so a
permission granted once stays granted. Verified by signing two different binaries
and diffing: cdhashes differed, designated requirements matched exactly.

`build.sh` looks for a code-signing identity named **Recents Local Signing** in
the login keychain, uses it when it is there, and falls back to ad-hoc when it is
not. Creating that identity is a one-off local step: a self-signed **Code
Signing** certificate, with `codesign` granted access to the key so signing never
stops to ask. The helper that makes it is not carried in this repository — it
writes to a keychain, which is the one part of this setup that belongs to a
machine rather than to the project.

The certificate is deliberately *not* added to any trust store — `codesign`
accepts an untrusted identity, and trusting it would need an admin prompt for no
benefit.

The build also runs `xattr -cr` before signing, because Finder attaches metadata
that makes `codesign --verify --strict` reject the bundle as carrying "resource
fork, Finder information, or similar detritus".

Keep the project out of a synchronising folder. Under iCloud's Desktop &
Documents sync, `com.apple.FinderInfo` is re-attached within moments of being
cleared, so signing loses the race; `build.sh` retries and then refuses to leave
an ad-hoc signature behind, because an ad-hoc designated requirement is
cdhash-based and costs the app every permission it has been granted.

This is a **local development** identity. It is trusted by nothing and notarised
by nobody, which is fine for a build that only ever runs on this machine.
Distributing Recents would need a real Apple Developer ID.

> **One-off after switching:** the signature identity changed, so the old grant
> no longer applies. Reset and re-grant once —
> `tccutil reset ScreenCapture com.recents.deck`, then click the banner in the
> deck. Every rebuild after that keeps it.
>
> Beware duplicate bundles. A stray `Recents 2.app` with the same
> `CFBundleIdentifier` makes LaunchServices resolve `com.recents.deck` to two
> paths, and permissions can attach to the wrong one.


Recents never blocks on a permission and always says which one it is missing.
Full Disk Access and Screen Recording are both optional — the deck degrades and
carries on without either. **Dock previews are the exception**: they need
Accessibility *and* Screen Recording, and neither has anything to fall back on.

### Screen Recording — for app window thumbnails

Lets Recents capture each app's last window to use as its card. **Without it,
apps show their icon instead**; nothing else changes, and the failure is stated
in a banner rather than passed off as "no window yet".

Capture happens whenever a window is provably on screen and might be about to
stop being:

- when you **switch away** from an app (its window still shows your last state)
- when you **switch to** an app — twice: once immediately, and again ~0.7s later
- when an app **opens a window** (Accessibility only — see below)
- when an app is **hidden** (⌘H) or **unhidden**
- when an app **launches**, once it has had a moment to draw a window
- when a minimised window is **restored** (Accessibility only — see below)
- when the **deck is summoned**, for every app with a window on screen
- every **20 seconds** for the frontmost app

A capture that fails leaves the previous one in place. Rapid ⌘Tab is throttled to
one capture per app every 2 seconds; a window appearing overrules that throttle,
since it is the one moment the remembered frame is known to be wrong.

> **Why switching to an app captures twice.** Activation and a window are not the
> same event. An app brought forward with nothing open *makes* a window in
> response — Safari does this from the Dock, ⌘N does it anywhere — and that
> window does not exist at the instant activation is announced. With a single
> immediate capture the attempt found nothing, and the card went on showing the
> frame from whenever the app last had a window, hours earlier, directly beneath
> a subtitle reading "2 mins ago". Delayed capture per app is coalesced, so an
> app restoring a dozen windows still costs one.

### Minimised and closed apps — live previews

A minimised window **is** readable, and Recents shows it live. This corrects an
earlier belief that shaped the original design.

What is true is narrower than "macOS will not give you the pixels": it is
*ScreenCaptureKit* that will not. Measured on macOS 26.5, for a window that is
not on screen:

- `SCScreenshotManager.captureImage` throws *"Failed to start stream due to
  audio/video capture failure"*.
- An `SCStream` on `SCContentFilter(desktopIndependentWindow:)` starts without
  error and then delivers **zero** frames, indefinitely.

The window server itself has no such limitation. `SLSHWCaptureWindowList` returns
a window's current backing store whether or not it is on screen, and if the owning
app is still drawing, successive calls return successive frames. A video playing
in a minimised window therefore **plays on its card**, which is what a Windows
taskbar thumbnail does and what the deck previously could not.

Run `Recents --selftest-live` to see this proven on your own machine: it lists
every window, marks which are minimised, and reports which are actively drawing.

**How it is paced.** A capture costs ~10.5 ms of wall time but only ~0.2 ms of
CPU — it is almost entirely a blocking round trip — and the window server
serialises them, so four concurrent captures take as long as four sequential
ones. The scarce resource is calls per second, not processor time. So:

- The engine runs **only while the deck is on screen**. Closed deck, no timer.
- The **focused** card (centred, or hovered) refreshes at 15 fps; merely visible
  neighbours at 3 fps; everything else is not captured at all, with a ceiling of
  four windows per tick.
- A frame whose sampled fingerprint is unchanged is dropped on the background
  queue, so an idle window costs no redraw.
- Live frames are folded back into the on-disk cache every 15s, so a recent still
  survives the app quitting.

**Threading.** On macOS 26 this call is not the plain window-server round trip its
name suggests — a stack sample taken while it was wedged shows it routed through
ScreenCaptureKit (`SLSHWCaptureWindowListToIOSurfaceProxying` →
`dispatch_semaphore_wait`), so it depends on `replayd` and **can block for
seconds** when that daemon is saturated. It is therefore confined to one private
serial queue, refuses to run on the main thread, and every call carries a 300 ms
timeout; requests that expire while queued behind a stalled one are discarded
rather than run.

**Which window.** macOS keeps an untitled 500×500 placeholder window offscreen
for many processes — Finder, Safari and Messages all have one — which captures as
a blank rectangle. An on-screen window is always preferred; an offscreen one is
only used if it carries a title, which a genuinely minimised document window
always does and a placeholder never does. A frame that comes back flat and empty
is dropped too, so a good remembered still is never replaced by nothing.

**When it is not live.** A quit app has no window to read, so the last frame ever
seen still stands:

- Captures are written to disk with a metadata sidecar (capture time, window
  title, source size, pixel size, scale) and are **never evicted** because an app
  was minimised, hidden or quit.
- A card falls back to an icon only when Recents has genuinely never seen a
  window from that app.
- The card always says which it is: a green **Live** badge when a minimised or
  hidden window is being shown live, and an age badge — *"No window on screen"*
  or *"This app is not running"* — when it is a remembered still.

**Private API, and what happens without it.** `SLSHWCaptureWindowList` is SkyLight
SPI. Every symbol is resolved with `dlsym` at startup, and if any is missing the
whole facility reports itself unavailable and the app falls back to
ScreenCaptureKit stills. It only ever *adds* frames the public API declined to
provide; nothing breaks when it returns nothing. Live previews can also simply be
switched off in Settings.

### Accessibility — required for Dock previews, optional for the deck

**Dock previews cannot run without it.** The Dock is asked what the pointer is
over through its accessibility tree (`DockProbe`), the windows a tile stands for
are resolved and acted on through theirs, and a `CGEventTap` — how the panel
reads the arrow keys — needs the same grant. There is nothing to degrade to, so
the feature reports itself unavailable and Settings says which permission is
missing. See § 4.9.

For the deck it remains optional and buys precision. Restoration and window
creation *are* observable: with Accessibility granted, Recents registers an
`AXObserver` per running app for `kAXWindowDeminiaturized` and `kAXWindowCreated`
and re-captures ~0.45s after either, so the card refreshes instead of keeping the
frame from before the window was minimised — or, for a window that did not exist
at all, from before it was opened. Without it, the delayed capture after
activation and the summon refresh cover the same ground less precisely.

### Full Disk Access — for exact Apple-menu ordering

Lets Recents read `~/Library/Application Support/com.apple.sharedfilelist/`, the
same lists the Apple menu uses — and, in the same protected directory, Preview's
own. **Without it the deck cannot claim parity with any of them**: documents
disappear (Preview's list is the only source for them, and Spotlight is no longer
a fallback for it), apps fall back to what is running, servers disappear
entirely. A banner says so and offers to fix it, and `--parity` reports the lists
it could not read rather than reporting a false match.

> Ad-hoc code signatures change on every rebuild, and TCC keys grants partly on
> the signature. After a rebuild macOS may ask for permission again. Keeping the
> bundle at a stable path minimises this.

---

## 7. Architecture

```
Sources/Recents/
├── main.swift                    entry point; --dump / --parity / --selftest-*
├── AppDelegate.swift             wiring, hotkey rebinding, first-run prompt
├── Model/
│   ├── RecentItem.swift          one entry; .application, .document or .server
│   ├── SharedFileListReader.swift  .sfl4 parsing (Apple's own lists)
│   ├── OfficeRecentsReader.swift Word/Excel/PowerPoint private MRUs
│   ├── AppleMenuRecents.swift    Clear Menu — empties Apple's lists for real
│   ├── SpotlightSource.swift     live NSMetadataQuery feed
│   ├── RecentsStore.swift        the merge; single source of truth for the UI
│   ├── ParityReport.swift        --parity; checks deck order against the lists
│   ├── UserState.swift           pins + suppressions (JSON)
│   ├── Preferences.swift         settings + shortcut (UserDefaults)
│   ├── FileWatcher.swift         re-arming file watcher
│   ├── WatcherSelfTest.swift     proves the watcher survives replacement
│   └── OfficeSelfTest.swift      --selftest-office; deck vs. the Office stores
├── Thumbnails/
│   ├── ThumbnailCache.swift      QuickLook previews, 3-tier cache
│   ├── AppWindowCapture.swift    window screenshots + capture lifecycle
│   ├── LiveWindowPreview.swift   the capture engine: demand levels and pacing
│   ├── WindowServerCapture.swift SkyLight SPI; reads minimised/hidden windows
│   └── LivePreviewSelfTest.swift --selftest-live
├── Dock/
│   ├── DockHoverWatcher.swift    which Dock tile the pointer is over
│   ├── DockProbe.swift           the Dock's own accessibility tree, and its edge
│   ├── DockWindows.swift         a tile's windows; activate, close, zoom, open
│   ├── DockPreviewController.swift  panel lifecycle, placement, subscriptions
│   ├── DockPreviewView.swift     the row of thumbnails itself
│   ├── DockPreviewLayout.swift   fitting that row to the screen it opens on
│   ├── DockPreviewSelection.swift  the highlight the pointer and keys share
│   ├── DockPreviewKeys.swift     the event tap that reads ←/→/↩/⎋
│   ├── DockSelfTest.swift        --selftest-dock
│   ├── DockCloseSelfTest.swift   --selftest-dock-close
│   └── DockKeySelfTest.swift     --selftest-dock-keys
├── Input/
│   ├── HotKey.swift              Carbon global shortcut
│   ├── TrackpadGesture.swift     private multitouch tap-to-summon
│   ├── TrackpadGestureSelfTest.swift  --selftest-gesture
│   ├── MenuBarItem.swift         status bar item and its menu
│   └── MenuSelfTest.swift        --selftest-menu
└── UI/
    ├── DeckWindow.swift          the window + its controller + appearance switch
    ├── DeckMetrics.swift         card geometry scaled to the window's size
    ├── DeckAppearance.swift      glass/solid modes and the derived palette
    ├── GlassBackground.swift     DeckBackgroundView: the two grounds
    ├── DeckView.swift            rail layout, circular math, all input
    ├── DeckRail.swift            the rail's arithmetic, with no view attached
    ├── CardView.swift            one card; app, document and server shapes
    ├── ClearMenuPrompt.swift     the Clear Menu confirmation, shared by both doors
    ├── ThumbnailImage.swift      async document preview
    ├── PeekView.swift            full QLPreviewView preview
    ├── FuzzyFilter.swift         scored subsequence matching
    ├── SettingsWindow.swift      settings + hotkey recorder
    ├── DeckSnapshot.swift        --render, for development
    └── RenderOptions.swift       --flat / --solid / --glass
```

The unit suite lives beside it in `Tests/RecentsTests/` — 235 tests across 13
suites, covering the readers, the rail's arithmetic, card geometry, preferences,
the fuzzy filter, the Dock preview's layout and its selection.

### Why two data sources

Neither is sufficient alone, and they fail in complementary ways:

| | `.sfl4` shared lists | Spotlight |
|---|---|---|
| Ordering | **Authoritative** (macOS's own) | Timestamp-derived only |
| Timestamps | None | **Real** (`kMDItemLastUsedDate`) |
| Breadth | ~10 documents per list | **100+ per week** |
| Change feed | File watchers | `NSMetadataQuery` updates |
| Permission | Full Disk Access | None for most paths |

The shared lists decide **what is in the deck and in what order**; Spotlight only
**annotates** it with timestamps and tells it when to look again. That asymmetry
used to be weaker — Spotlight could also *add* document cards the lists did not
contain, appended after the authoritative ones and badged as such. It no longer
does: the main deck's documents are Preview's list and nothing else, so an entry
Spotlight alone knows about has no card to annotate. A URL Spotlight has no
timestamp for falls back to a direct `kMDItemLastUsedDate` read rather than to
Spotlight's seven-day window.

### `.sfl4` format

macOS 26 uses `.sfl4` (most references online describe `.sfl3` or `.sfl2`):

```
NSKeyedArchiver plist
└─ root dict
     ├─ "items" → [[String: Any]]     ← array order IS recency order
     │    └─ each: "Bookmark" (Data), "uuid", "Name"?, "visibility"
     └─ "properties"
```

`Bookmark` blobs resolve with `URL(resolvingBookmarkData:)`, using `.withoutUI`
and `.withoutMounting` so a stale network bookmark cannot block or raise an
authentication dialog from a background refresh.

### The Office store — a third source, for sub-decks only

Word, Excel and PowerPoint are the conspicuous hole in the per-app lists. They
*do* have `ApplicationRecentDocuments/com.microsoft.word.sfl4` files, so the
directory listing looks complete — but all three are **empty**: 0 items each,
against 10 for Preview and 7 for VS Code on the same machine. Office registers
documents with LaunchServices (which is why they reach the Apple menu's combined
list, and why Spotlight sees them) and then keeps its own MRU privately. The
result was an application card for Word with nothing to expand into.

That private MRU is the sandbox's security-scoped bookmark store:

```
~/Library/Containers/<bundleID>/Data/Library/Preferences/
    <bundleID>.securebookmarks.plist

binary plist
└─ root dict — keys are percent-encoded file:// URL strings
     └─ each value: "kBookmarkDataKey" (Data)
                    "kUUIDKey"         (String)
                    "kLastUsedDateKey" (Date)   ← recency order
```

Two things make it cheap to read. The dictionary **keys are already the file
URLs**, so the bookmark blobs never have to be resolved — no round trip, and no
risk of one reaching for a network volume. And `kLastUsedDateKey` is a real
timestamp, so unlike an `.sfl4` this file carries its own order rather than
depending on array position.

Three details that are easy to get wrong:

- The bundle identifier is `com.microsoft.Powerpoint` — lowercase `p`, which is
  Microsoft's spelling, not a typo. Everything is keyed lowercased anyway, for
  the same reason `SharedFileListReader` is.
- Office bookmarks the **folders** it has been granted access to alongside the
  documents inside them. Those are sandbox grants, not recents — Word's own
  File ▸ Recent does not list `~/Downloads` — so directories are filtered out.
- The lists are long and mostly dead. On the machine this was built against Word
  held 119 entries of which 36 still existed, and PowerPoint held 20 of which
  **none** did.

That last case is why `documentsByApp` is pruned to existing files *when the
index is built* rather than when a card is drawn: unpruned, PowerPoint's card
showed a chevron promising a sub-deck, and the swipe then did nothing because
every entry was filtered away at the last moment. Pruning early makes
`hasRecentDocuments` both honest and free — no filesystem access from a SwiftUI
body — and drops an app with nothing live left entirely.

**Scope.** This feeds application sub-decks and document attribution only. It
never touches the main deck's order, which stays macOS's own, so `--parity` is
unaffected. It is undocumented Office internals in a sandbox container: an Office
update can rename the file or change the keys, and if it does, every read returns
nothing and those cards simply stop offering recents — exactly as they behaved
before. `Recents --selftest-office` is how you find out.

### Three subtle bugs worth knowing about

**1. The file watcher must re-arm.** `sharedfilelistd` rewrites `.sfl4` files by
writing a temp file and renaming it into place. The inode the descriptor points
at is unlinked, so a `DispatchSource` armed naively fires `.delete` once and then
goes **permanently silent** — it works in casual testing, then quietly stops
updating forever. `FileWatcher` tears down and re-arms on `.delete`/`.rename`.

Verify with:
```bash
./.build/debug/Recents --selftest-watcher
```

**2. A `DispatchSource` cancel handler must not own its watcher.** `FileWatcher`
is routinely released by one of its own blocks finishing on its private queue —
every one of them promotes a weak `self` to strong for its duration. If the
cancel handler does the same, deallocation happens *on* that queue, `deinit` calls
`stop()`, and `queue.sync` targeting the queue you are already on is an immediate
deadlock that libdispatch traps (SIGTRAP, exit 133). The handler now captures the
file descriptor by value, `deinit` never calls `stop()`, and `stop()` checks a
queue-specific key before it syncs.

**3. Snapshots misrepresent 3D transforms.** `--render` draws through
`cacheDisplay`, which cannot composite `CATransform3D` layers and places them at
their untransformed origin — making a correct layout look broken. Pass `--flat`
to disable card tilt when rendering.

### Performance

- Only cards within 5 slots of centre are built at all
- Thumbnails: memory LRU (120) → disk cache → QuickLook render
- Cache keys include modification date and size, so editing a file invalidates
  its thumbnail with no explicit purge — plus the requested point size and the
  display scale, so a 1× render is never served to a Retina card
- Window captures are capped at 2600px on the long edge, and re-captured at most
  once per app every 2 seconds
- A file watcher whose file does not exist (`RecentServers.sfl4`, on most
  machines) backs off from 1s to 30s rather than retrying every second forever
- Concurrent requests for the same thumbnail are coalesced
- Refreshes are debounced 250ms — one user action can trigger a shared-list
  rewrite and a Spotlight update milliseconds apart

---

## 8. Developer commands

| Command | Purpose |
|---|---|
| `swift test` | The unit suite — pure logic, the readers, the rail's arithmetic. Hermetic: it builds its own `.sfl4` archives, Office bookmark stores and state files in a scratch directory |
| `Recents --dump` | Print the merged deck as text, then exit |
| `Recents --dump --watch` | Keep printing on every change |
| `Recents --parity` | Compare deck order against macOS's own lists (exit 0 = match) |
| `Recents --selftest-watcher` | Prove the file watcher re-arms (exit 0 = pass) |
| `Recents --selftest-live` | List every window, which are minimised, and which are actively drawing |
| `Recents --selftest-live --verbose` | The same, preceded by the raw unfiltered window list — the only way to tell "we rejected this window" from "the server does not have it" |
| `Recents --selftest-office` | Read Word/Excel/PowerPoint's private stores, then check the deck agrees with them (exit 0 = match). The store is undocumented Office internals, so this is how you find out an Office update moved it |
| `Recents --selftest-gesture [--fingers N] [--taps N]` | Score the bound trackpad gesture live for 45s. The flags try another shape without changing the setting |
| `Recents --selftest-dock` | Check the Dock still exposes its tiles through Accessibility on this release, and that hovering one would resolve to real windows with real pixels behind them |
| `Recents --selftest-dock-close` | Click the close button on a real preview thumbnail, against a scratch window the test creates. The one claim about the panel that cannot be checked by reading anything |
| `Recents --selftest-dock-keys` | Press the arrow keys at a real preview and read back which thumbnail ended up highlighted — whether a keystroke reaches a panel that never becomes key is a fact about the window server |
| `Recents --selftest-menu` | Press ↓ at the real status item menu and read back what it highlighted |
| `Recents --render out.png [--flat]` | Render the deck offscreen to a PNG |
| `Recents --render out.png --solid` | …forcing Solid appearance, without changing the setting |
| `Recents --render out.png --glass` | …forcing Liquid Glass |
| `Recents --render out.png --size 1700x1050` | …at a given window size, for checking that the deck scales |
| `Recents --render-settings out.png` | Render the Settings window offscreen to a PNG |
| `Recents --show` | Open the deck immediately on launch |

`--render` exists because `screencapture` requires Screen Recording permission
that a build script has no business demanding, and a hotkey overlay is awkward to
photograph by hand.

### Verifying end to end

The two kinds of test answer different questions and neither replaces the other.
`swift test` says whether the code is right without saying anything about this
machine. The `--selftest-*` harnesses make no assertions about the code at all;
they check that the undocumented surfaces it stands on — the Dock's accessibility
tree, Office's private MRU, minimised windows having readable pixels, a panel
that never becomes key still hearing an arrow key — are still where they were on
the machine in front of you.

```bash
# 0. The code, independent of this machine
swift test

# 1. Data engine, before any UI
./.build/debug/Recents --dump

# 2. Apple-menu parity (exits non-zero on divergence)
./.build/debug/Recents --parity

# 3. File watcher (the specific bug that hides in casual testing)
./.build/debug/Recents --selftest-watcher

# 4. Visual check, both appearances
./.build/debug/Recents --render /tmp/glass.png --flat --glass
./.build/debug/Recents --render /tmp/solid.png --flat --solid

# 5. The real thing
./build.sh && open ./Recents.app
```

`--parity` resolves each shared file list, resolves the deck, and compares the two
sequences directly — after removing entries the deck legitimately dropped (a file
that no longer exists, one you chose to forget, a folder while folders are
hidden) and setting pinned items aside, since pinning deliberately reorders. It
reports the first position where they differ.

Manual checks worth doing:

**Apple-menu parity**
- Open Apple menu → Recent Items and compare its *Applications* section, top to
  bottom, with the deck's app cards
- Open Preview → File → Open Recent and compare it with the deck's document
  cards; the deck shows the first _n_ of that menu, in that order
- Confirm nothing has been mixed *into* either sequence

**Thumbnail quality**
- PDFs, images, Office files, folders and app windows all render
- Previews are fitted, not cropped or distorted
- Drag the window between a Retina and a non-Retina display and re-summon

**Appearance**
- Switch Liquid Glass ↔ Solid with the deck open; it changes without a relaunch
- Switch Regular ↔ Clear; Clear should visibly show more of the desktop
- Set a glass tint, then remove it
- Pick a dark custom colour while macOS is in light mode; captions stay readable
- Quit and relaunch; the setting persists

**Minimised and closed apps**
- Play a video, ⌘M the window, summon the deck → the card **keeps playing**,
  with a green *Live* badge
- Scrub the rail away from that card → it keeps updating, more slowly
- Close the deck → captures stop entirely (check Activity Monitor)
- Turn *Live window previews* off → the card falls back to a still immediately
- Quit the app → the card shows its last window with an age badge, not an icon
- Quit *Recents* and relaunch → that frame is still there
- `Recents --selftest-live` → minimised windows listed as readable

**Dock previews** (Settings → Show → *Dock previews*, plus Accessibility)
- Rest the pointer on a Dock icon → thumbnails of its windows appear above it
- ⌘M a window, then hover its icon → it is there, still moving, badged as minimised
- Click a thumbnail → that window comes forward; if it was minimised, it restores
- ←/→ → the highlight walks the row; ↩ acts on it; ⎋ dismisses the panel
- ⌘← while a preview is up → the app in front goes Back, and the preview ignores it
- ✕ on a thumbnail → that window closes and the row rebuilds without it; the
  highlight stays put, so the next window can be closed without moving the mouse
- Hover an app that is running with no windows → one remembered still, labelled
  with what a click will do; hover an app that is not running → no panel at all
- Revoke Accessibility → the setting says so rather than looking broken
- `--selftest-dock`, `--selftest-dock-close`, `--selftest-dock-keys` all exit 0

**Everything else**
- Summon from inside a full-screen app; **⎋** should return focus to *that* app
- Revoke Full Disk Access → relaunch → deck still populates, banner appears,
  `--parity` reports the unreadable lists rather than a false match
- Forget a card → relaunch → it stays gone
- Forget a running app → quit and relaunch that app → its card returns, because
  the launch is newer than the flick
- Forget a document → open it again → its card returns on the next refresh
- Quit every window of a running app, then click it in the Dock → its card shows
  the window that just opened, not the one from before
- Pin an item → relaunch → it still leads the deck
- Peek a document (**Space**) → **double-click** it → it opens and the deck closes
- Summon again → the peek is **not** still open. Same after ⌘W, the red button and
  the hotkey, each of which orders the window out without tearing the view down
- Drag the window taller → the cards grow with it; drag it wider → they do not,
  but more of the rail comes into view
- **⇧⌘⌫ → Clear Menu** → open any app's  menu → *Recent Items* holds only its
  three section headers and *Clear Menu* itself. Then open one document and check
  the menu again: it must list that document **and nothing else**. If the old
  entries reappear, `sharedfilelistd` survived with its cache intact and the
  clear only looked like it worked.

  Back the three `.sfl4` files up before running this by hand; there is no undo.
  Restoring them is not simply copying them back — the daemon serves whatever it
  last read, so it has to be killed again afterwards, and already-running apps
  keep a stale menu until the lists next change. (Deleting them does not have
  that problem: the daemon broadcasts the change and every menu empties at once.)

---

## 9. Storage

| Path | Contents |
|---|---|
| `~/Library/Application Support/Recents/state.json` | Pins, and suppressions with the date each was made |
| `~/Library/Caches/Recents/thumbnails/` | Document previews (SHA256-keyed) |
| `~/Library/Caches/Recents/windows/` | App window screenshots (`<bundleID>.png`) plus a `<bundleID>.json` sidecar holding capture time, window title, source size, pixel size and scale |
| `UserDefaults` (`com.recents.deck`) | Shortcut, display and appearance settings |

Deleting `thumbnails/` is always safe; it rebuilds on demand. Deleting
`windows/` is safe but **lossy in one direction**: those frames are the only
record of what a minimised or quit app last looked like, and there is no way to
re-capture a window that is no longer on screen. They come back one app at a
time, as each is next used.
