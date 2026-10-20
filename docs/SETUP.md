# Device setup: Kindle 11th gen (KT5), firmware 5.19.2.0.1

The plugin runs inside KOReader, which needs a jailbroken Kindle. You have to do these steps on the device yourself. Checked on 2026-10-20: the connected Kindle has firmware 5.19.2.0.1 and **is not jailbroken yet**. It has no `koreader/`, `extensions/` or `mrpackages/` folder.

Follow the current kindlemodding.org guides, which change often. Do not rely only on this summary.

## 1. Jailbreak (pick one)

**Option A: Véra.** Newer and fully on-device.
Guide: https://kindlemodding.org/jailbreaking/Vera/
1. Set the font to Bookerly, bold 0, max size, medium spacing, and save it as a theme. Exact settings are in the guide.
2. In the Kindle browser, open kindlemodding.org/vera and follow the prompts.
3. Open the Véra book and wait for "RESTARTING GUI".

**Option B: SpringBreak.** Lists 5.19.2.0.1 for the K11 explicitly.
Guide: https://kindlemodding.org/jailbreaking/SpringBreak/
1. Turn on Airplane Mode first.
2. Copy the SpringBreak files over USB, as the guide describes.
3. Follow the Kindle Store steps.
4. Do the mandatory cleanup step afterwards.

Both install a hotfix and KUAL/KPM. Keep the hotfix installed so the jailbreak survives OTA updates. Keep Airplane Mode on until the guide says the hotfix is installed.

## 2. Install KOReader

Follow the "What's Next" → KOReader page on kindlemodding.org. On firmware 5.16.3 and newer, pick the **kindlehf** (hard-float) build.

## 3. Install the plugin

With the Kindle connected over USB:

    ./deploy.sh

This copies `profanitymask.koplugin` to `/Volumes/Kindle/koreader/plugins/`. Restart KOReader, open an EPUB, and find the plugin under the typeset (document) menu tab → **Profanity filter**.

The word list is created on first use at `/mnt/us/koreader/profanity.txt`. Over USB that is `/Volumes/Kindle/koreader/profanity.txt`.

## Libby / .acsm loans

Libby EPUB loans arrive as `.acsm` tokens for Adobe DRM. Making them readable in KOReader means removing that DRM, which this project does not do. Your options:
- Read Libby loans in the stock Kindle reader through "Read with Kindle" (US libraries). The mask won't apply there.
- Use DRM-free books, such as Standard Ebooks, Project Gutenberg, or DRM-free store purchases.
