# Kindle Clean

A KOReader plugin that masks words from a personal list on screen while you read. It never modifies book files.

- `profanitymask.koplugin/`: the plugin
  - `matcher.lua`: pure Lua matching (case, punctuation, possessives, plurals, phrases)
  - `wordlist.lua`: reads and edits `profanity.txt`
  - `profiles.lua`: named profiles (which categories are on)
  - `main.lua`: KOReader glue (overlay painting, menus, settings)
- `tests/run.lua`: desktop unit tests for the pure-Lua parts. Run with `luajit tests/run.lua`.
- `deploy.sh`: copies the plugin to a USB-mounted Kindle
- `docs/SETUP.md`: jailbreak and KOReader setup for the KT5 on 5.19.2.0.1

## Features

| Spec | Status |
|---|---|
| FR-1 exact words, no partial matches | done, unit tested |
| FR-2 case-insensitive | done, unit tested |
| FR-3 punctuation (quotes, dashes, ellipses) | done, unit tested |
| FR-4 possessives mask the base word | done, unit tested |
| FR-5 plurals (toggle) | done, unit tested |
| FR-6 black / gray / asterisks / blank | done, not tested on device |
| FR-7 enable/disable without reopening | done (menu + gesture action "Toggle profanity mask") |
| FR-8 per-book mode | done: follow global / always / never for this book |
| FR-9 live re-render | done |
| Add/remove word menus, highlight → "Mask this word" | done |
| Phrases ("son of a") | done (one Phase 3 item pulled in early) |
| Categories (`[Name]` headers, on/off per profile) | done, unit tested |
| Profiles (global active profile + per-book override) | done, unit tested |
| In-app word list editor | done (Profanity filter → Edit word list…) |
| PDF / DjVu (text layer) | done, not yet tested on device |
| Regex entries (`re:`) | parsed and reserved, not used yet |

## Word list format (`koreader/profanity.txt`)

    # comment
    damn          <- "General" (entries before any header)
    son of a
    [Strong]
    frak          <- "Strong"

Under **Profanity filter**:
- **Categories (profile)** turns categories on or off for the current profile.
- **Profile** switches the active profile, creates new ones (copied from the current one), deletes them, and sets a per-book override.

Words added from the menu or the highlight popup go into the General section.

## How it works

The plugin registers a ReaderView view module, which paints after the page text and highlights. On each new page or setting change, it does the following:
1. It gets the visible text with `getTextFromPositions`.
2. It runs a quick substring pre-check against the list.
3. Only if that hits does it walk the page word by word using crengine xpointers.
4. It gets each match's screen boxes with `getScreenBoxesFromPositions`, caches them per page, and paints the masks.

For PDF and DjVu, it reads the page's text-layer word boxes (`getTextBoxes`), matches them in reading order, and maps them to the screen with `pageToScreenTransform`, the same path KOReader uses for saved highlights. This works in page, scroll and reflow modes.

## Known limits

- PDFs need a text layer. Scanned PDFs without one are not masked (unless KOReader's OCR is turned on).
- PDF word boxes have no per-character positions, so for `damn's` the masked part is estimated by character share of the word's width. In reflow mode the whole word is masked.
- A word hyphenated across a PDF line break (`dam-` / `n`) is not matched.
- When a word is split by inline markup (e.g. `<i>da</i>mn`), the whole rendered token is masked.
- In night mode, the masks invert along with the page.
