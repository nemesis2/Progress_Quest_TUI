unit CharCreate;
{ TUI-based character creation for Progress Quest }

{$mode objfpc}{$H+}

interface

uses SysUtils, GameState, TUI, GameData;

{ Returns: 0=quit, 1=load game, 2=new character }
function  CharCreateMenu: Integer;
function  CharCreateLoad(var FileName: string; out GS: TGameState): Boolean;
function  CharCreateNew(var GS: TGameState; out SaveFile: string): Boolean;

implementation

uses SaveFile, GameLogic, Math, BragOnline;

const
  ESC     = #27;
  BOLD    = #27 + '[1m';
  INVERSE = #27 + '[7m';
  COLOR_R = #27 + '[31m';
  COLOR_G = #27 + '[32m';
  COLOR_Y = #27 + '[33m';
  COLOR_C = #27 + '[36m';
  NORMAL  = #27 + '[0m';

  KFileExt = '.pq3';

  { Navigation keys returned by ReadNavKey }
  KEY_SELECT   = 1;
  KEY_UP_NAV   = 2;
  KEY_DOWN_NAV = 3;
  KEY_QUIT_NAV = 4;

{ ---- Stat rolling ---- }

procedure RollStat(var s: Integer);
begin
  s := 3 + Random(6) + Random(6) + Random(6);
end;

procedure RollAllStats(var Stats: array of Integer);
var
  i: Integer;
begin
  for i := 0 to 5 do
    RollStat(Stats[i]);
end;

function StatsTotal(const Stats: array of Integer): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Stats) do
    Inc(Result, Stats[i]);
end;

function StatsColor(total: Integer): string;
begin
  if total >= 81 then Result := COLOR_R
  else if total > 72 then Result := COLOR_Y
  else if total <= 45 then Result := COLOR_C
  else if total < 54 then Result := COLOR_G
  else Result := NORMAL;
end;

procedure DrawTitleBar;
var pad: Integer;
begin
  pad := TermCols - Length(' Progress Quest TUI 6.4.1 ');
  if pad < 0 then pad := 0;
  WriteLn(INVERSE + ' Progress Quest TUI 6.4.1 ' + StringOfChar(' ', pad) + NORMAL);
  WriteLn;
end;

{ ---- Title screen ---- }

function CharCreateMenu: Integer;
var
  key: Integer;
  width: Integer;
begin
  width := TermCols;
  if width > 80 then width := 80;

  repeat
    TUI_Clear;
    DrawTitleBar;
    WriteLn('  [' + BOLD + 'N' + NORMAL + ']' + ' New Character');
    WriteLn('  [' + BOLD + 'L' + NORMAL + ']' + ' Load Game');
    WriteLn('  [' + BOLD + 'Q' + NORMAL + ']' + ' Quit');
    WriteLn;
    WriteLn('  Press a key to choose...');
    Flush(Output);

    key := TUI_WaitKey;
  until key in [Ord('n'), Ord('N'), Ord('l'), Ord('L'), Ord('q'), Ord('Q')];

  case key of
    Ord('n'), Ord('N'): Result := 2;
    Ord('l'), Ord('L'): Result := 1;
    else                Result := 0;
  end;
end;

{ ---- Load game ---- }

function CharCreateLoad(var FileName: string; out GS: TGameState): Boolean;
var
  input: string;
begin
  Result := False;
  TUI_Clear;
  DrawTitleBar;
  WriteLn('Enter save file name (e.g. mygame.pq):');
  TUI_Prompt('  > ', input);
  if input = '' then Exit;
  if not FileExists(input) then begin
    WriteLn('File not found: ' + input);
    WriteLn('Press any key...');
    TUI_WaitKey;
    Exit;
  end;
  FileName := input;
  Result := LoadSave(input, GS);
  if not Result then begin
    WriteLn('Error loading save file.');
    WriteLn('Press any key...');
    TUI_WaitKey;
  end;
end;

{ ---- Race/class selection ---- }

function ReadNavKey: Integer;
{ Returns KEY_* constant. Handles j/k, Enter, q, arrow keys on all platforms. }
var k: Integer;
begin
  k := TUI_WaitKey;
  case k of
    10, 13:                Result := KEY_SELECT;
    Ord('j'), Ord('J'):    Result := KEY_DOWN_NAV;
    Ord('k'), Ord('K'):    Result := KEY_UP_NAV;
    Ord('q'), Ord('Q'):    Result := KEY_QUIT_NAV;
    KEY_ARROW_UP:          Result := KEY_UP_NAV;
    KEY_ARROW_DOWN:        Result := KEY_DOWN_NAV;
    27: begin { ESC — try to read the rest of a CSI escape sequence (Linux) }
      k := TUI_GetKey;
      if k = Ord('[') then begin
        k := TUI_GetKey;
        case k of
          Ord('A'): Result := KEY_UP_NAV;
          Ord('B'): Result := KEY_DOWN_NAV;
          else      Result := 0;
        end;
      end else
        Result := 0;
    end;
    else Result := k;
  end;
end;

function SelectRace: Integer;
var
  nav: Integer;
  sel, total, maxPage, page, startIdx, endIdx, i: Integer;
begin
  sel := 0;
  total := Length(Races);

  repeat
    maxPage := TermRows - 7;
    if maxPage < 5 then maxPage := 5;
    page     := sel div maxPage;
    startIdx := page * maxPage;
    endIdx   := Min(startIdx + maxPage, total);

    TUI_Clear;
    DrawTitleBar;
    WriteLn(BOLD + 'Select a Race (' + IntToStr(sel + 1) + '/' +
            IntToStr(total) + '):' + NORMAL);
    WriteLn('Use keys j/k or arrows to move, Enter to select, q to quit');
    WriteLn('');

    for i := startIdx to endIdx - 1 do begin
      if i = sel then
        WriteLn('  ' + BOLD + COLOR_Y + '>> ' + NORMAL + DSplit(Races[i], 0))
      else
        WriteLn('    ' + DSplit(Races[i], 0));
    end;
    if endIdx < total then
      WriteLn('  ... ' + IntToStr(total - endIdx) + ' more below');
    Flush(Output);

    nav := ReadNavKey;
    case nav of
      KEY_DOWN_NAV: sel := (sel + 1) mod total;
      KEY_UP_NAV:   sel := (sel - 1 + total) mod total;
      KEY_QUIT_NAV: Exit(-1);
      KEY_SELECT:   Exit(sel);
    end;
  until False;

  Result := sel;
end;

function SelectClass: Integer;
var
  nav: Integer;
  sel, total, maxPage, page, startIdx, endIdx, i: Integer;
begin
  sel := 0;
  total := Length(Klasses);

  repeat
    maxPage  := TermRows - 7;
    if maxPage < 5 then maxPage := 5;
    page     := sel div maxPage;
    startIdx := page * maxPage;
    endIdx   := Min(startIdx + maxPage, total);

    TUI_Clear;
    DrawTitleBar;
    WriteLn(BOLD + 'Select a Class (' + IntToStr(sel + 1) + '/' +
            IntToStr(total) + '):' + NORMAL);
    WriteLn('Use keys j/k or arrows to move, Enter to select, q to quit');
    WriteLn('');

    for i := startIdx to endIdx - 1 do begin
      if i = sel then
        WriteLn('  ' + BOLD + COLOR_Y + '>> ' + NORMAL + DSplit(Klasses[i], 0))
      else
        WriteLn('    ' + DSplit(Klasses[i], 0));
    end;
    if endIdx < total then
      WriteLn('  ... ' + IntToStr(total - endIdx) + ' more below');
    Flush(Output);

    nav := ReadNavKey;
    case nav of
      KEY_DOWN_NAV: sel := (sel + 1) mod total;
      KEY_UP_NAV:   sel := (sel - 1 + total) mod total;
      KEY_QUIT_NAV: Exit(-1);
      KEY_SELECT:   Exit(sel);
    end;
  until False;

  Result := sel;
end;

{ ---- Online/offline selection ---- }

function AskOnlineMode: Integer;
{ Returns: 1=online, 0=offline, -1=quit. }
var key: Integer;
begin
  repeat
    TUI_Clear;
    DrawTitleBar;
    WriteLn(BOLD + 'Character Creation — Play Mode' + NORMAL);
    WriteLn;
    WriteLn('  [' + BOLD + 'O' + NORMAL + '] Online   — register on progressquest.com');
    WriteLn('  [' + BOLD + 'F' + NORMAL + '] Offline  — play locally, no registration');
    WriteLn('  [' + BOLD + 'Q' + NORMAL + '] Quit');
    WriteLn;
    WriteLn('  Press a key to choose...');
    Flush(Output);
    key := TUI_WaitKey;
  until key in [Ord('o'), Ord('O'), Ord('f'), Ord('F'), Ord('q'), Ord('Q'), 27];
  case key of
    Ord('o'), Ord('O'): Result := 1;
    Ord('q'), Ord('Q'), 27: Result := -1;
    else Result := 0;
  end;
end;

function SelectRealmNav(const Realms: TOnlineRealmArr; DefIdx: Integer): Integer;
{ Nav-list of available online realms.  Returns realm index, or -1 if quit. }
var
  nav: Integer;
  sel, total, maxPage, page, startIdx, endIdx, i: Integer;
begin
  if Length(Realms) = 0 then Exit(-1);
  sel   := DefIdx;
  total := Length(Realms);

  repeat
    maxPage  := TermRows - 10;
    if maxPage < 4 then maxPage := 4;
    page     := sel div maxPage;
    startIdx := page * maxPage;
    endIdx   := Min(startIdx + maxPage, total);

    TUI_Clear;
    DrawTitleBar;
    WriteLn(BOLD + 'Online Registration — Select Realm (' +
            IntToStr(sel + 1) + '/' + IntToStr(total) + '):' + NORMAL);
    WriteLn('Use j/k or arrows to move, Enter to select, q to quit');
    WriteLn;

    for i := startIdx to endIdx - 1 do begin
      if i = sel then
        WriteLn('  ' + BOLD + COLOR_Y + '>> ' + NORMAL + Realms[i].Name)
      else
        WriteLn('    ' + Realms[i].Name);
    end;
    if endIdx < total then
      WriteLn('  ... ' + IntToStr(total - endIdx) + ' more below');

    { Show description of the currently highlighted realm }
    if (sel >= 0) and (sel < total) and (Realms[sel].Desc <> '') then begin
      WriteLn;
      WriteLn('  ' + COLOR_C + Realms[sel].Desc + NORMAL);
    end;
    Flush(Output);

    nav := ReadNavKey;
    case nav of
      KEY_DOWN_NAV: sel := (sel + 1) mod total;
      KEY_UP_NAV:   sel := (sel - 1 + total) mod total;
      KEY_QUIT_NAV: Exit(-1);
      KEY_SELECT:   Exit(sel);
    end;
  until False;

  Result := sel;
end;

{ ---- Character creation ---- }

function CharCreateNew(var GS: TGameState; out SaveFile: string): Boolean;
var
  stats: array[0..5] of Integer;
  rerolls:  array of Integer;
  key: Integer;
  name: string;
  raceIdx, classIdx: Integer;
  total: Integer;
  onlineMode:              Integer;  { -1=quit, 0=offline, 1=online }
  realms:                  TOnlineRealmArr;
  defRealmIdx, selRealm:   Integer;
  account, password:       string;
  motto, passkey, errMsg:  string;
begin
  Result := False;
  InitNewGame(GS);
  SetLength(rerolls, 0);
  SetLength(realms, 0);
  defRealmIdx := 0;

  { Online / offline selection — first thing, sets the play mode }
  onlineMode := AskOnlineMode;
  if onlineMode < 0 then Exit(False);

  { Roll initial stats }
  RollAllStats(stats);

  repeat
    total := StatsTotal(stats);
    TUI_Clear;
    DrawTitleBar;
    WriteLn(BOLD + 'Character Creation - Stat Rolling' + NORMAL);
    WriteLn;
    WriteLn('  ' + BOLD + 'STR: ' + NORMAL + IntToStr(stats[0]));
    WriteLn('  ' + BOLD + 'CON: ' + NORMAL + IntToStr(stats[1]));
    WriteLn('  ' + BOLD + 'DEX: ' + NORMAL + IntToStr(stats[2]));
    WriteLn('  ' + BOLD + 'INT: ' + NORMAL + IntToStr(stats[3]));
    WriteLn('  ' + BOLD + 'WIS: ' + NORMAL + IntToStr(stats[4]));
    WriteLn('  ' + BOLD + 'CHA: ' + NORMAL + IntToStr(stats[5]));
    WriteLn;
    WriteLn('  Total: ' + StatsColor(total) + IntToStr(total) + NORMAL);
    WriteLn;
    if Length(rerolls) > 0 then
      WriteLn('  Rolls available: ' + IntToStr(Length(rerolls)))
    else
      WriteLn('  Rolls available: 0');
    WriteLn;
  WriteLn('  [' + BOLD + 'R' + NORMAL + '] Re-roll all stats');
    WriteLn('  [' + BOLD + 'U' + NORMAL + '] Undo last roll');
    WriteLn('  [' + BOLD + 'Enter' + NORMAL + '] Accept stats & continue');
    WriteLn('  [' + BOLD + 'Q' + NORMAL + '] Quit');

    key := TUI_WaitKey;

    case key of
      Ord('r'), Ord('R'): begin
        SetLength(rerolls, Length(rerolls) + 1);
        rerolls[Length(rerolls)-1] := RandSeed;
        RollAllStats(stats);
      end;
      Ord('u'), Ord('U'): begin
        if Length(rerolls) > 0 then begin
          RandSeed := rerolls[Length(rerolls)-1];
          SetLength(rerolls, Length(rerolls) - 1);
          RollAllStats(stats);
        end;
      end;
      Ord('q'), Ord('Q'): Exit(False);
      13, 10: Break;
    end;
  until False;

  { Name input }
  name := '';
  repeat
    TUI_Clear;
    DrawTitleBar;
    WriteLn(BOLD + 'Character Creation - Name' + NORMAL);
    WriteLn;
    WriteLn('  Enter your character name,');
    WriteLn('  or leave blank to have one generated.');
    WriteLn;
    TUI_Prompt('  Name: ', name);
    if name <> '' then Break;

    name := GenerateName;
    repeat
      TUI_Clear;
      DrawTitleBar;
      WriteLn(BOLD + 'Character Creation - Name' + NORMAL);
      WriteLn;
      WriteLn('  Generated: ' + BOLD + name + NORMAL);
      WriteLn;
      WriteLn('  [Enter] Accept   [G] Generate another   [T] Type your own');
      Flush(Output);
      key := TUI_WaitKey;
      if key in [Ord('g'), Ord('G')] then
        name := GenerateName;
    until key in [13, 10, Ord('t'), Ord('T')];

    if key in [Ord('t'), Ord('T')] then begin
      name := '';
      Continue;
    end;
    Break;
  until False;

  { Sanitize name for filename }
  SaveFile := name + KFileExt;

  { Race selection }
  repeat
    raceIdx := SelectRace;
    if raceIdx < 0 then Exit(False);
    TUI_Clear;
    DrawTitleBar;
    WriteLn('Selected race: ' + BOLD + DSplit(Races[raceIdx], 0) + NORMAL);
    WriteLn('Press Enter to accept, R to re-select, Q to quit.');
    key := TUI_WaitKey;
  until key in [13, 10, Ord('q'), Ord('Q')];
  if key in [Ord('q'), Ord('Q')] then Exit(False);

  { Class selection }
  repeat
    classIdx := SelectClass;
    if classIdx < 0 then Exit(False);
    TUI_Clear;
    DrawTitleBar;
    WriteLn('Selected class: ' + BOLD + DSplit(Klasses[classIdx], 0) + NORMAL);
    WriteLn('Press Enter to accept, R to re-select, Q to quit.');
    key := TUI_WaitKey;
  until key in [13, 10, Ord('q'), Ord('Q')];
  if key in [Ord('q'), Ord('Q')] then Exit(False);

  { Motto — stored in every save; shown on leaderboard for online characters }
  motto := '';
  TUI_Clear;
  DrawTitleBar;
  WriteLn(BOLD + 'Character Creation — Motto' + NORMAL);
  WriteLn;
  WriteLn('  Enter a motto (leave blank to skip):');
  WriteLn('  Online: shown on the progressquest.com leaderboard.');
  WriteLn;
  TUI_Prompt('  Motto: ', motto);

  { ---- Online registration ---- }

  if onlineMode = 1 then begin
    { Fetch realm list }
    TUI_Clear;
    DrawTitleBar;
    WriteLn(BOLD + 'Online Registration' + NORMAL);
    WriteLn;
    WriteLn('  Contacting progressquest.com...');
    Flush(Output);

    if not BragFetchRealms(realms, defRealmIdx) then begin
      WriteLn;
      WriteLn('  ' + COLOR_R + 'Could not reach the server.' + NORMAL);
      WriteLn('  Your character will be created offline instead.');
      WriteLn;
      WriteLn('  Press any key...');
      TUI_WaitKey;
      onlineMode := 0;
    end;
  end;

  if onlineMode = 1 then begin
    { Select realm }
    selRealm := SelectRealmNav(realms, defRealmIdx);
    if selRealm < 0 then Exit(False);

    { Credentials (only some realms require them; standard PQ does not) }
    account  := '';
    password := '';
    if realms[selRealm].Options and 8 <> 0 then begin
      TUI_Clear;
      DrawTitleBar;
      WriteLn(BOLD + 'Online Registration — Credentials' + NORMAL);
      WriteLn;
      WriteLn('  This realm requires an account.');
      WriteLn;
      TUI_Prompt('  Account:  ', account);
      TUI_Prompt('  Password: ', password);
    end;

    { Register — retry loop until success, offline fallback, or quit }
    repeat
      TUI_Clear;
      DrawTitleBar;
      WriteLn(BOLD + 'Online Registration' + NORMAL);
      WriteLn;
      WriteLn('  Registering ' + BOLD + name + NORMAL +
              ' on ' + BOLD + realms[selRealm].Name + NORMAL + '...');
      Flush(Output);

      passkey := '';
      errMsg  := '';
      if BragRegister(name, realms[selRealm].Name,
                      realms[selRealm].HostURL, realms[selRealm].Options,
                      account, password, passkey, errMsg) then begin
        { Success: populate the round-trip fields Brag() reads later }
        GS.TraitsTag     := StrToIntDef(passkey, 0);
        GS.TraitsHint    := passkey;
        GS.SpellsHint    := realms[selRealm].Name;
        GS.EquipsHint    := realms[selRealm].HostURL;
        GS.InventoryHint := account;
        GS.PlotsHint     := password;
        GS.Label8Tag     := realms[selRealm].Options;
        WriteLn;
        WriteLn('  ' + COLOR_G + 'Registered! Passkey: ' + passkey + NORMAL);
        WriteLn;
        WriteLn('  Press any key...');
        TUI_WaitKey;
        Break;
      end else begin
        WriteLn;
        WriteLn('  ' + COLOR_R + 'Registration failed:' + NORMAL);
        WriteLn('  ' + errMsg);
        WriteLn;
        WriteLn('  [' + BOLD + 'R' + NORMAL + '] Retry');
        WriteLn('  [' + BOLD + 'F' + NORMAL + '] Play offline instead');
        WriteLn('  [' + BOLD + 'Q' + NORMAL + '] Quit');
        Flush(Output);
        repeat
          key := TUI_WaitKey;
        until key in [Ord('r'), Ord('R'), Ord('f'), Ord('F'), Ord('q'), Ord('Q')];
        if key in [Ord('q'), Ord('Q')] then Exit(False);
        if key in [Ord('f'), Ord('F')] then begin
          onlineMode := 0;
          Break;
        end;
        { Ord('r'), Ord('R'): fall through to retry }
      end;
    until False;
  end;

  { Apply race/class stat bonuses }
  GS.CharName := name;
  GS.Race := DSplit(Races[raceIdx], 0);
  GS.Klass := DSplit(Klasses[classIdx], 0);
  GS.Level := 1;
  GS.Stats[STAT_STR] := stats[0];
  GS.Stats[STAT_CON] := stats[1];
  GS.Stats[STAT_DEX] := stats[2];
  GS.Stats[STAT_INT] := stats[3];
  GS.Stats[STAT_WIS] := stats[4];
  GS.Stats[STAT_CHA] := stats[5];
  GS.Stats[STAT_HPMAX] := Random(8) + stats[1] div 6;
  GS.Stats[STAT_MPMAX] := Random(8) + stats[3] div 6;

  { Apply race bonuses }
  case raceIdx of
    0: Inc(GS.Stats[STAT_HPMAX]);  { Half Orc }
    1: Inc(GS.Stats[STAT_CHA]);    { Half Man }
    2: Inc(GS.Stats[STAT_DEX]);    { Half Halfling }
    3: Inc(GS.Stats[STAT_STR]);    { Double Hobbit }
    4: begin { Hob-Hobbit }
         Inc(GS.Stats[STAT_DEX]);
         Inc(GS.Stats[STAT_CON]);
       end;
    5: Inc(GS.Stats[STAT_CON]);    { Low Elf }
    6: Inc(GS.Stats[STAT_WIS]);    { Dung Elf }
    7: begin { Talking Pony }
         Inc(GS.Stats[STAT_MPMAX]);
         Inc(GS.Stats[STAT_INT]);
       end;
    8: Inc(GS.Stats[STAT_DEX]);    { Gyrognome }
    9: Inc(GS.Stats[STAT_CON]);    { Lesser Dwarf }
    10: Inc(GS.Stats[STAT_CHA]);   { Crested Dwarf }
    11: Inc(GS.Stats[STAT_DEX]);   { Eel Man }
    12: begin { Panda Man }
         Inc(GS.Stats[STAT_CON]);
         Inc(GS.Stats[STAT_STR]);
       end;
    13: Inc(GS.Stats[STAT_WIS]);   { Trans-Kobold }
    14: Inc(GS.Stats[STAT_MPMAX]); { Enchanted Motorcycle }
    15: Inc(GS.Stats[STAT_WIS]);   { Will o'the Wisp }
    16: begin { Battle-Finch }
         Inc(GS.Stats[STAT_DEX]);
         Inc(GS.Stats[STAT_INT]);
       end;
    17: Inc(GS.Stats[STAT_STR]);   { Double Wookiee }
    18: Inc(GS.Stats[STAT_WIS]);   { Skraeling }
    19: Inc(GS.Stats[STAT_CON]);   { Demicanadian }
    20: begin { Land Squid }
         Inc(GS.Stats[STAT_STR]);
         Inc(GS.Stats[STAT_HPMAX]);
       end;
  end;

  { Apply class bonuses }
  case classIdx of
    0: begin { Ur-Paladin }
         Inc(GS.Stats[STAT_WIS]);
         Inc(GS.Stats[STAT_CON]);
       end;
    1: begin { Voodoo Princess }
         Inc(GS.Stats[STAT_INT]);
         Inc(GS.Stats[STAT_CHA]);
       end;
    2: Inc(GS.Stats[STAT_STR]);    { Robot Monk }
    3: Inc(GS.Stats[STAT_DEX]);    { Mu-Fu Monk }
    4: begin { Mage Illusioner }
         Inc(GS.Stats[STAT_INT]);
         Inc(GS.Stats[STAT_MPMAX]);
       end;
    5: Inc(GS.Stats[STAT_DEX]);    { Shiv-Knight }
    6: Inc(GS.Stats[STAT_CON]);    { Inner Mason }
    7: begin { Fighter/Organist }
         Inc(GS.Stats[STAT_CHA]);
         Inc(GS.Stats[STAT_STR]);
       end;
    8: Inc(GS.Stats[STAT_DEX]);    { Puma Burgular }
    9: Inc(GS.Stats[STAT_WIS]);    { Runeloremaster }
    10: begin { Hunter Strangler }
         Inc(GS.Stats[STAT_DEX]);
         Inc(GS.Stats[STAT_INT]);
       end;
    11: Inc(GS.Stats[STAT_STR]);   { Battle-Felon }
    12: begin { Tickle-Mimic }
         Inc(GS.Stats[STAT_WIS]);
         Inc(GS.Stats[STAT_INT]);
       end;
    13: Inc(GS.Stats[STAT_CON]);   { Slow Poisoner }
    14: Inc(GS.Stats[STAT_CON]);   { Bastard Lunatic }
    15: begin { Jungle Clown }
         Inc(GS.Stats[STAT_DEX]);
         Inc(GS.Stats[STAT_CHA]);
       end;
    16: Inc(GS.Stats[STAT_WIS]);   { Birdrider }
    17: Inc(GS.Stats[STAT_INT]);   { Vermineer }
  end;

  { Initial equipment and inventory }
  GS.Equips[0] := 'Sharp Stick';
  SetLength(GS.Inventory, 1);
  GS.Inventory[0].Key := 'Gold';
  GS.Inventory[0].Val := '0';

  GS.GameStyle := 3;
  { Do not reset Label8Tag here — online registration already set it above.
    InitNewGame initialised it to 0 (offline default). }
  GS.StatsHint := motto;

  { Show summary }
  TUI_Clear;
  DrawTitleBar;
  WriteLn(BOLD + 'Character Summary' + NORMAL);
  WriteLn;
  WriteLn('  Name:  ' + GS.CharName);
  WriteLn('  Race:  ' + GS.Race);
  WriteLn('  Class: ' + GS.Klass);
  WriteLn;
  WriteLn('  STR: ' + IntToStr(GS.Stats[STAT_STR]));
  WriteLn('  CON: ' + IntToStr(GS.Stats[STAT_CON]));
  WriteLn('  DEX: ' + IntToStr(GS.Stats[STAT_DEX]));
  WriteLn('  INT: ' + IntToStr(GS.Stats[STAT_INT]));
  WriteLn('  WIS: ' + IntToStr(GS.Stats[STAT_WIS]));
  WriteLn('  CHA: ' + IntToStr(GS.Stats[STAT_CHA]));
  WriteLn('  HP:  ' + IntToStr(GS.Stats[STAT_HPMAX]));
  WriteLn('  MP:  ' + IntToStr(GS.Stats[STAT_MPMAX]));
  WriteLn;
  WriteLn('  Save file: ' + SaveFile);
  WriteLn;
  WriteLn('  Press Enter to begin your adventure...');
  TUI_WaitKey;

  Result := True;
end;

end.
