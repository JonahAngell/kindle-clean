# Kindle Clean

A KOReader plugin that masks words from a personal list on screen while you read. It never modifies book files.

- `profanitymask.koplugin/`: the plugin
  - `matcher.lua`: pure Lua matching (case, punctuation, possessives, plurals, phrases)
  - `wordlist.lua`: reads and edits `profanity.txt`
  - `main.lua`: KOReader glue (overlay painting, menus, settings)
- `tests/run.lua`: desktop unit tests for the pure-Lua parts. Run with `luajit tests/run.lua`.
- `deploy.sh`: copies the plugin to a USB-mounted Kindle
- `docs/SETUP.md`: jailbreak and KOReader setup for the KT5 on 5.19.2.0.1

## Features (Phase 1)

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
| PDF | not yet (Phase 3) |
| Categories, profiles, regex | parsed and reserved in the file format, not used yet |

## Word list format (`koreader/profanity.txt`)

    # comment
    damn
    son of a
    [Category]   # reserved for future profiles

## How it works

The plugin registers a ReaderView view module, which paints after the page text and highlights. On each new page or setting change, it does the following:
1. It gets the visible text with `getTextFromPositions`.
2. It runs a quick substring pre-check against the list.
3. Only if that hits does it walk the page word by word using crengine xpointers.
4. It gets each match's screen boxes with `getScreenBoxesFromPositions`, caches them per page, and paints the masks.

## Known limits

- Reflowable documents only (EPUB, FB2, HTML, MOBI via KOReader). PDFs are not masked yet.
- When a word is split by inline markup (e.g. `<i>da</i>mn`), the whole rendered token is masked.
- In night mode, the masks invert along with the page.
