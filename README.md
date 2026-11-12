# Satchel Tracker

**Satchel Tracker** is a lightweight, standalone addon for **World of Warcraft: Forever** (`1.60.1`) that tracks the random outcomes of the **[Satchel of Potions](https://www.wowhead.com/forever/item=280766/satchel-of-potions)** trinket (Item ID `280766`).

## Features

- **Tracks All 4 Outcomes & Percentages:**
  - **Health** (Healing Potion effect)
  - **Mana** (Restore Mana effect)
  - **Speed** (15s Speed buff)
  - **Damage** (Self-inflicted Fire backfire, plus a hidden Crit sub-row that reveals itself the first time your backfire critically hits)
- **3-Tab View (`Overall` | `Session` | `History`):**
  - **Overall:** Persistent all-time counts and percentages across all sessions.
  - **Session:** Tracks your current login session (persists across `/reload` and resets only on a fresh login after logging out, or when manually reset).
  - **History:** Displays a `Last:` icon strip of your last 8 rolls plus a scrollable chronological roll log (up to 100 rolls) with relative timestamps.
- **Compact Mode (Horizontal & Vertical):**
  - Minimal icon + count strip (or recent 8-roll icon strip when on the `History` tab). Click `C` on the header (or `+` in compact mode) to toggle; right-click `C` / `+` to flip between Horizontal and Vertical layouts; middle-click `+` to cycle `Overall` / `Session` / `History` in Compact Mode.
- **Auto-Show When Equipped:**
  - Automatically shows when **Satchel of Potions** is equipped in either trinket slot and hides when unequipped.
- **Minimap Button:**
  - **Left-Click:** Toggle window
  - **Shift + Left-Click:** Toggle Compact Mode
  - **Middle-Click:** Undo last recorded roll
  - **Right-Click:** Cycle `Overall` / `Session` / `History` tabs
  - **Shift + Right-Click:** Reset Session stats

## Slash Commands (`/satchel` or `/st`)

- `/satchel` — Show / hide the tracker window
- `/satchel compact [h|v]` — Toggle compact mode (horizontal / vertical)
- `/satchel minimap` — Show / hide the minimap button
- `/satchel lock` — Lock / unlock window position
- `/satchel equip` — Toggle auto-show only when equipped
- `/satchel undo` — Remove the last recorded roll
- `/satchel reset` — Reset current session stats
- `/satchel reset overall` — Reset all-time Overall, Session, and History stats
- `/satchel debug` — Toggle debug event logging

## License

MIT
