unit GameState;
{$mode objfpc}{$H+}
interface

const
  EQUIP_SLOTS = 11;
  STAT_STR   = 0;
  STAT_CON   = 1;
  STAT_DEX   = 2;
  STAT_INT   = 3;
  STAT_WIS   = 4;
  STAT_CHA   = 5;
  STAT_HPMAX = 6;
  STAT_MPMAX = 7;
  STAT_COUNT = 8;

type
  TKeyVal = record
    Key, Val: string;
  end;
  TKeyValArr = array of TKeyVal;

  TListItem = record
    Text:    string;
    SubText: string;  { for 2-column lists }
    Done:    Boolean; { iImage: 1=done/checked, 0=current }
  end;
  TListItems = array of TListItem;

  TGameState = record
    { Traits }
    CharName: string;
    Race:     string;
    Klass:    string;
    Level:    Integer;
    { Stats [STAT_STR..STAT_MPMAX] }
    Stats:    array[0..STAT_COUNT-1] of Int64;
    { Equipment [0..EQUIP_SLOTS-1] }
    Equips:   array[0..EQUIP_SLOTS-1] of string;
    { Spells: Key=name, Val=roman numeral level }
    Spells:   TKeyValArr;
    { Inventory: Key=item name, Val=count as string }
    Inventory: TKeyValArr;
    { Quests and Plots }
    Quests:   TListItems;
    Plots:    TListItems;
    { Progress bars }
    ExpPos,   ExpMax:   Int64;
    QuestPos, QuestMax: Int64;
    PlotPos,  PlotMax:  Int64;
    EncumPos, EncumMax: Int64;
    TaskPos,  TaskMax:  Int64;
    { Current task/quest labels }
    TaskText:  string; { 'action|monster|level|item' }
    TaskItem:  string; { item dropped by current kill task, '' otherwise }
    QuestText: string; { monster entry for quest target }
    { Action queue (fQueue) }
    Queue:    array of string;
    { GameStyle tag (always 3 = single player) }
    GameStyle: Integer;
    { Label8.Tag for multiplayer flags (0 in offline mode) }
    Label8Tag: Integer;
    { Best equip slot index (Equips.Tag) }
    BestEquip: Integer;
    { Quest monster tag (fQuest.Tag = index into monsters array) }
    QuestMonTag: Integer;
    { Round-trip fields: present in Delphi saves; not used by FPC gameplay.
      Preserved so a save loaded and re-saved by the FPC port stays fully
      compatible with the original Windows client. }
    TraitsTag:     Integer;  { Brag() passkey (0 = offline character) }
    TraitsHint:    string;   { passkey as decimal string (mirrors TraitsTag) }
    StatsHint:     string;   { motto shown on progressquest.com leaderboard }
    SpellsHint:    string;   { realm/hostname }
    EquipsHint:    string;   { host address URL; empty = default server }
    InventoryHint: string;   { login/username }
    QuestsHint:    string;   { unused in vanilla; round-tripped for safety }
    PlotsHint:     string;   { password }
    ExpBarHint:    string;   { e.g. "2832901 XP needed for next level" }
    QuestBarHint:  string;   { e.g. "25% complete" }
    PlotBarHint:   string;   { e.g. "5 days remaining" }
    EncumBarHint:  string;   { e.g. "7618/8139 cubits" }
    TaskBarHint:   string;   { task progress tooltip }
    GuildHint:     string;   { guild name — Label1.Hint; set via Ctrl+G in Delphi }
    { Runtime-only: bumped by GameLogic when stats/equipment change; used by TUI cache }
    StaticSeq: LongInt;
  end;

procedure InitNewGame(var GS: TGameState);
function  GS_GetInvI(const GS: TGameState; const Key: string): Integer;
procedure GS_PutInv(var GS: TGameState; const Key, Val: string);
procedure GS_AddInv(var GS: TGameState; const Key: string; Delta: Integer);
function  GS_GetInvVal(const GS: TGameState; const Key: string): string;
function  GS_SumInv(const GS: TGameState): Integer;
procedure GS_PutEquip(var GS: TGameState; Idx: Integer; const Val: string);
function  GS_GetSpellI(const GS: TGameState; const Key: string): Integer;
procedure GS_AddSpellR(var GS: TGameState; const Key: string; Delta: Integer);

implementation

uses SysUtils, GameData, GameLogic;

procedure InitNewGame(var GS: TGameState);
var i: Integer;
begin
  GS.CharName   := '';
  GS.Race       := '';
  GS.Klass      := '';
  GS.Level      := 1;
  for i := 0 to STAT_COUNT-1 do GS.Stats[i] := 0;
  for i := 0 to EQUIP_SLOTS-1 do GS.Equips[i] := '';
  SetLength(GS.Spells, 0);
  SetLength(GS.Inventory, 0);
  SetLength(GS.Quests, 0);
  SetLength(GS.Plots, 0);
  GS.ExpPos := 0;   GS.ExpMax := 0;
  GS.QuestPos := 0; GS.QuestMax := 0;
  GS.PlotPos := 0;  GS.PlotMax := 0;
  GS.EncumPos := 0; GS.EncumMax := 10;
  GS.TaskPos := 0;  GS.TaskMax := 0;
  GS.TaskText   := '';
  GS.TaskItem   := '';
  GS.QuestText  := '';
  SetLength(GS.Queue, 0);
  GS.GameStyle  := 3;
  GS.Label8Tag  := 0;
  GS.BestEquip  := 0;
  GS.QuestMonTag   := 0;
  GS.TraitsTag     := 0;
  GS.TraitsHint    := '';
  GS.StatsHint     := '';
  GS.SpellsHint    := '';
  GS.EquipsHint    := '';
  GS.InventoryHint := '';
  GS.QuestsHint    := '';
  GS.PlotsHint     := '';
  GS.ExpBarHint    := '';
  GS.QuestBarHint  := '';
  GS.PlotBarHint   := '';
  GS.EncumBarHint  := '';
  GS.TaskBarHint   := '';
  GS.GuildHint     := '';
  GS.StaticSeq     := 0;
end;

function GS_InvIdx(const GS: TGameState; const Key: string): Integer;
var i: Integer;
begin
  for i := 0 to High(GS.Inventory) do
    if GS.Inventory[i].Key = Key then begin Result := i; Exit; end;
  Result := -1;
end;

function GS_GetInvVal(const GS: TGameState; const Key: string): string;
var i: Integer;
begin
  i := GS_InvIdx(GS, Key);
  if i < 0 then Result := '' else Result := GS.Inventory[i].Val;
end;

function GS_GetInvI(const GS: TGameState; const Key: string): Integer;
begin
  Result := StrToIntDef(GS_GetInvVal(GS, Key), 0);
end;

procedure GS_PutInv(var GS: TGameState; const Key, Val: string);
var i, n: Integer;
begin
  i := GS_InvIdx(GS, Key);
  if i < 0 then begin
    n := Length(GS.Inventory);
    SetLength(GS.Inventory, n+1);
    GS.Inventory[n].Key := Key;
    GS.Inventory[n].Val := Val;
  end else
    GS.Inventory[i].Val := Val;
end;

procedure GS_AddInv(var GS: TGameState; const Key: string; Delta: Integer);
begin
  GS_PutInv(GS, Key, IntToStr(GS_GetInvI(GS, Key) + Delta));
end;

function GS_SumInv(const GS: TGameState): Integer;
var i: Integer;
begin
  Result := 0;
  for i := 0 to High(GS.Inventory) do
    Inc(Result, StrToIntDef(GS.Inventory[i].Val, 0));
end;

procedure GS_PutEquip(var GS: TGameState; Idx: Integer; const Val: string);
begin
  if (Idx >= 0) and (Idx < EQUIP_SLOTS) then
    GS.Equips[Idx] := Val;
end;

function GS_SpellIdx(const GS: TGameState; const Key: string): Integer;
var i: Integer;
begin
  for i := 0 to High(GS.Spells) do
    if GS.Spells[i].Key = Key then begin Result := i; Exit; end;
  Result := -1;
end;

function GS_GetSpellI(const GS: TGameState; const Key: string): Integer;
var i: Integer;
begin
  i := GS_SpellIdx(GS, Key);
  if i < 0 then Result := 0
  else Result := RomanToInt(GS.Spells[i].Val);
end;

procedure GS_AddSpellR(var GS: TGameState; const Key: string; Delta: Integer);
var i, n: Integer;
begin
  i := GS_SpellIdx(GS, Key);
  if i < 0 then begin
    n := Length(GS.Spells);
    SetLength(GS.Spells, n+1);
    GS.Spells[n].Key := Key;
    GS.Spells[n].Val := IntToRoman(Delta);
  end else
    GS.Spells[i].Val := IntToRoman(RomanToInt(GS.Spells[i].Val) + Delta);
end;

end.
