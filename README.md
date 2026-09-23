# Book card 
A new KOReader Sleep Screen

Sleep screen showing a reading summary card: cover (framed, rounded corners),
title, author, series, reading time, time left, progress, daily average,
pages/min, days + start date, finish date (or estimated finish), battery,
daily + weekly reading streak and reader type.

<img width="382" height="510" alt="FileManager_2026-09-22_091600" src="https://github.com/user-attachments/assets/2834619a-9e49-4826-9b2c-d76099bb9dae" />
<img width="382" height="510" alt="Reader_The Wild Robot 1  - The Wild Robot - Brown, Peter #p(128) epub_p6_2026-09-22_084553" src="https://github.com/user-attachments/assets/10d84b60-9a52-43ee-aab2-eaabb1ff7c3f" />


<br>Settings screen in the menu<br>
<img width="255" height="340" alt="FileManager_2026-09-21_094916" src="https://github.com/user-attachments/assets/aa3e40a1-41d5-4551-8ef4-b24f6992d7bc" />


## Install
Copy the `bookcard.koplugin` folder to `koreader/plugins/`, restart KOReader.

## Use
- Settings > Screen > Sleep screen > Wallpaper > **Book card**
  (or Tools > Book card > Use as sleep screen).
- Locking from inside a book: live data (and the cache is refreshed).
- Locking from the file manager: data cached from the last book that was open.
  If there is no cache, it is rebuilt from the book's sidecar + statistics DB.
- Tools > Book card: Preview, Background (follow night mode / light / dark,
  wallpaper picture, text background opacity), Cover (rounded corners,
  shadow, cover/statistics spacing), Colors, Fonts, Card elements
  (battery / streak / reader type toggles, statistics rows), Advanced
  Settings (orientation, clear cache), Updates.
- Assign a gesture to open it.

## Android
KOReader's own sleep screen (the "Use as sleep screen" option above) only
ever appears on platforms where KOReader itself owns the "device is
asleep" screen, such as Kindle or Kobo. On Android, locking the screen
hands control to Android's own lock screen instead, so the native Book
Card sleep screen is never shown there.

For Android, use **Tools > Book card > Advanced Settings > Image export
(for Android wallpaper)** instead:
- **Save as image, kept up to date** - turns on a background PNG export of
  the card, refreshed automatically (Save image now / refresh interval,
  both in the same menu).
- **Also copy to a shared folder…** - optionally also writes the same
  picture into a folder you pick (e.g. a shared `Pictures` folder), so it
  shows up in Android's own gallery/wallpaper picker, or so a
  wallpaper-changer app can watch that folder and keep applying the latest
  version automatically.
- The always-on copy lives at
  `koreader/screensaver/bookcard_png/bookcard_wallpaper.png` regardless of
  whether an extra folder is set.

This mirrors how the Ink Stain Wallpaper plugin handles the same
Android limitation.

## Orientation
Tools > Book card > Advanced Settings > Orientation:
- **Default** - the card is drawn at whatever rotation
  the device is already in when it falls asleep (no change from the
  original behaviour).
- **Force portrait** / **Force landscape** - the screen is rotated to match
  right before the sleep screen is drawn, and rotated back to whatever it
  was as soon as the device wakes up.

This only affects the actual sleep screen. Tools > Book card > Preview opens
the card in a popup while you are actively using KOReader, so it never
rotates the screen - it always renders at the screen's current orientation,
regardless of this setting.

## Wallpaper
Tools > Book card > Background > Wallpaper lets you pick a background
picture, read from `settings/bookcard/wallpapers/` (drop your own image
files there - png/jpg/jpeg/bmp/gif/webp - then reopen the menu to see them
listed; pick "None" to go back to the plain background). With a wallpaper
set, a translucent panel is drawn behind each piece of text (title, author,
series, statistics, battery, streak, reader type) so it stays legible over
the picture - black in dark mode, white in light mode, matching whatever
"Background" theme is in effect. Its strength is set separately under
Background > Text background opacity (Off / Low / Moderate / High / Solid).

## Numbers
All statistics are computed exactly like Reading Insights (same avg_time,
same pages-left call, same capped reading time, same streak logic; the weekly
streak follows Reading Insights' week-start setting). The reader type is the
part of the day (night 0-6, morning 6-12, afternoon 12-18, evening 18-24) with
the most reading time over all books.

## Updates
`lib/updater.lua` is the Reading Insights updater. Set `GITHUB_REPO` at the top
of that file (e.g. `"owner/bookcard.koplugin"`) - until then update checks report
that no source is configured. Releases need a `.zip` asset whose single
top-level folder is `bookcard.koplugin`.

## Files
- `lib/screensaver.lua` sleep-screen hook (also forces/restores orientation),
  `lib/bookdata.lua` data, `lib/cache.lua` cache
- `lib/updater.lua` GitHub updater, `lib/statsdb.lua` read-only stats DB access
- `lib/wallpaper.lua` background picture + translucent text backdrop panels
- `views/card_view.lua` layout, `widgets/` battery, stat cell, framed cover, svg icon
- `icons/` svg, `locale/*.po` translations (en, hu)

## Notes
- Needs KOReader's Statistics plugin enabled for time/pace/streak figures.
- Cache: `settings/bookcard_cache.lua` and `cache/bookcard/cover.png`, cleared
  from Advanced Settings > Clear cached data.
- If you disable the plugin while "Book card" is selected, pick another wallpaper.
- Forced orientation only takes effect on the real sleep screen; if KOReader
  is killed or crashes while asleep (skipping the normal wake-up event), the
  screen can stay in the forced rotation until you rotate it yourself.

## Acknowledgements
- Idea from statistics page from [crosspoint-reader](https://github.com/crosspoint-reader/crosspoint-reader).
- Statistics based on [quanganhdo/koreader-user-patches](https://github.com/quanganhdo/koreader-user-patches).
- Colorwheel from [Euphoriyy/KOReader.patches](https://github.com/Euphoriyy/KOReader.patches#-colorwheelwidgetlua).
- In-plugin updater, cover shadows, backgrounds, and cover look comes from [AndyHazz/bookshelf.koplugin](https://github.com/AndyHazz/bookshelf.koplugin).
- Android support [Estela-Zelin84/inkstain.koplugin](https://github.com/Estela-Zelin84/inkstain.koplugin).
