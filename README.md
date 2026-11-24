# Dev MapPace

A development addon for World of Warcraft (forever). It times every frame while the world map opens and closes, to find what makes the map hitch. It's how we found the cause of the controller UI's map hitch, reported as [WoWUIBugs #907](https://github.com/Stanzilla/WoWUIBugs/issues/907) and worked around by [Gamepad Fast Map](https://github.com/ArtisanGW/GamepadFastMap).

It uses only the game: no libraries, no other addon.

## Install

Copy this folder into `Interface/AddOns/DevMapPace`, then `/reload`.

## Commands

| Command | What it does |
|---|---|
| `/mappace` | Opens and closes the map itself, 3 times in 20 seconds (out of combat). |
| `/mappace manual` | You press M: open and close the map 3 times in the 20 seconds. |
| `/mappace deep` | Automatic, and also times the game's own map steps. Runs twice: with the game's quest pins on, then off. |
| `/mappace clear` | Empties the saved runs. |

Each run ends asking for a `/reload`. The reload writes the results to `WTF/Account/<account>/SavedVariables/DevMapPace.lua` and clears the taint the timers put on the map.

## What each run records

For every frame of the run:
- its length (`debugprofilestop`)
- the time all addons and each loaded addon spent in it (`C_AddOnProfiler`)
- the memory it made (`collectgarbage("count")`)

For each open and close, the summary keeps the frames up to one second after it: the longest frame, the total, and the frames over 25 ms in full.

## How the deep run works

`/mappace deep` wraps the game's own map functions in timers for the length of the run, then puts them back:
- `WorldMapFrame`: `OnShow`, `OnHide`, `OnMapChanged`, `RefreshAll`, `RefreshAllDataProviders`, `RefreshOverlayFrames`, and others
- every map data provider: `RefreshAllData`, `OnShow`, `OnHide`, `OnMapChanged`, `RemoveAllData`
- every overlay frame's `Refresh`
- the quest log: `QuestLogQuests_Update`, `QuestMapFrame_UpdateAll` and the `QuestMapFrame` methods
- pin churn: `RemoveAllPinsByTemplate` and `AcquirePin`

Each wrapped function adds its time and its call count to the frame it ran in, so a summary reads like "`QuestLogQuests_Update` 97 ms, x20". `QuestLogQuests_Update` also keeps the call stacks that led to it, which shows who asked for the rebuild.

The deep run then runs again with the game's quest pins off (the `questPOI` setting). It puts the setting back after, or at the next login if a reload cut the run short. Comparing the two runs separates the cost of the quest pins from the rest of the map.

## What the deep runs found

Controller UI on, 20 quests on the map, forever client 1.60.1.71037, 2026-11-24.

**Game as is** (deep run, quest pins on): every open and close rebuilt the whole quest list once per quest pin.

| | Longest frame | `QuestLogQuests_Update` | Calls |
|---|---|---|---|
| First open | 370 ms | 310 ms | x62 |
| Close | 110 ms | 95 ms | x20 |
| Open | 157 ms | 131 ms | x20 |
| Close | 110 ms | 97 ms | x20 |
| Open | 161 ms | 134 ms | x20 |
| Close | 111 ms | 98 ms | x20 |

The saved call stacks show where they came from: 160 of the run's 162 calls came through `MapCanvasMixin:UnregisterPin` → `ExitMapPin` → the quest pin's `OnMouseLeave` → `MapCanvas.QuestPin.OnLeave` → `QuestLogScrollFrameMixin:OnMapCanvasPinLeave` → `QuestLogQuests_Update` (`Blizzard_MapCanvas.lua:117-122`, `QuestDataProvider.lua:290`, `QuestMapFrame.lua:1267-1269`). The other 2 were the quest log's own refresh. On the controller UI the game "leaves" every pin it releases, even ones the cursor was never on.

**With the workaround** (Gamepad Fast Map, same deep run): the per-pin rebuilds are gone.

| | Longest frame | `QuestLogQuests_Update` calls |
|---|---|---|
| First open | 209 ms | x2 |
| Close | 11 ms | 0 |
| Open | 20 ms | 0 |
| Close | 11 ms | 0 |
| Open | 23 ms | 0 |
| Close | 10 ms | 0 |

With the quest pins off, the closes took about 10 ms and the opens about 20 ms, which confirms the quest pins were the cost.

## License

All rights reserved: see [LICENSE](LICENSE).
