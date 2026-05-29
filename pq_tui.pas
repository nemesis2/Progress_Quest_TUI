program pq;
{ Progress Quest 6.4 — Linux TUI port using Free Pascal }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Math,
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  GameState, GameData, GameLogic, SaveFile, TUI, CharCreate, BragOnline;

{$IFDEF WINDOWS}
function GetMillisNow: LongInt;
begin
  Result := LongInt(GetTickCount64 and $7FFFFFFF);
end;
{$ELSE}
type
  timeval = record
    tv_sec:  NativeInt;   { time_t = C long: 4 bytes on 32-bit, 8 on 64-bit }
    tv_usec: NativeInt;   { suseconds_t = C long }
  end;

function gettimeofday(var tv: timeval; tz: Pointer): Integer; cdecl; external 'c' name 'gettimeofday';
function usleep(usecs: LongWord): Integer; cdecl; external 'c' name 'usleep';

function GetMillisNow: LongInt;
var tv: timeval;
begin
  gettimeofday(tv, nil);
  Result := LongInt(tv.tv_sec * 1000 + tv.tv_usec div 1000);
end;
{$ENDIF}

const
  KFileExt   = '.pq3';
  SaveInterval = 60; { seconds between auto-saves }
  TickInterval = 100; { ms between game ticks }

var
  GS: TGameState;
  SaveFileName: string;
  MakeBackup: Boolean;
  ExportSheets: Boolean;
  Running: Boolean;
  LastSaveTime: LongInt;
  LastTick: LongInt;
  i: Integer;
  SetMottoMode: Boolean;  { -set-motto or -motto flag was given }
  SetMottoText: string;   { non-empty → non-interactive: set motto directly }

function GetSaveName: string;
begin
  Result := GS.CharName + KFileExt;
end;

procedure AutoSave;
var
  ok: Boolean;
  elapsed: LongInt;
begin
  { Save every SaveInterval seconds }
  elapsed := LastTick div 1000 - LastSaveTime;
  if elapsed < SaveInterval then Exit;

  LastSaveTime := LastTick div 1000;
  SaveFileName := GetSaveName;
  ok := SaveSave(SaveFileName, GS, MakeBackup);
  if not ok then
    TUI_Toast('Auto-save failed!');

  if ExportSheets then begin
    try
      ExportCharSheet(ChangeFileExt(SaveFileName, '.sheet'), GS);
    except
      on E: Exception do
        TUI_Toast('Auto-export failed: ' + E.Message);
    end;
  end;
end;

procedure DoSaveAndExit;
begin
  SaveFileName := GetSaveName;
  SaveSave(SaveFileName, GS, MakeBackup);
  if ExportSheets then
    ExportCharSheet(ChangeFileExt(SaveFileName, '.sheet'), GS);
end;

function TitleCase(const s: string): string;
var i: Integer;
begin
  Result := s;
  if Result = '' then Exit;
  Result[1] := UpCase(Result[1]);
  for i := 2 to Length(Result) do
    if Result[i-1] = ' ' then
      Result[i] := UpCase(Result[i]);
end;

function PluralizeItem(const s: string): string;
{ Returns the plural form of a title-cased item name.
  Uncountable and already-plural words are returned unchanged.
  "Tooth" -> "Teeth" (irregular). Regular English suffix rules otherwise. }
const
  NoChange: array[0..31] of string = (
    'blood', 'chitin', 'cigarettes', 'condensation', 'drawers', 'drops',
    'dung', 'dust', 'foam', 'fur', 'gel', 'gills', 'gravy', 'gravel',
    'jam', 'leathers', 'lube', 'matches', 'mulch', 'pajamas', 'pants',
    'recycling', 'saliva', 'shag', 'shavings', 'slime', 'snow', 'teeth',
    'twine', 'vomit', 'webbing', 'wool');
var
  lc, last2: string;
  last: Char;
  i: Integer;
begin
  if s = '' then begin Result := s; Exit; end;
  lc := LowerCase(s);
  if lc = 'tooth' then begin Result := 'Teeth'; Exit; end;
  for i := 0 to High(NoChange) do
    if lc = NoChange[i] then begin Result := s; Exit; end;
  last := lc[Length(lc)];
  if Length(lc) >= 2 then last2 := Copy(lc, Length(lc)-1, 2) else last2 := '';
  if (last2 = 'ch') or (last2 = 'sh') or (last in ['s', 'x', 'z']) then
    Result := s + 'es'
  else
    Result := s + 's';
end;

function GetTaskDescription: string;
var
  s: string;
  i, p: Integer;
begin
  if GS.TaskText = '' then
    Result := 'Waiting...'
  else if Copy(GS.TaskText, 1, 5) = 'kill|' then begin
    { field 4 = display name appended by MonsterTask; skip 4 pipe separators }
    s := GS.TaskText;
    for i := 1 to 4 do begin
      p := Pos('|', s);
      if p = 0 then begin s := ''; Break; end;
      s := Copy(s, p+1, MaxInt);
    end;
    if s <> '' then begin
      Result := 'Executing ' + s;
      if GS.TaskItem <> '' then begin
        { plural when display starts with a digit, e.g. "3 young Anhkhegs" }
        if (s[1] >= '0') and (s[1] <= '9') then
          Result := Result + ' for their ' + PluralizeItem(GS.TaskItem)
        else
          Result := Result + ' for its ' + GS.TaskItem;
      end;
    end else
      Result := 'Executing ...';
  end else if GS.TaskText = 'buying' then
    Result := 'Negotiating purchase of better equipment'
  else if GS.TaskText = 'market' then
    Result := 'Heading to market to sell loot'
  else if GS.TaskText = 'sell' then
    Result := 'Selling loot'
  else if GS.TaskText = 'heading' then
    Result := 'Heading to the killing fields'
  else if GS.TaskText = 'load' then
    Result := 'Loading'
  else
    Result := GS.TaskText; { covers cinematic task descriptions and anything else }
end;

function MillisSince(var Last: LongInt): LongInt;
var now: LongInt;
begin
  now := GetMillisNow;
  Result := now - Last;
  if Result < 0 then Result := 0;
  Last := now;
end;

procedure InitTime(var Last: LongInt);
begin
  Last := GetMillisNow;
end;

procedure ProcessCommandLine;
var
  i: Integer;
  s: string;
  exportOnly: Boolean;
  saveFileName: string;
begin
  MakeBackup   := True;
  ExportSheets := False;
  exportOnly   := False;
  saveFileName := '';
  SetMottoMode := False;
  SetMottoText := '';

  i := 1;
  while i <= ParamCount do begin
    s := ParamStr(i);
    if s = '-no-backup' then
      MakeBackup := False
    else if s = '-export' then
      ExportSheets := True
    else if s = '-export-only' then
      exportOnly := True
    else if s = '-set-motto' then
      SetMottoMode := True
    else if s = '-motto' then begin
      SetMottoMode := True;
      if (i < ParamCount) and (Copy(ParamStr(i + 1), 1, 1) <> '-') then begin
        Inc(i);
        SetMottoText := ParamStr(i);
      end else begin
        WriteLn('Error: -motto requires a motto value, e.g. -motto "My motto"');
        Halt(1);
      end;
    end
    else if s = '-help' then begin
      WriteLn('Usage: pq_tui [flags] [game.pq3]');
      WriteLn('  -no-backup          Do not make a backup file when saving');
      WriteLn('  -export             Export a text character sheet periodically');
      WriteLn('  -export-only        Export a text character sheet now, then exit');
      WriteLn('  -set-motto          Interactively set or clear the character motto');
      WriteLn('  -motto <text>       Set the character motto to <text> (no prompt)');
      WriteLn('  -help               Display this help');
      WriteLn;
      WriteLn('  -set-motto and -motto require a save file argument.');
      Halt(0);
    end
    else begin
      saveFileName := s;
    end;
    Inc(i);
  end;

  { If a save file was specified on command line, load it }
  if saveFileName <> '' then begin
    if LoadSave(saveFileName, GS) then begin
      { Patches for old misspellings }
      for i := 0 to Length(GS.Spells)-1 do begin
        if GS.Spells[i].Key = 'Tonsilectomy' then GS.Spells[i].Key := 'Tonsillectomy';
        if GS.Spells[i].Key = 'Innoculate' then GS.Spells[i].Key := 'Inoculate';
      end;
      SaveFileName := saveFileName;

      if exportOnly then begin
        ExportCharSheet(ChangeFileExt(saveFileName, '.sheet'), GS);
        Halt(0);
      end;

      StartTimer(GS);
    end else begin
      WriteLn('Error loading save file: ' + saveFileName);
      Halt(1);
    end;
  end;
end;

procedure DoSetMotto;
{ Called when -set-motto or -motto <text> flag is present.
  SetMottoText = '' → interactive (prompts at the terminal).
  SetMottoText ≠ '' → non-interactive (sets directly and saves). }
var
  newMotto: string;
begin
  if SetMottoText <> '' then begin
    GS.StatsHint := SetMottoText;
    if SaveSave(GetSaveName, GS, MakeBackup) then
      WriteLn('Motto set to: "' + GS.StatsHint + '"')
    else
      WriteLn('Error: could not save ' + GetSaveName);
  end else begin
    WriteLn('Character: ' + GS.CharName);
    if GS.StatsHint <> '' then
      WriteLn('Current motto: "' + GS.StatsHint + '"')
    else
      WriteLn('Current motto: (none)');
    WriteLn;
    Write('New motto (blank to clear): ');
    ReadLn(newMotto);
    GS.StatsHint := newMotto;
    if SaveSave(GetSaveName, GS, MakeBackup) then begin
      if newMotto <> '' then
        WriteLn('Motto updated: "' + newMotto + '"')
      else
        WriteLn('Motto cleared.');
    end else
      WriteLn('Error: could not save ' + GetSaveName);
  end;
end;

procedure GameLoop;
var
  key: Integer;
  tickElapsed: LongInt;
  taskDesc: string;
  DrawTick: Integer;
  prevLevel, prevPlots: Integer;
  completedAct: TListItem;
  Minimized: Boolean;
  LastTaskText, LastTaskItem: string;
begin
  InitTime(LastTick);
  LastSaveTime := LastTick div 1000;
  Running := True;
  Minimized    := False;
  LastTaskText := #0;   { sentinel: differs from any real TaskText on first draw }
  LastTaskItem := #0;
  taskDesc     := '';
  DrawTick := 1;  { start at 1 so first iteration draws }

  while Running do begin
    { Check for key press (non-blocking: read 1 byte with timeout) }
    key := TUI_GetKey;

    case key of
      Ord('q'), Ord('Q'): begin
        DoSaveAndExit;
        Running := False;
      end;
      Ord('s'), Ord('S'): begin
        SaveFileName := GetSaveName;
        if SaveSave(SaveFileName, GS, MakeBackup) then begin
          if ExportSheets then
            ExportCharSheet(ChangeFileExt(SaveFileName, '.sheet'), GS);
          TUI_Toast('Game saved: ' + SaveFileName);
        end else
          TUI_Toast('Save failed — disk full or permission error?');
      end;
      Ord('e'), Ord('E'): begin
        try
          ExportCharSheet(ChangeFileExt(GetSaveName, '.sheet'), GS);
          TUI_Toast('Character sheet exported: ' + ChangeFileExt(GetSaveName, '.sheet'));
        except
          on E: Exception do
            TUI_Toast('Export failed: ' + E.Message);
        end;
      end;
      Ord('b'), Ord('B'): begin
        { manual brag — network failure silently ignored, matching Delphi '// ats okay.' }
        if Brag(GS, 'b') then  { False only for offline chars (TraitsTag=0) }
          TUI_Toast('Brag posted to progressquest.com.');
      end;
      Ord('m'), Ord('M'): begin
        Minimized := not Minimized;
        TUI_Clear;
        DrawTick := 100;  { force draw on next cycle }
      end;
    else
      if key <> -1 then ; { ignore other keys }
    end;

    if Running then begin
      { Game tick }
      tickElapsed := MillisSince(LastTick);
      if tickElapsed > TickInterval then tickElapsed := TickInterval;
      if tickElapsed > 0 then begin
        prevLevel := GS.Level;
        prevPlots := Length(GS.Plots);
        TickGame(GS, tickElapsed);
        { Mirror Delphi's Brag('l') in LevelUp and Brag('a') in CompleteAct }
        if GS.Level > prevLevel then begin
          Brag(GS, 'l');
          TUI_Toast('Level up!  You are now level ' + IntToStr(GS.Level) + '.');
        end;
        if Length(GS.Plots) > prevPlots then begin
          Brag(GS, 'a');
          if prevPlots > 0 then begin
            completedAct := GS.Plots[prevPlots - 1];
            if completedAct.SubText <> '' then
              TUI_Toast(completedAct.SubText + ' complete!')
            else
              TUI_Toast(completedAct.Text + ' complete!');
          end else
            TUI_Toast('Act complete!');
        end;
        AutoSave;
      end;

      { Draw TUI every 2 ticks (200 ms) normally, or every 50 ticks (5 s) when minimized }
      Inc(DrawTick);
      if (Minimized and (DrawTick >= 50)) or ((not Minimized) and (DrawTick >= 2)) then begin
        DrawTick := 0;
        { Recompute task description only when the task actually changes }
        if (GS.TaskText <> LastTaskText) or (GS.TaskItem <> LastTaskItem) then begin
          taskDesc     := GetTaskDescription;
          LastTaskText := GS.TaskText;
          LastTaskItem := GS.TaskItem;
        end;
        TUI_Draw(GS, taskDesc, Minimized);
      end;
    end;

    { Small sleep to avoid busy-wait }
    {$IFDEF WINDOWS}Sleep(100);{$ELSE}usleep(100000);{$ENDIF}
  end;

  { Clear screen and home cursor on exit — must come after the loop so
    TUI_Draw cannot run again and re-dirty the screen after we clear it. }
  TUI_Clear;
end;

begin
  Randomize;

  ProcessCommandLine;

  { Motto set/edit mode: requires a save file; exits after saving }
  if SetMottoMode then begin
    if GS.CharName = '' then begin
      WriteLn('Error: -set-motto and -motto require a save file argument.');
      WriteLn('  Example: pq_tui -set-motto mygame.pq3');
      Halt(1);
    end;
    DoSetMotto;
    Halt(0);
  end;

  { If no save file was loaded, show title menu and/or character creation }
  if GS.CharName = '' then begin
    TUI_Init;
    TUI_Clear;
    try
      case CharCreateMenu of
        0: Halt(0); { Quit from title }
        1: begin
          { Load existing game }
          if not CharCreateLoad(SaveFileName, GS) then begin
            WriteLn('No valid save file selected.');
            WriteLn('Press any key to continue...');
            TUI_WaitKey;
            Halt(0);
          end;
          { Patches for old misspellings }
          for i := 0 to Length(GS.Spells)-1 do begin
            if GS.Spells[i].Key = 'Tonsilectomy' then GS.Spells[i].Key := 'Tonsillectomy';
            if GS.Spells[i].Key = 'Innoculate' then GS.Spells[i].Key := 'Inoculate';
          end;
        end;
        2: begin
          { New character }
          if not CharCreateNew(GS, SaveFileName) then begin
            TUI_Shutdown;
            Halt(0);
          end;
          { Initialize starting queue }
          GS.QuestText := '';
          GS.TaskText := 'load';
          GS.TaskPos := 0;
          GS.TaskMax := 2000;

          { Add initial cinematic tasks to queue }
          SetLength(GS.Queue, 5);
          GS.Queue[0] := 'task|10|Experiencing an enigmatic and foreboding night vision';
          GS.Queue[1] := 'task|6|Much is revealed about that wise old bastard you''d underestimated';
          GS.Queue[2] := 'task|6|A shocking series of events leaves you alone and bewildered, but resolute';
          GS.Queue[3] := 'task|4|Drawing upon an unexpected reserve of determination, you set out on a long and dangerous journey';
          GS.Queue[4] := 'plot|2|Loading';

          GS.PlotMax := 26;
          SetLength(GS.Plots, 1);
          GS.Plots[0].Text := 'Prologue';
          GS.Plots[0].Done := False;

          { Save initial state }
          SaveSave(SaveFileName, GS, MakeBackup);
          { Delphi calls Brag('s') immediately after GoButtonClick saves }
          Brag(GS, 's');
          StartTimer(GS);
        end;
      end;
    finally
      TUI_Shutdown;
    end;
  end;

  { Main game loop }
  TUI_Init;
  TUI_Clear;
  try
    GameLoop;
  finally
    TUI_Shutdown;
  end;
end.
