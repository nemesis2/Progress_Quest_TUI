unit TUI;
{ Simple TUI for Progress Quest — ANSI escape codes, no curses dependency }

{$mode objfpc}{$H+}

interface

uses SysUtils, GameState, GameData, Math
  {$IFDEF WINDOWS}, Windows{$ENDIF};

procedure TUI_Init;
procedure TUI_Shutdown;
procedure TUI_Clear;
procedure TUI_Draw(const GS: TGameState; const TaskDescription: string; Minimized: Boolean);
procedure TUI_Prompt(const Prompt: string; var Input: string);
function  TUI_GetKey: Integer;   { non-blocking: returns -1 if no input }
function  TUI_WaitKey: Integer;  { blocks until a key is pressed }
procedure TUI_Popup(const msg: string); { modal popup; any key to dismiss }
procedure TUI_Toast(const msg: string); { show msg on bottom line for ~2 s }

const
  { Synthetic key codes returned by TUI_GetKey for non-ASCII keys }
  KEY_ARROW_UP   = 1001;
  KEY_ARROW_DOWN = 1002;

var
  TermCols: Integer;
  TermRows: Integer;

implementation

uses GameLogic;

{$IFNDEF WINDOWS}
type
  _winsize = packed record
    ws_row: UInt16;
    ws_col: UInt16;
    ws_xpixel: UInt16;
    ws_ypixel: UInt16;
  end;

  { Linux x86_64 struct termios — 60 bytes total }
  TTermios = packed record
    iflag:  LongWord;              { offset  0 }
    oflag:  LongWord;              { offset  4 }
    cflag:  LongWord;              { offset  8 }
    lflag:  LongWord;              { offset 12 }
    line:   Byte;                  { offset 16 }
    cc:     array[0..31] of Byte;  { offset 17, NCCS=32 }
    _pad:   array[0..2]  of Byte;  { offset 49, alignment pad }
    ispeed: LongWord;              { offset 52 }
    ospeed: LongWord;              { offset 56 }
  end;

const
  TIOCGWINSZ = $5413;
  TCSANOW    = 0;
  ICANON     = $0002;
  ECHO       = $0008;
  SIGWINCH   = 28;

type
  TSigHandler = procedure(sig: Integer); cdecl;

function  read(fd: Integer; var buf; count: Integer): Integer; cdecl; external 'c' name 'read';
function  ioctl(fd, req: Integer; var argp): Integer; cdecl; external 'c' name 'ioctl';
function  tcgetattr(fd: Integer; var termios): Integer; cdecl; external 'c' name 'tcgetattr';
function  tcsetattr(fd: Integer; optional_actions: Integer; var termios): Integer; cdecl; external 'c' name 'tcsetattr';
function  signal(signum: Integer; handler: TSigHandler): TSigHandler; cdecl; external 'c' name 'signal';
{$ENDIF}

const
  CSI     = #27 + '[';
  ERASE   = CSI + '2J';
  HOME    = CSI + '0;0H';
  CURSOR_SHOW  = CSI + '?25h';
  CURSOR_HIDE  = CSI + '?25l';
  SYNC_BEGIN   = CSI + '?2026h';
  SYNC_END     = CSI + '?2026l';
  BOLD   = CSI + '1m';
  NORMAL = CSI + '0m';
  INVERSE = CSI + '7m';
  COLOR_CYAN  = CSI + '36m';
  COLOR_YELLOW = CSI + '33m';
  COLOR_GREEN  = CSI + '32m';
  COLOR_RED    = CSI + '31m';

  BAR_LEFT  = '│';
  BAR_FULL  = '█';
  BAR_EMPTY = '░';
  BAR_RIGHT = '│';

var
{$IFDEF WINDOWS}
   hIn, hOut:     THandle;
   OldInMode,
   OldOutMode:    DWORD;
{$ELSE}
   OrigTermios:   TTermios;
{$ENDIF}
   PrevLines:     array of string;
   PrevWidth:     Integer;
   ResizePending: Boolean;
   { Reused across frames — allocated once, resized only on terminal resize }
   DrawLeft, DrawRight: array of string;
   DrawChanged: array of Boolean;
   DrawLines: array of string;   { current frame; swapped with PrevLines each draw }
   { Static section cache: stats and equipment — keyed on StaticSeq + width }
   CachedStatLeft:  array[0..8]  of string;   { 1 + STAT_COUNT  = 9  }
   CachedStatRight: array[0..11] of string;   { 1 + EQUIP_SLOTS = 12 }
   CachedSeqStatic: LongInt;
   CachedStatWidth: Integer;
   { Race/Class/Level row — keyed on StaticSeq + lw (independent of Minimized path) }
   CachedRow3L:    string;
   CachedRow3LSeq: LongInt;
   CachedRow3LW:   Integer;
   { Session-static cache: rows that never change during gameplay, keyed on terminal width }
   CachedSessWidth:     Integer;   { -1 = not yet built }
   CachedRow0:          string;    { title bar — normal mode }
   CachedRow0Min:       string;    { title bar — minimized mode }
   CachedRow2L:         string;    { name / motto left }
   CachedFooterOnL:     string;    { keys footer — online char, normal mode }
   CachedFooterOffL:    string;    { keys footer — offline char, normal mode }
   CachedFooterOnMinL:  string;    { keys footer — online char, minimized mode }
   CachedFooterOffMinL: string;    { keys footer — offline char, minimized mode }
   { ACT row cache (row 3 right) — keyed on plot count and rw }
   CachedActR:      string;
   CachedActPlots:  Integer;
   CachedActRW:     Integer;
   { Inventory + quest body cache — keyed on InventorySeq, quest count, and geometry }
   CachedBodyLeft:       array of string;
   CachedBodyRight:      array of string;
   CachedBodyInvSeq:     LongInt;
   CachedBodyQuestCount: Integer;
   CachedBodyStaticSeq:  LongInt;   { spells change with StaticSeq }
   CachedBodyLW:         Integer;
   CachedBodyRW:         Integer;
   CachedBodyTermRows:   Integer;
   { Toast notification — bottom-row transient message }
   ToastMsg:   string;
   ToastTicks: Integer;   { TUI_Draw calls remaining; 10 × 200 ms ≈ 2 s }

procedure ConWrite(const s: string);
{ Route all TUI output through WriteConsoleW on Windows so UTF-8 bar chars
  render correctly without depending on the console code page. }
{$IFDEF WINDOWS}
var ws: WideString; nw: DWORD;
begin
  ws := UTF8Decode(s);
  WriteConsoleW(hOut, PWideChar(ws), Length(ws), nw, nil);
end;
{$ELSE}
begin
  Write(s);
  Flush(Output);
end;
{$ENDIF}

procedure GetTerminalSize;
{$IFDEF WINDOWS}
var csbi: CONSOLE_SCREEN_BUFFER_INFO;
begin
  TermRows := 24; TermCols := 80;
  if GetConsoleScreenBufferInfo(hOut, csbi) then begin
    TermRows := csbi.srWindow.Bottom - csbi.srWindow.Top + 1;
    TermCols := csbi.srWindow.Right  - csbi.srWindow.Left + 1;
  end;
{$ELSE}
var w: _winsize;
begin
  TermRows := 24; TermCols := 80;
  if ioctl(1, TIOCGWINSZ, w) = 0 then begin
    TermRows := Integer(w.ws_row);
    TermCols := Integer(w.ws_col);
  end;
{$ENDIF}
  if TermRows < 24 then TermRows := 24;
  if TermCols < 80 then TermCols := 80;
end;

{$IFNDEF WINDOWS}
procedure SigWinchHandler(sig: Integer); cdecl;
begin
  ResizePending := True;
end;
{$ENDIF}

procedure CheckResize;
{$IFDEF WINDOWS}
var prevR, prevC: Integer;
begin
  prevR := TermRows; prevC := TermCols;
  GetTerminalSize;
  if (TermRows <> prevR) or (TermCols <> prevC) then ResizePending := True;
end;
{$ELSE}
begin { SIGWINCH sets ResizePending asynchronously on Unix }
end;
{$ENDIF}

procedure TUI_Init;
{$IFDEF WINDOWS}
const
  ENABLE_VT = $0004; { ENABLE_VIRTUAL_TERMINAL_PROCESSING }
begin
  ResizePending := False;
  CachedSeqStatic := -1;
  CachedStatWidth := 0;
  CachedSessWidth      := -1;
  CachedRow3LSeq       := -1;
  CachedRow3LW         := -1;
  CachedActPlots       := -1;
  CachedActRW          := -1;
  CachedBodyInvSeq     := -1;
  CachedBodyQuestCount := -1;
  CachedBodyStaticSeq  := -1;
  CachedBodyLW         := -1;
  CachedBodyRW         := -1;
  CachedBodyTermRows   := -1;
  ToastMsg   := '';
  ToastTicks := 0;
  hIn  := GetStdHandle(STD_INPUT_HANDLE);
  hOut := GetStdHandle(STD_OUTPUT_HANDLE);
  GetTerminalSize;
  GetConsoleMode(hIn,  OldInMode);
  GetConsoleMode(hOut, OldOutMode);
  SetConsoleMode(hIn,  0);                        { raw: no echo, no line }
  SetConsoleMode(hOut, OldOutMode or ENABLE_VT);  { enable ANSI sequences }
{$ELSE}
var attr: TTermios;
begin
  ResizePending := False;
  CachedSeqStatic := -1;
  CachedStatWidth := 0;
  CachedSessWidth      := -1;
  CachedRow3LSeq       := -1;
  CachedRow3LW         := -1;
  CachedActPlots       := -1;
  CachedActRW          := -1;
  CachedBodyInvSeq     := -1;
  CachedBodyQuestCount := -1;
  CachedBodyStaticSeq  := -1;
  CachedBodyLW         := -1;
  CachedBodyRW         := -1;
  CachedBodyTermRows   := -1;
  ToastMsg   := '';
  ToastTicks := 0;
  GetTerminalSize;
  signal(SIGWINCH, @SigWinchHandler);
  tcgetattr(0, OrigTermios);
  attr := OrigTermios;
  attr.lflag := attr.lflag and not (ICANON or ECHO);
  attr.cc[5] := 0;  { VTIME = 0 }
  attr.cc[6] := 0;  { VMIN  = 0: non-blocking read }
  tcsetattr(0, TCSANOW, attr);
{$ENDIF}
  ConWrite(CURSOR_HIDE);
end;

procedure TUI_Shutdown;
begin
{$IFDEF WINDOWS}
  SetConsoleMode(hIn,  OldInMode);
  SetConsoleMode(hOut, OldOutMode);
{$ELSE}
  tcsetattr(0, TCSANOW, OrigTermios);
{$ENDIF}
  ConWrite(CURSOR_SHOW);
end;

procedure TUI_Clear;
begin
    ConWrite(ERASE + HOME);
    SetLength(PrevLines, 0);
    PrevWidth := 0;
    CachedSeqStatic := -1;
    ToastMsg   := '';
    ToastTicks := 0;
end;

function DispWidth(const s: string): Integer;
  { Returns display width in terminal cells.
    Skips ANSI CSI escape sequences (ESC '[' ... letter) so colour codes do not
    contribute to the measured width.  Handles 3-byte UTF-8 block glyphs (U+25xx). }
var i, w: Integer;
begin
  w := 0;
  i := 1;
  while i <= Length(s) do
    if (Ord(s[i]) = $1B) and (i+1 <= Length(s)) and (s[i+1] = '[') then begin
      { ANSI CSI sequence: ESC '[' <params> <final byte $40..$7E> — zero width }
      Inc(i, 2);
      while (i <= Length(s)) and (Ord(s[i]) < $40) do Inc(i); { skip params }
      if i <= Length(s) then Inc(i);  { skip final byte }
    end else if Ord(s[i]) < $80 then begin { ASCII (non-ESC) }
      Inc(w);
      Inc(i);
    end else if (Ord(s[i]) = $e2) and (i+2 <= Length(s)) then begin { 3-byte UTF-8: U+25xx }
      Inc(w);
      Inc(i, 3);
    end else begin { continuation byte or other multi-byte lead — skip }
      Inc(i);
    end;
  Result := w;
end;

function TruncateStr(const s: string; maxLen: Integer): string;
{ Return s truncated to at most maxLen display cells.
  ANSI CSI escape sequences are skipped (zero width) so colour codes do not
  consume the budget.  3-byte UTF-8 glyphs (U+25xx) count as 1 cell each. }
var
  i, w, byteEnd: Integer;
begin
  w := 0;
  byteEnd := 0;
  i := 1;
  while i <= Length(s) do begin
    if (Ord(s[i]) = $1B) and (i+1 <= Length(s)) and (s[i+1] = '[') then begin
      { ANSI CSI sequence — zero display width; include bytes verbatim }
      Inc(i, 2);
      while (i <= Length(s)) and (Ord(s[i]) < $40) do Inc(i);
      if i <= Length(s) then Inc(i);
      byteEnd := i - 1;  { include the full escape sequence up to here }
    end else if Ord(s[i]) < $80 then begin { ASCII → 1 cell }
      if w + 1 > maxLen then Break;
      Inc(w);
      byteEnd := i;
      Inc(i);
    end else if (Ord(s[i]) = $e2) and (i+2 <= Length(s)) then begin { 3-byte UTF-8 U+25xx → 1 cell }
      if w + 1 > maxLen then Break;
      Inc(w);
      byteEnd := i + 2;
      Inc(i, 3);
    end else begin { continuation byte or other multi-byte → skip }
      Inc(i);
    end;
  end;
  if w <= maxLen then Result := s
  else Result := Copy(s, 1, byteEnd);
end;

function PadStr(const s: string; len: Integer): string;
var w: Integer;
begin
  Result := s;
  w := DispWidth(s);
  if len > w then Result := Result + StringOfChar(' ', len - w);
end;

function RepStrUTF8(const s: string; n: Integer): string;
{ Return s repeated n times using Move — safe for multi-byte UTF-8 glyphs. }
var slen, i: Integer;
begin
  if n <= 0 then begin Result := ''; Exit; end;
  slen := Length(s);
  SetLength(Result, n * slen);
  for i := 0 to n - 1 do
    Move(s[1], Result[i * slen + 1], slen);
end;

function ProgressBarText(pos, maxVal: Int64; width: Integer): string;
var
   n, filled: Integer;
begin
   { 2 borders + n blocks = width; all glyphs are single-width (1 cell) }
   n := width - 2;
   if n < 1 then n := 1;
   if maxVal <= 0 then maxVal := 1;
   filled := (pos * n) div maxVal;
   { Build bar with two bulk-Move fills instead of n single-glyph concatenations }
   Result := BAR_LEFT + RepStrUTF8(BAR_FULL, filled) +
                        RepStrUTF8(BAR_EMPTY, n - filled) + BAR_RIGHT;
end;

procedure TUI_Draw(const GS: TGameState; const TaskDescription: string; Minimized: Boolean);
var
   RC: Integer;
   yL, yR: Integer;
   i, r: Integer;
   frame: string;
   width, lw, rw: Integer;
   barW: Integer;
   expPct, questPct, plotPct, encumPct: string;
   plotPos, questPos: string;
   invCount, spellCount, questCount: Integer;
   maxInv, maxQuest, maxSpells: Integer;
   bodyBottom, spellTop, spellIdx: Integer;
   nameFld: Integer;
   spellLine: string;
titleText: string;
    actText: string;
    actSubText: string;
    actNum: Integer;
   tmp: array of string;   { used for DrawLines ↔ PrevLines swap }
   dirty, hasLeft, hasRight: Boolean;
begin
   CheckResize;
   if ResizePending then begin
     ResizePending := False;
     {$IFNDEF WINDOWS}GetTerminalSize;{$ENDIF}
     ConWrite(SYNC_BEGIN + ERASE + HOME + SYNC_END);
     SetLength(PrevLines, 0);
     PrevWidth := 0;
   end;

   width := TermCols;
   RC    := width div 2 + 1;
   lw    := RC - 2;
   rw    := width - RC - 1;
   if rw < 10 then rw := 10;

   { DrawLines may be shorter than DrawLeft after a swap with an empty PrevLines
     (e.g. first frame after TUI_Clear); check both to keep them in sync. }
   if (Length(DrawLeft) <> TermRows) or (Length(DrawLines) <> TermRows) then begin
     SetLength(DrawLeft,    TermRows);
     SetLength(DrawRight,   TermRows);
     SetLength(DrawChanged, TermRows);
     SetLength(DrawLines,   TermRows);
   end;
   for r := 0 to TermRows-1 do begin
     DrawLeft[r]  := '';
     DrawRight[r] := '';
   end;

   { Session-static rows: rebuilt only when terminal width changes }
   if width <> CachedSessWidth then begin
     CachedSessWidth := width;
     if GS.TraitsTag <> 0 then begin
       if GS.SpellsHint <> '' then
         titleText := ' Progress Quest TUI 6.4.1 - Online - Realm: ' + GS.SpellsHint + ' '
       else
         titleText := ' Progress Quest TUI 6.4.1 - Online - Realm: Knoram ';
     end else
       titleText := ' Progress Quest TUI 6.4.1 - Offline ';
     CachedRow0 := INVERSE + PadStr(titleText, width) + NORMAL;
     if GS.TraitsTag <> 0 then begin
       if GS.SpellsHint <> '' then
         titleText := ' Progress Quest TUI 6.4.1 - Online - Realm: ' + GS.SpellsHint + ' - Minimal Mode'
       else
         titleText := ' Progress Quest TUI 6.4.1 - Online - Realm: Knoram - Minimal Mode';
     end else
       titleText := ' Progress Quest TUI 6.4.1 - Offline - Minimal Mode';
     CachedRow0Min := INVERSE + PadStr(titleText, width) + NORMAL;
     if GS.StatsHint <> '' then
       CachedRow2L := PadStr(COLOR_CYAN + TruncateStr(GS.CharName + ' - ' + GS.StatsHint, lw) + NORMAL, lw + 1)
     else
       CachedRow2L := PadStr(COLOR_CYAN + TruncateStr(GS.CharName, lw) + NORMAL, lw + 1);
     CachedFooterOnL    := PadStr(COLOR_YELLOW + 'Keys  [' + NORMAL + BOLD + 'Q' + NORMAL + COLOR_YELLOW + ']uit  [' +
                                  NORMAL + BOLD + 'S' + NORMAL + COLOR_YELLOW + ']ave  [' + NORMAL + BOLD + 'E' + NORMAL + COLOR_YELLOW + ']xport  [' +
                                  NORMAL + BOLD + 'B' + NORMAL + COLOR_YELLOW + ']rag  [' + NORMAL + BOLD + 'M' + NORMAL + COLOR_YELLOW + ']in', lw + 1);
     CachedFooterOffL   := PadStr(COLOR_YELLOW + 'Keys  [' + NORMAL + BOLD + 'Q' + NORMAL + COLOR_YELLOW + ']uit  [' +
                                  NORMAL + BOLD + 'S' + NORMAL + COLOR_YELLOW + ']ave  [' + NORMAL + BOLD + 'E' + NORMAL + COLOR_YELLOW + ']xport  [' +
                                  NORMAL + BOLD + 'M' + NORMAL + COLOR_YELLOW + ']in', lw + 1);
     CachedFooterOnMinL := PadStr(COLOR_YELLOW + 'Keys  [' + NORMAL + BOLD + 'Q' + NORMAL + COLOR_YELLOW + ']uit  [' +
                                  NORMAL + BOLD + 'S' + NORMAL + COLOR_YELLOW + ']ave  [' + NORMAL + BOLD + 'E' + NORMAL + COLOR_YELLOW + ']xport  [' +
                                  NORMAL + BOLD + 'B' + NORMAL + COLOR_YELLOW + ']rag  [' + NORMAL + BOLD + 'M' + NORMAL + COLOR_YELLOW + ']ax', lw + 1);
     CachedFooterOffMinL := PadStr(COLOR_YELLOW + 'Keys  [' + NORMAL + BOLD + 'Q' + NORMAL + COLOR_YELLOW + ']uit  [' +
                                   NORMAL + BOLD + 'S' + NORMAL + COLOR_YELLOW + ']ave  [' + NORMAL + BOLD + 'E' + NORMAL + COLOR_YELLOW + ']xport  [' +
                                   NORMAL + BOLD + 'M' + NORMAL + COLOR_YELLOW + ']ax', lw + 1);
   end;

   { Row 1: Title bar }
   if Minimized then
     DrawLeft[0] := CachedRow0Min
   else
     DrawLeft[0] := CachedRow0;

   { Row 2: blank separator }

   { Row 3: Name (L) + EXP bar (R) }
   DrawLeft[2] := CachedRow2L;
   expPct := ProgressBarText(GS.ExpPos, GS.ExpMax, rw - 25);
   DrawRight[2] := PadStr(TruncateStr(COLOR_YELLOW + Format('EXP %s %d/%d', [expPct, Integer(GS.ExpPos), Integer(GS.ExpMax)]) + NORMAL, rw), rw);

   { Row 4: Race/Class/Level (L) — cached on StaticSeq+lw; ACT (R) — cached on plot count+rw }
   if (GS.StaticSeq <> CachedRow3LSeq) or (lw <> CachedRow3LW) then begin
     CachedRow3L   := PadStr(COLOR_CYAN + TruncateStr(GS.Race + ' ' + GS.Klass + ' Level ' + NORMAL + IntToStr(GS.Level) + NORMAL, lw) + NORMAL, lw + 1);
     CachedRow3LSeq := GS.StaticSeq;
     CachedRow3LW   := lw;
   end;
   DrawLeft[3] := CachedRow3L;
   if (Length(GS.Plots) <> CachedActPlots) or (rw <> CachedActRW) then begin
     CachedActPlots := Length(GS.Plots);
     CachedActRW    := rw;
     if Length(GS.Plots) > 0 then begin
       actText    := GS.Plots[Length(GS.Plots)-1].Text;
       actSubText := GS.Plots[Length(GS.Plots)-1].SubText;
       actNum     := RomanToInt(Copy(actText, 5, Length(actText)));
       if actSubText <> '' then
         CachedActR := PadStr(TruncateStr(COLOR_YELLOW + 'Currently in ' + NORMAL + actText + ' (' + IntToStr(actNum) + ')' + ' - ' + actSubText, rw), rw)
       else
         CachedActR := PadStr(TruncateStr(COLOR_YELLOW + 'Currently in ' + NORMAL + actText + ' (' + IntToStr(actNum) + ')', rw), rw);
     end else
       CachedActR := '';
   end;
   DrawRight[3] := CachedActR;

   if Minimized then begin
     barW := lw - 20;
     if barW < 8 then barW := 8;
     encumPct := ProgressBarText(GS.EncumPos, GS.EncumMax, barW);
     DrawLeft[5] := PadStr(TruncateStr(COLOR_YELLOW + Format('Encum %s %d/%d', [encumPct, Integer(GS.EncumPos), Integer(GS.EncumMax)]) + NORMAL, lw), lw);
     barW := rw - 24;
     if barW < 8 then barW := 8;
     questPct := ProgressBarText(GS.QuestPos, GS.QuestMax, barW);
     questPos := Format('%d/%d', [Integer(GS.QuestPos), Integer(GS.QuestMax)]);
     DrawRight[6] := PadStr(TruncateStr(COLOR_YELLOW + Format('Quest %s %s', [questPct, questPos]) + NORMAL, rw), rw);
     if GS.TraitsTag <> 0 then
       DrawLeft[6] := CachedFooterOnMinL
     else
       DrawLeft[6] := CachedFooterOffMinL;
     plotPct := ProgressBarText(GS.PlotPos, GS.PlotMax, barW);
     plotPos := Format('%d/%d', [Integer(GS.PlotPos), Integer(GS.PlotMax)]);
     DrawRight[5] := PadStr(TruncateStr(COLOR_YELLOW + Format('Plot  %s %s', [plotPct, plotPos]) + NORMAL, rw), rw);
   end else begin

   { Row 5: blank separator }

   { Row 6: Task description }
   DrawLeft[5] := PadStr(TruncateStr(COLOR_GREEN + BOLD + TaskDescription + '...' + NORMAL, width), width);

   { Row 7: Task progress bar }
   if GS.TaskMax > 0 then
     DrawLeft[6] := ProgressBarText(GS.TaskPos, GS.TaskMax, width);

   { Row 8: blank separator }
   DrawLeft[7] := PadStr('', width);

   { Two-column body }
   yL := 9;
   yR := 9;

   { LEFT: Stats  /  RIGHT: Equipment — rebuilt only when StaticSeq or width changes }
   if (GS.StaticSeq = CachedSeqStatic) and (width = CachedStatWidth) then begin
     for i := 0 to STAT_COUNT do  DrawLeft[8 + i]  := CachedStatLeft[i];
     for i := 0 to EQUIP_SLOTS do DrawRight[8 + i] := CachedStatRight[i];
     yL := 9 + 1 + STAT_COUNT;
     yR := 9 + 1 + EQUIP_SLOTS;
   end else begin
     DrawLeft[yL-1] := PadStr(COLOR_CYAN + 'Stats:' + NORMAL, lw + 1);
     Inc(yL);
     for i := 0 to STAT_COUNT-1 do begin
       DrawLeft[yL-1] := PadStr(Format(' %-8s %5d', [StatNames[i], GS.Stats[i]]), lw + 1);
       Inc(yL);
     end;
     DrawRight[yR-1] := PadStr(COLOR_CYAN + 'Equipment:' + NORMAL, rw);
     Inc(yR);
     for i := 0 to EQUIP_SLOTS-1 do begin
       if GS.Equips[i] <> '' then
         DrawRight[yR-1] := PadStr(Format(' %-11s %s', [EquipSlots[i], TruncateStr(GS.Equips[i], rw-14)]), rw)
       else
         DrawRight[yR-1] := PadStr(Format(' %-11s (empty)', [EquipSlots[i]]), rw);
       Inc(yR);
     end;
     for i := 0 to STAT_COUNT do  CachedStatLeft[i]  := DrawLeft[8 + i];
     for i := 0 to EQUIP_SLOTS do CachedStatRight[i] := DrawRight[8 + i];
     CachedSeqStatic := GS.StaticSeq;
     CachedStatWidth := width;
   end;

   bodyBottom := TermRows - 4;

   { Encumbrance (L) + Plot bar (R) }
   barW := lw - 20;
   if barW < 8 then barW := 8;
   encumPct := ProgressBarText(GS.EncumPos, GS.EncumMax, barW);
   DrawLeft[TermRows-3] := PadStr(TruncateStr(COLOR_YELLOW + Format('Encum %s %d/%d', [encumPct, Integer(GS.EncumPos), Integer(GS.EncumMax)]) + NORMAL, lw), lw);

   barW := rw - 24;
   if barW < 8 then barW := 8;
   plotPct  := ProgressBarText(GS.PlotPos,  GS.PlotMax,  barW);
   plotPos := Format('%d/%d', [Integer(GS.PlotPos), Integer(GS.PlotMax)]);
   DrawRight[TermRows-3] := PadStr(TruncateStr(COLOR_YELLOW + Format('Plot  %s %s', [plotPct, plotPos]) + NORMAL, rw), rw);

   { Footer (L) + Quest bar (R) }
   if GS.TraitsTag <> 0 then
     DrawLeft[TermRows-2] := CachedFooterOnL
   else
     DrawLeft[TermRows-2] := CachedFooterOffL;
   questPct := ProgressBarText(GS.QuestPos, GS.QuestMax, barW);
   questPos := Format('%d/%d', [Integer(GS.QuestPos), Integer(GS.QuestMax)]);
   DrawRight[TermRows-2] := PadStr(TruncateStr(COLOR_YELLOW + Format('Quest %s %s', [questPct, questPos]) + NORMAL, rw), rw);

   { Inventory + Quests + Spells — rebuilt only when content or geometry changes }
   spellTop := (yL + bodyBottom + 1) div 2;
   if spellTop < yL + 2 then spellTop := yL + 2;
   if spellTop > bodyBottom then spellTop := bodyBottom;
   if yL > spellTop - 1 then yL := spellTop - 1;

   if (GS.InventorySeq  <> CachedBodyInvSeq)     or
      (Length(GS.Quests) <> CachedBodyQuestCount) or
      (GS.StaticSeq      <> CachedBodyStaticSeq)  or
      (lw                <> CachedBodyLW)          or
      (rw                <> CachedBodyRW)          or
      (TermRows          <> CachedBodyTermRows)    then begin

     CachedBodyInvSeq     := GS.InventorySeq;
     CachedBodyQuestCount := Length(GS.Quests);
     CachedBodyStaticSeq  := GS.StaticSeq;
     CachedBodyLW         := lw;
     CachedBodyRW         := rw;
     CachedBodyTermRows   := TermRows;

     { (Re)size cache arrays to cover the full terminal height }
     if Length(CachedBodyLeft)  <> TermRows then SetLength(CachedBodyLeft,  TermRows);
     if Length(CachedBodyRight) <> TermRows then SetLength(CachedBodyRight, TermRows);
     for i := 0 to TermRows - 1 do begin
       CachedBodyLeft[i]  := '';
       CachedBodyRight[i] := '';
     end;

     { Inventory }
     invCount := Length(GS.Inventory);
     maxInv   := (spellTop - 1) - yL;
     if (maxInv > 0) and (invCount > 0) then begin
       CachedBodyLeft[yL-1] := PadStr(COLOR_CYAN + 'Inventory:' + NORMAL, lw + 1);
       Inc(yL);
       if invCount <= maxInv then r := invCount else r := maxInv - 1;
       nameFld := 0;
       for i := 0 to r - 1 do
         if Length(GS.Inventory[i].Key) > nameFld then
           nameFld := Length(GS.Inventory[i].Key);
       Inc(nameFld, 3);
       if nameFld > lw - 7 then nameFld := lw - 7;
       if nameFld < 10 then nameFld := 10;
       if invCount <= maxInv then begin
         for i := 0 to invCount-1 do begin
           CachedBodyLeft[yL-1] := PadStr(TruncateStr(' ' + PadStr(TruncateStr(GS.Inventory[i].Key, nameFld), nameFld) + 'x' + GS.Inventory[i].Val, lw + 1), lw + 1);
           Inc(yL);
         end;
       end else begin
         for i := 0 to maxInv-2 do begin
           CachedBodyLeft[yL-1] := PadStr(TruncateStr(' ' + PadStr(TruncateStr(GS.Inventory[i].Key, nameFld), nameFld) + 'x' + GS.Inventory[i].Val, lw + 1), lw + 1);
           Inc(yL);
         end;
         CachedBodyLeft[yL-1] := PadStr(Format(' ... %d more', [invCount - (maxInv - 1)]), lw + 1);
       end;
     end;

     { Quests }
     if yR > bodyBottom then yR := bodyBottom;
     questCount := Length(GS.Quests);
     maxQuest := bodyBottom - yR;
     if questCount < maxQuest then maxQuest := questCount;
     if maxQuest > 0 then begin
       CachedBodyRight[yR-1] := PadStr(COLOR_CYAN + 'Quests:' + NORMAL, rw);
       Inc(yR);
       for i := Max(0, questCount-maxQuest) to questCount-1 do begin
         if GS.Quests[i].Done then
           CachedBodyRight[yR-1] := ' ' + COLOR_GREEN + '[x]' + NORMAL
         else if i = questCount-1 then
           CachedBodyRight[yR-1] := ' ' + COLOR_YELLOW + '[-]' + NORMAL
         else
           CachedBodyRight[yR-1] := ' [ ]';
         CachedBodyRight[yR-1] := CachedBodyRight[yR-1] + PadStr(' ' + TruncateStr(GS.Quests[i].Text, rw - 5), rw - 4);
         Inc(yR);
       end;
     end;

     { Spells }
     spellCount := Length(GS.Spells);
     maxSpells  := bodyBottom - spellTop;
     if maxSpells < 1 then maxSpells := 1;
     for i := 0 to maxSpells do begin
       if i = 0 then begin
         if spellCount > 0 then
           CachedBodyLeft[spellTop + i - 1] := PadStr(COLOR_CYAN + 'Spells: ' + NORMAL, lw + 1)
         else
           CachedBodyLeft[spellTop + i - 1] := PadStr('', lw + 1);
       end else begin
         spellIdx := spellCount - maxSpells + i - 1;
         if spellIdx >= 0 then begin
           spellLine := GS.Spells[spellIdx].Key + Format(' %s (%d)', [GS.Spells[spellIdx].Val, RomanToInt(GS.Spells[spellIdx].Val)]);
           CachedBodyLeft[spellTop + i - 1] := PadStr(' ' + TruncateStr(spellLine, lw - 1), lw + 1);
         end else
           CachedBodyLeft[spellTop + i - 1] := PadStr('', lw + 1);
       end;
     end;
   end;

   { Copy body cache into the current frame }
   for i := 0 to TermRows - 1 do begin
     if CachedBodyLeft[i]  <> '' then DrawLeft[i]  := CachedBodyLeft[i];
     if CachedBodyRight[i] <> '' then DrawRight[i] := CachedBodyRight[i];
   end;
   end; { not Minimized }

   { Toast notification — bottom row, auto-expires after ToastTicks frames }
   if ToastTicks > 0 then begin
     DrawLeft[TermRows-1] := COLOR_CYAN + TruncateStr(ToastMsg, width) + NORMAL;
     Dec(ToastTicks);
     if ToastTicks = 0 then ToastMsg := '';
   end;

   { Combine columns and diff against previous frame }
   hasLeft := False;
   hasRight := False;
   for r := 0 to TermRows-1 do begin
     hasLeft  := hasLeft  or (DrawLeft[r]  <> '');
     hasRight := hasRight or (DrawRight[r] <> '');
     DrawLines[r] := DrawLeft[r] + #9 + DrawRight[r];
   end;

   dirty := False;
   if (Length(PrevLines) <> TermRows) or (PrevWidth <> width) or not (hasLeft and hasRight) then begin
     for r := 0 to TermRows-1 do DrawChanged[r] := True;
   end else begin
     for r := 0 to TermRows-1 do
       DrawChanged[r] := (PrevLines[r] <> DrawLines[r]);
   end;

   for r := 0 to TermRows-1 do
     if DrawChanged[r] then dirty := True;

   if dirty then begin
     frame := '';
     for r := 0 to TermRows-1 do
       if DrawChanged[r] then begin
         if (r = 0) or (not Minimized and ((r = 5) or (r = 6))) then
           frame := frame + CSI + Format('%d;1H', [r+1]) +
                                DrawLeft[r] +
                                CSI + Format('%d;%dH', [r+1, RC]) + DrawRight[r]
         else if r = TermRows - 1 then begin
           { Toast row: full-width, with explicit clear when empty }
           if DrawLeft[r] <> '' then
             frame := frame + CSI + Format('%d;1H', [r+1]) + DrawLeft[r] + CSI + '0K'
           else
             frame := frame + CSI + Format('%d;1H', [r+1]) + CSI + '2K'
         end else
           frame := frame + CSI + Format('%d;1H', [r+1]) +
                                DrawLeft[r] + CSI + '0K' +
                                CSI + Format('%d;%dH', [r+1, RC]) + DrawRight[r] + CSI + '0K';
       end;
     if frame <> '' then
       ConWrite(SYNC_BEGIN + frame + SYNC_END);
   end;

   { Swap DrawLines ↔ PrevLines (O(1) reference swap, no allocation) }
   tmp       := PrevLines;
   PrevLines := DrawLines;
   DrawLines := tmp;
   PrevWidth := width;
end;

procedure TUI_Prompt(const Prompt: string; var Input: string);
{$IFDEF WINDOWS}
begin
  SetConsoleMode(hIn, ENABLE_ECHO_INPUT or ENABLE_LINE_INPUT or ENABLE_PROCESSED_INPUT);
  ConWrite(CURSOR_SHOW + Prompt);
  ReadLn(Input);
  SetConsoleMode(hIn, 0);
  ConWrite(CURSOR_HIDE);
end;
{$ELSE}
var
  ch:   AnsiChar;
  buf:  string;
  attr: TTermios;
  n:    Integer;
begin
  { Switch to blocking single-char mode for text input }
  tcgetattr(0, attr);
  attr.cc[5] := 0;  { VTIME = 0 }
  attr.cc[6] := 1;  { VMIN  = 1: block until a char arrives }
  tcsetattr(0, TCSANOW, attr);

  Write(CURSOR_SHOW);
  Write(Prompt);
  Flush(Output);
  buf := '';
  while True do begin
    n := read(0, ch, 1);
    if n <= 0 then Continue;
    case Ord(ch) of
      8, 127: begin
        if Length(buf) > 0 then begin
          Delete(buf, Length(buf), 1);
          Write(#8 + ' ' + #8);
          Flush(Output);
        end;
      end;
      13, 10: begin
        Write(#13#10);
        Write(CURSOR_HIDE);
        Break;
      end;
      3: begin
        Write(#13#10);
        Write(CURSOR_HIDE);
        buf := '';
        Break;
      end;
    else
      if (ch >= #32) and (ch <= #126) then begin
        buf := buf + ch;
        Write(ch);
        Flush(Output);
      end;
    end;
  end;
  Input := buf;

  { Restore non-blocking mode }
  tcgetattr(0, attr);
  attr.cc[5] := 0;  { VTIME = 0 }
  attr.cc[6] := 0;  { VMIN  = 0 }
  tcsetattr(0, TCSANOW, attr);
end;
{$ENDIF}

function TUI_GetKey: Integer;
{$IFDEF WINDOWS}
var
  ir: INPUT_RECORD;
  nr: DWORD;
begin
  Result := -1;
  if PeekConsoleInput(hIn, ir, 1, nr) and (nr > 0) then begin
    ReadConsoleInput(hIn, ir, 1, nr);
    if (ir.EventType = KEY_EVENT) and ir.Event.KeyEvent.bKeyDown then begin
      if ir.Event.KeyEvent.AsciiChar <> #0 then
        Result := Ord(ir.Event.KeyEvent.AsciiChar)
      else case ir.Event.KeyEvent.wVirtualKeyCode of
        $26: Result := KEY_ARROW_UP;    { VK_UP   }
        $28: Result := KEY_ARROW_DOWN;  { VK_DOWN }
      end;
    end;
  end;
end;
{$ELSE}
var
  ch: AnsiChar;
  n:  Integer;
begin
  n := read(0, ch, 1);
  if n <= 0 then
    Result := -1
  else
    Result := Ord(ch);
end;
{$ENDIF}

function TUI_WaitKey: Integer;
begin
  repeat
    Result := TUI_GetKey;
    {$IFDEF WINDOWS}if Result < 0 then Sleep(10);{$ENDIF}
  until Result >= 0;
end;

procedure TUI_Popup(const msg: string);
{ Draw a centred modal popup containing msg, wait for any key, then force a
  full redraw on the next TUI_Draw call.

  Box layout (pw = inner + 4):
    ┌──────────────────────┐
    │ message text here    │
    │                      │
    │    [ Press Enter ]   │
    └──────────────────────┘                                                   }
const
  CH_H  = '─';    { U+2500 }
  CH_V  = '│';    { U+2502 }
  CH_TL = '┌';    { U+250C }
  CH_TR = '┐';    { U+2510 }
  CH_BL = '└';    { U+2514 }
  CH_BR = '┘';    { U+2518 }
  BTN   = '[ Press Enter ]';
  BTN_W = 15;     { display-cell width of BTN }
var
  inner, pw, ph, pr, pc: Integer;
  lineArr: array[0..19] of string;
  nlines, i, sp, pad: Integer;
  s, frame, horzLine, btnRow: string;
begin
  { ── 1. Inner content width ── }
  inner := DispWidth(msg);
  if inner > TermCols - 4 then inner := TermCols - 4;
  if inner < BTN_W + 2 then inner := BTN_W + 2;  { ensure button fits with margin }
  pw := inner + 4;  { border + space + inner + space + border }

  { ── 2. Word-wrap the message ── }
  nlines := 0;
  s := msg;
  while (s <> '') and (nlines < 20) do begin
    if DispWidth(s) <= inner then begin
      lineArr[nlines] := s;
      Inc(nlines);
      s := '';
    end else begin
      { scan back from position inner for a word break }
      sp := inner;
      while (sp > 1) and (s[sp] <> ' ') do Dec(sp);
      if sp <= 1 then begin
        { no space found — hard break }
        lineArr[nlines] := TruncateStr(s, inner);
        Inc(nlines);
        s := Copy(s, inner + 1, MaxInt);
      end else begin
        lineArr[nlines] := TruncateStr(Copy(s, 1, sp - 1), inner);
        Inc(nlines);
        s := TrimLeft(Copy(s, sp + 1, MaxInt));
      end;
    end;
  end;
  if nlines = 0 then begin lineArr[0] := ''; nlines := 1; end;

  { ── 3. Popup geometry ── }
  ph := nlines + 4;  { top border + lines + blank + button + bottom border }
  pr := (TermRows - ph) div 2 + 1;
  if pr < 1 then pr := 1;
  pc := (TermCols - pw) div 2 + 1;
  if pc < 1 then pc := 1;

  { ── 4. Build repeated horizontal bar (pw-2 glyphs, each 1 display cell) ── }
  horzLine := '';
  for i := 1 to pw - 2 do horzLine += CH_H;

  { ── 5. Compose the popup frame ── }
  frame := SYNC_BEGIN;

  { Top border: ┌───...───┐ }
  frame += CSI + Format('%d;%dH', [pr, pc]);
  frame += CH_TL + horzLine + CH_TR;

  { Message lines: │ text padded to inner │ }
  for i := 0 to nlines - 1 do begin
    frame += CSI + Format('%d;%dH', [pr + 1 + i, pc]);
    frame += CH_V + ' ' + PadStr(lineArr[i], inner) + ' ' + CH_V;
  end;

  { Blank separator: │         │ }
  frame += CSI + Format('%d;%dH', [pr + 1 + nlines, pc]);
  frame += CH_V + StringOfChar(' ', pw - 2) + CH_V;

  { Button row — BTN centred in the inner area, highlighted }
  pad := (inner - BTN_W) div 2;
  btnRow := CH_V + ' '
          + StringOfChar(' ', pad)
          + INVERSE + BTN + NORMAL
          + StringOfChar(' ', inner - pad - BTN_W)
          + ' ' + CH_V;
  frame += CSI + Format('%d;%dH', [pr + 2 + nlines, pc]);
  frame += btnRow;

  { Bottom border: └───...───┘ }
  frame += CSI + Format('%d;%dH', [pr + 3 + nlines, pc]);
  frame += CH_BL + horzLine + CH_BR;

  frame += SYNC_END;
  ConWrite(frame);

  { ── 6. Block until any key is pressed ── }
  TUI_WaitKey;

  { ── 7. Force a full screen redraw on the next TUI_Draw call ── }
  SetLength(PrevLines, 0);
  PrevWidth := 0;
end;

procedure TUI_Toast(const msg: string);
{ Display msg on the bottom row of the terminal for ~2 seconds (10 draw frames
  at the normal 200 ms draw rate).  Safe to call at any time; the message is
  written to DrawLeft[TermRows-1] in the next TUI_Draw call and cleared
  automatically when the counter reaches zero. }
begin
  ToastMsg   := msg;
  ToastTicks := 10;   { 10 × ~200 ms ≈ 2 s }
end;

end.
