# Progress Quest `.pq3` Save File Format

Used by both the original Delphi 6 Windows build and the FPC port.
The FPC port (`SaveFile.pas`) reads and writes this format with full round-trip
compatibility.

## Overview

Save files are **zlib-compressed** Delphi DFM binary streams. Decompressing yields
a flat sequence of component blocks, each starting with the magic bytes `TPF0`.

```
file = zlib_compress(component_block × N)
```

The FPC port writes **37** blocks. The original Delphi build writes **38** (the
extra block is `IdCompressorZLib1` appended at the end; the reader skips it).

## Component Block Structure

```
[4]  "TPF0"              magic
[1+] pascal_string       class name  (1-byte length + chars)
[1+] pascal_string       instance name
     property records... (repeated)
[1]  0x00                end-of-properties  (zero-length name sentinel)
[1]  0x00                end-of-child-components (always empty)
```

A **pascal_string** is `[1-byte length][chars]`.

## Property Value Types

| Byte | Name         | Encoding |
|------|--------------|----------|
| 0x02 | vaInt8       | 1 signed byte |
| 0x03 | vaInt16      | 2-byte LE signed |
| 0x04 | vaInt32      | 4-byte LE signed |
| 0x06 | vaString     | 1-byte length + chars (AnsiString, max 255) |
| 0x07 | vaIdent      | 1-byte length + chars |
| 0x08 | vaFalse      | no data |
| 0x09 | vaTrue       | no data |
| 0x0A | vaBinary     | 4-byte LE length + raw bytes |
| 0x0B | vaSet        | pascal_strings until 0x00-length byte |
| 0x0C | vaLString    | 4-byte LE length + chars (AnsiString, up to 2 GB) |
| 0x0E | vaCollection | items: `(0x01 + props + 0x00)` repeated, terminated by `0x00` |
| 0x12 | vaUTF8String | 4-byte LE length + UTF-8 chars |

## The 37 Components (Write Order)

All components are top-level (no parent/child nesting in the stream).

| #  | Instance Name | Class | Notes |
|----|---------------|-------|-------|
| 1  | Panel1 | TPanel | |
| 2  | Label1 | TLabel | |
| 3  | Label6 | TLabel | |
| 4  | Label4 | TLabel | |
| 5  | Traits | TListView | Name / Race / Class / Level |
| 6  | Stats | TListView | STR / CON / DEX / INT / WIS / CHA / HP Max / MP Max |
| 7  | ExpBar | TProgressBar | XP progress |
| 8  | Spells | TListView | spell name → Roman numeral level |
| 9  | Cheats | TPanel | |
| 10 | CashIn | TButton | |
| 11 | Button1 | TButton | |
| 12 | FinishQuest | TButton | |
| 13 | Button3 | TButton | |
| 14 | CheatPlot | TButton | |
| 15 | Panel3 | TPanel | |
| 16 | Label3 | TLabel | |
| 17 | Label2 | TLabel | |
| 18 | QuestBar | TProgressBar | quest progress |
| 19 | Plots | TListView | plot acts |
| 20 | PlotBar | TProgressBar | plot/act progress |
| 21 | Quests | TListView | quest list |
| 22 | Panel2 | TPanel | |
| 23 | InventoryLabelAlsoGameStyle | TLabel | Tag = GameStyle (3 = single player) |
| 24 | Label7 | TLabel | |
| 25 | Label8 | TLabel | Tag = multiplayer flags (0 = offline) |
| 26 | Inventory | TListView | item name → quantity |
| 27 | EncumBar | TProgressBar | encumbrance |
| 28 | Equips | TListView | slot → equipped item; Tag = last-bought slot index |
| 29 | vars | TPanel | |
| 30 | fTask | TLabel | Caption = current task (pipe-delimited) |
| 31 | fQuest | TLabel | Caption = quest monster entry; Tag = monster index |
| 32 | fQueue | TListBox | action queue (usually empty at save time) |
| 33 | Panel4 | TPanel | |
| 34 | Kill | TStatusBar | |
| 35 | TaskBar | TProgressBar | current task progress |
| 36 | Timer1 | TTimer | |
| 37 | ImageList1 | TImageList | |

## Game State Encoding

### TProgressBar — Position and Max

| Component | Position | Max |
|-----------|----------|-----|
| ExpBar | current XP (seconds) | XP needed for next level |
| QuestBar | quest progress | 50–149 (random at CompleteQuest) |
| PlotBar | plot progress (seconds) | `3600 × (1 + 5 × act_count)` |
| EncumBar | encumbrance (item count) | `10 + STR` |
| TaskBar | task elapsed (ms) | task duration (ms) |

### TLabel.Caption — fTask and fQuest

`fTask.Caption` encodes the current task. Possible formats:

| Format | Meaning |
|--------|---------|
| `kill\|name\|level\|item\|display` | Killing monsters; `item=*` → WinItem reward; field 4 is the formatted display name |
| `buying` | Purchasing equipment |
| `market` | Walking to market |
| `sell` | Selling next inventory item |
| `heading` | Walking to killing fields |
| `load` | Initial loading sequence |
| plain text | Narrative/cinematic description (stored directly; **not** `task\|n\|…` prefixed) |

Note: `task|n|description` and `plot|n|description` are **queue** formats (fQueue
items); they are expanded by `Dequeue` and stored as plain description text in fTask.

`fQuest.Caption` holds the raw monster entry (`name|level|item`) for the current
quest target, or `''` if no monster quest is active.

### fQueue — TListBox Items

Each item is pipe-delimited: `action|seconds|description`  
where `action` is `task` or `plot`. Usually empty at save time.

## TListView Items — `Items.ItemData` (vaBinary)

All TListView components store their items in a `Items.ItemData` vaBinary property.

### Blob Layout

```
[1]  version        always 0x06
[4]  content_size   LE uint32 = total_blob_size + item_count - 9
[4]  item_count     LE uint32
     items...       (back-to-back, no separators)
     trailing       2 × item_count bytes of 0xFF  (multi-column lists only)
```

### Per-Item Structure

```
[4]  state       LE int32   always 0
[4]  iImage      LE int32   -1=no image, 0=current/in-progress, 1=done/checked
[4]  iOverlay    LE int32   always -1
[4]  subCount    LE int32   number of sub-column strings (0 or 1)
[4]  unknown     LE int32   always -1
[4]  indent      LE int32   always 0
[4]  unknown     LE int32   always 0
[1]  char_count             number of UTF-16LE characters in caption
[char_count×2]  caption    UTF-16LE chars
[1]  char_count             number of UTF-16LE characters in subitem  (if subCount > 0)
[char_count×2]  subitem    UTF-16LE chars                             (if subCount > 0)
[8]  zero_footer            8 × 0x00                                  (if subCount > 0)
```

7 DWORDs (28 bytes) per item header. Strings are UTF-16LE with a 1-byte *character*
count prefix (not byte count); for Progress Quest's all-ASCII content each character
expands to `[lo, 0x00]`.

### Checked/Done State

- `Quests`, `Plots` (single-column, subCount=0): `iImage=1` → done, `iImage=0` → current
- All other lists (subCount=1): `iImage=-1` (no image)

### Trailing 0xFF Bytes

Multi-column lists (subCount=1) append `2 × item_count` bytes of `0xFF` after all
items. Single-column lists (Quests, Plots) have no trailing bytes.

| Component | Columns | subCount | Trailing |
|-----------|---------|----------|----------|
| Traits    | 2       | 1        | 2 × n bytes |
| Stats     | 2       | 1        | 2 × n bytes |
| Spells    | 2       | 1        | 2 × n bytes |
| Inventory | 2       | 1        | 2 × n bytes |
| Equips    | 2       | 1        | 2 × n bytes |
| Quests    | 1       | 0        | none |
| Plots     | 1       | 0        | none |

### Per-Component Item Schema

**Traits** (4 items):

| caption | subitem |
|---------|---------|
| `Name`  | character name |
| `Race`  | race name |
| `Class` | class name |
| `Level` | integer as string |

**Stats** (8 items): STR / CON / DEX / INT / WIS / CHA / HP Max / MP Max,
caption = stat name, subitem = integer as string.

**Equips** (11 items, fixed slots): caption = slot name (Weapon … Sollerets),
subitem = equipped item name or `''`.

**Spells** (variable): caption = spell name, subitem = Roman numeral level.

**Inventory** (variable): caption = item name, subitem = integer count.
First entry is always `Gold`.

**Quests** (up to 100 in older saves; FPC port trims to 99): caption = quest
description, no subitem. `iImage=1` → completed, `iImage=0` → current.

**Plots** (up to 100 in older saves; FPC port trims to 99): caption = act name
(`Prologue`, `Act I`, …). `iImage=1` → completed, `iImage=0` → current act.

## Verified Example: Rogarian.pq3

Character: Rogarian, Double Wookiee / Tongueblade, Level 82

| Component | blob size | item_count | trailing |
|-----------|-----------|------------|---------|
| Traits    | 275 B     | 4          | 8 B     |
| Stats     | 459 B     | 8          | 16 B    |
| Spells    | 3671 B    | 46         | 92 B    |
| Inventory | 79747 B   | 865        | 1730 B  |
| Equips    | 1193 B    | 11         | 22 B    |
| Quests    | 7261 B    | 100        | 0       |
| Plots     | 3107 B    | 70         | 0       |

- `fTask.Caption`: `kill|Will-o-the-Wisp|9|wisp`
- `fQuest.Caption`: `Ice Devil|11|snow`
- `TaskBar`: Position=5268, Max=5268 (task complete, dequeues on next tick)
- `ExpBar`: Position=2590116, Max=5694632
- `PlotBar`: Position=498868, Max=1245600
- `EncumBar`: Position=4480, Max=8099
