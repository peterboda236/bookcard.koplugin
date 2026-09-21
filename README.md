# Book Card 
A new KOReader Sleep Screen

Sleep screen showing a reading summary card: cover (framed, rounded corners),
title, author, series, reading time, time left, progress, daily average,
pages/min, days + start date, finish date (or estimated finish), battery,
daily + weekly reading streak and reader type.

<img width="510" height="680" alt="FileManager_2026-09-21_094858" src="https://github.com/user-attachments/assets/6cdde237-53d2-47be-9189-af41912ccf8b" />

<br>Settings screen in the menu<br>
<img width="255" height="340" alt="FileManager_2026-09-21_094916" src="https://github.com/user-attachments/assets/aa3e40a1-41d5-4551-8ef4-b24f6992d7bc" />


## Install
Copy the `bookcard.koplugin` folder to `koreader/plugins/`, restart KOReader.

## Use
- Settings > Screen > Sleep screen > Wallpaper > **Book Card**
  (or Tools > Book Card > Use as sleep screen).
- Locking from inside a book: live data (and the cache is refreshed).
- Locking from the file manager: data cached from the last book that was open.
  If there is no cache, it is rebuilt from the book's sidecar + statistics DB.
- Tools > Book Card: Preview, Background (follow night mode / light / dark),
  rounded cover corners, battery / streak / reader type toggles, clear cache,
  Updates.
- Assign a gesture to open it.

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
- `lib/screensaver.lua` sleep-screen hook, `lib/bookdata.lua` data, `lib/cache.lua` cache
- `lib/updater.lua` GitHub updater, `lib/statsdb.lua` read-only stats DB access
- `views/card_view.lua` layout, `widgets/` battery, stat cell, framed cover, svg icon
- `icons/` svg, `locale/*.po` translations (en, hu)

## Notes
- Needs KOReader's Statistics plugin enabled for time/pace/streak figures.
- Cache: `settings/bookcard_cache.lua` and `cache/bookcard/cover.png`.
- If you disable the plugin while "Book Card" is selected, pick another wallpaper.

## Acknowledgements
- Idea from statistics page from [crosspoint-reader](https://github.com/crosspoint-reader/crosspoint-reader).
- Statistics based on [quanganhdo/koreader-user-patches](https://github.com/quanganhdo/koreader-user-patches).
- Colorwheel from [Euphoriyy/KOReader.patches](https://github.com/Euphoriyy/KOReader.patches#-colorwheelwidgetlua).
- In-plugin updater, cover shadows and over look comes from [AndyHazz/bookshelf.koplugin](https://github.com/AndyHazz/bookshelf.koplugin).
