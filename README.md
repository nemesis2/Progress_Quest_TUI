# Progress Quest 6.4.1 — TUI Port

> *"Gone are the tedious micromanagement and other frustrations common to that older
> generation of RPGs."*

**Progress Quest** is a satirical zero-player RPG by [Eric Fredricksen](http://progressquest.com).
Your character auto-levels, auto-quests, and auto-loots — no input needed beyond
character creation. It is a loving parody of MMO grinding culture.

This repository is a **Free Pascal port** of the original
[Progress Quest 6.4](http://progressquest.com) (Delphi 6 / Windows), version **6.4.1**, to a
cross-platform terminal UI using raw ANSI escape codes — no curses dependency,
no external libraries. Runs on **Linux** and **Windows** (10 v1511+).

---

## Screenshot

```
 Progress Quest TUI 6.4.1 - Online - Realm: Nessus                              
                                                                                 
 Grumdrig Understeady - Motto: Grind on! EXP │████████████░░░░░░│ 31337/50000  
 Half Orc Vegan Level 12            Currently in Act IV: Woebetide               
                                                                                 
 Executing a Dexterity Monkey for its Wyvern Scales...                          
 │████████████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│          
                                                                                 
 Stats:                  │  Equipment:                                           
  STR       42           │   Weapon      Glowing Bonesaw of Wounding             
  CON       38           │   Shield      Studded Targe                           
  DEX       51           │   Helm        Warded Barbute                          
  INT       29           │   Hauberk     Briny Hauberk of Negation               
  WIS       33           │   ...                                                 
  CHA       17           │                                                       
  HP Max    74           │  Quests:                                              
  MP Max    46           │   [x] Solve the Mystery of the Missing Sock           
                         │   [x] Placate the Phrenologist                        
 Inventory:              │   [-] Locate the Enchanted Weapon                     
  Toad Stone        x3   │                                                       
  Wererat Tail      x7   │                                                       
  Gorgon Tooth      x12  │                                                       
                                                                                 
 Encum │████████░░│ 81/139   │  Plot  │██████████░░░░░│ 2103/4200               
 Keys  [Q]uit  [S]ave  [E]xport  [B]rag Online  │  Quest │████░░░░░░░░░░░│ 1750/9000
```

---

## Features

- **Truly zero-player** — sit back and watch your character's legend unfold
- **Online leaderboard** — register with a Progress Quest realm and compete at
  [progressquest.com/realms.php](http://progressquest.com/realms.php)
- **Compatible save files** — `.pq3` files round-trip with the original Windows client
- **No external dependencies** — zlib compression handled by bundled pure-Pascal
  sources in `paszlib/`
- **Cross-platform** — one codebase, `{$IFDEF WINDOWS}` guards for the platform
  differences in terminal control and timing

---

## Building

Requires [Free Pascal](https://www.freepascal.org/) (`fpc`) only.

```bash
./build.sh
```

Compiles everything in one `fpc -O3 -Xs -Fu./paszlib pq_tui.pas` invocation;
FPC resolves unit dependencies automatically. Produces the `pq_tui` binary.
On Windows use `build.bat`.

### ARM note

When cross-compiling for ARMHF you may see:

```
Warning: "crtbegin.o" not found, this will probably cause a linking failure
Warning: "crtend.o" not found, this will probably cause a linking failure
```

These warnings are harmless. `crtbegin.o`/`crtend.o` are C runtime objects that
the ARM linker looks for but never actually uses for pure Pascal code. The binary
links and runs correctly. To silence the warnings, install the ARM gcc toolchain:

```bash
sudo apt-get install gcc-arm-linux-gnueabihf
```

Installing it does not affect binary size — the objects are found but not pulled in.

---

## Running

```bash
./pq_tui                            # new character (interactive creation)
./pq_tui save.pq3                   # load existing save file
./pq_tui -export save.pq3           # load and export .sheet on each save
./pq_tui -export-only save.pq3      # export .sheet then exit
./pq_tui -no-backup save.pq3        # load without writing a backup on save
./pq_tui -set-motto save.pq3        # interactively set/clear the character motto
./pq_tui -motto "My motto" save.pq3 # set motto non-interactively then exit
./pq_tui -help                      # show all flags
```

**In-game keys:** `q` quit · `s` save · `e` export character sheet · `b` post to leaderboard · `m` toggle Minimal Mode

### Minimal Mode

Press `m` to toggle **Minimal Mode** — a compact view that collapses the stats,
equipment, inventory, and quest panels down to just the title bar, name/EXP row,
race/class/level row, encumbrance, plot progress, and quest progress. The redraw
rate drops from 5 Hz (every 200 ms) to 0.2 Hz (every 5 s), which considerably
reduces CPU usage — useful when running in the background or on low-power hardware.
The title bar shows `- Minimal Mode` when active.

---

## Architecture

All source lives in the project root. Entry point is `pq_tui.pas`.

| Unit | Role |
|------|------|
| `pq_tui.pas` | Main loop: 100 ms ticks, 200 ms redraws, keyboard input, auto-save every 60 s |
| `GameLogic.pas` | `TickGame`, `LevelUp`, `Dequeue`, quest/plot/monster logic |
| `GameState.pas` | `TGameState` record, inventory/equip/spell helpers |
| `GameData.pas` | All content: monsters, spells, items, races, classes, equipment tables |
| `SaveFile.pas` | Load/save `.pq3` files (zlib-compressed DFM), character sheet export |
| `TUI.pas` | ANSI terminal UI, non-blocking keyboard input, row-level diff renderer; `TUI_Toast` for transient bottom-row notifications; ANSI-aware `TruncateStr`/`DispWidth` so colour codes never consume the cell budget |
| `CharCreate.pas` | TUI character creation: stat rolling, race/class selection, motto prompt |
| `BragOnline.pas` | HTTP GET helper; posts level-up/act/save events to progressquest.com; returns success/failure to caller |
| `zlibc.pas` | zlib stream wrappers using bundled `paszlib/` (no external DLL/SO) |

See [`SAVE_FORMAT.md`](SAVE_FORMAT.md) for the binary save file specification.

---

## Attribution

**Progress Quest** was created by **Eric Fredricksen** and is copyright © 2022
Eric Fredricksen. The original Delphi source is available at
<https://bitbucket.org/grumdrig/pq/> and at <http://progressquest.com>.

This Free Pascal port is a derivative work and is distributed under the same
licence as the original. The game content (monsters, spells, items, races,
classes, quests, plot acts) and save-file format are taken directly from the
original source.

---

## License

```
Progress Quest version 6.4
Copyright (c) 2022 Eric Fredricksen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
