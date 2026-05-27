unit GameLogic;
{$mode objfpc}{$H+}
interface

uses GameState, GameData;

function  LevelUpTime(level: Integer): Int64;  { seconds }
procedure LevelUp(var GS: TGameState);
procedure Dequeue(var GS: TGameState);
procedure CompleteQuest(var GS: TGameState);
procedure CompleteAct(var GS: TGameState);
procedure WinEquip(var GS: TGameState);
procedure WinSpell(var GS: TGameState);
procedure WinStat(var GS: TGameState);
procedure WinItem(var GS: TGameState);
function  MonsterTask(var GS: TGameState; var level: Integer): string;
function  GenerateName: string;
function  GetActName(n: Integer): string;
function  IntToRoman(n: Integer): string;
function  RomanToInt(n: string): Integer;
function  EquipPrice(const GS: TGameState): Integer;
procedure StartTimer(var GS: TGameState);
procedure TickGame(var GS: TGameState; elapsed: Int64);

implementation

uses SysUtils, Math;

procedure UpdateEncum(var GS: TGameState); forward;

{ ---- Roman numeral helpers ---- }

function UnRome(var s: string; dn: Integer; var n: Integer; const ds: string): Boolean;
begin
  Result := Copy(s, 1, Length(ds)) = ds;
  if Result then begin Delete(s, 1, Length(ds)); Inc(n, dn); end;
end;

function RomanToInt(n: string): Integer;
begin
  Result := 0;
  while UnRome(n, 10000, Result, 'T') do ;
  UnRome(n, 9000,  Result, 'MT'); UnRome(n, 5000, Result, 'A');
  UnRome(n, 4000,  Result, 'MA');
  while UnRome(n, 1000, Result, 'M') do ;
  UnRome(n, 900, Result, 'CM'); UnRome(n, 500, Result, 'D');
  UnRome(n, 400, Result, 'CD');
  while UnRome(n, 100, Result, 'C') do ;
  UnRome(n, 90, Result, 'XC'); UnRome(n, 50, Result, 'L');
  UnRome(n, 40, Result, 'XL');
  while UnRome(n, 10, Result, 'X') do ;
  UnRome(n, 9, Result, 'IX'); UnRome(n, 5, Result, 'V');
  UnRome(n, 4, Result, 'IV');
  while UnRome(n, 1, Result, 'I') do ;
end;

function RomeAdd(var n: Integer; dn: Integer; var s: string; const ds: string): Boolean;
begin
  Result := n >= dn;
  if Result then begin Dec(n, dn); s := s + ds; end;
end;

function IntToRoman(n: Integer): string;
begin
  Result := '';
  while RomeAdd(n, 10000, Result, 'T') do ;
  RomeAdd(n, 9000, Result, 'MT'); RomeAdd(n, 5000, Result, 'A');
  RomeAdd(n, 4000, Result, 'MA');
  while RomeAdd(n, 1000, Result, 'M') do ;
  RomeAdd(n, 900, Result, 'CM'); RomeAdd(n, 500, Result, 'D');
  RomeAdd(n, 400, Result, 'CD');
  while RomeAdd(n, 100, Result, 'C') do ;
  RomeAdd(n, 90, Result, 'XC'); RomeAdd(n, 50, Result, 'L');
  RomeAdd(n, 40, Result, 'XL');
  while RomeAdd(n, 10, Result, 'X') do ;
  RomeAdd(n, 9, Result, 'IX'); RomeAdd(n, 5, Result, 'V');
  RomeAdd(n, 4, Result, 'IV');
  while RomeAdd(n, 1, Result, 'I') do ;
end;

function GetActName(n: Integer): string;
var
  pattern, adjIdx, noun1Idx, noun2Idx: Integer;
  adj, noun1, noun2: string;
begin
  if n = 0 then begin
    Result := 'A New Start';
    Exit;
  end;
  
  case n of
    24: Result := 'The ' + ItemAttrib[n mod 33] + ' Milestone';
    49: Result := 'The ' + ItemAttrib[n mod 33] + ' Midpoint';
    74: Result := 'The ' + ItemAttrib[n mod 33] + ' Apex';
    99: Result := 'The ' + ItemAttrib[n mod 33] + ' Centennial';
    124: Result := 'The ' + ItemAttrib[n mod 33] + ' Tercentennial';
    149: Result := 'The ' + ItemAttrib[n mod 33] + ' Quintessential';
  else
    pattern := n mod 5;
    adjIdx := n mod 33;
    noun1Idx := (n * 7) mod Length(ItemOfs);
    noun2Idx := (n * 13) mod Length(Specials);
    
    adj := ItemAttrib[adjIdx];
    noun1 := ItemOfs[noun1Idx];
    noun2 := Specials[noun2Idx];
    
    case pattern of
      0: Result := 'The ' + adj + ' ' + noun1;
      1: Result := adj + ' ' + noun1;
      2: Result := noun1 + ' of ' + noun2;
      3: Result := 'A ' + adj + ' ' + noun1;
      4: Result := 'The ' + adj + ' ' + noun1 + ' of ' + noun2;
    end;
  end;
end;

{ ---- Timing ---- }

function LevelUpTime(level: Integer): Int64;
begin
  Result := Round((20.0 + IntPower(1.15, level)) * 60.0);
end;

{ ---- Text helpers ---- }

function Split(const s: string; field: Integer): string;
var i, f: Integer;
begin
  Result := ''; f := 0;
  i := 1;
  while i <= Length(s) do begin
    if s[i] = '|' then begin
      if f = field then Exit;
      Inc(f); Inc(i);
    end else begin
      if f = field then Result := Result + s[i];
      Inc(i);
    end;
  end;
end;

function Plural(const s: string): string;
begin
  if (Length(s) > 0) and (s[Length(s)] = 's') then Result := s + 'es'
  else if (Length(s) >= 2) and (Copy(s, Length(s)-1, 2) = 'ch') then Result := s + 'es'
  else Result := s + 's';
end;

function Indefinite(const s: string; qty: Integer): string;
const Vowels = 'aeiouAEIOU';
begin
  if qty <> 1 then
    Result := IntToStr(qty) + ' ' + Plural(s)
  else if (Length(s) > 0) and (Pos(s[1], Vowels) > 0) then
    Result := 'an ' + s
  else
    Result := 'a ' + s;
end;

function Definite(const s: string; qty: Integer): string;
begin
  if qty <> 1 then
    Result := 'the ' + Plural(s)
  else
    Result := 'the ' + s;
end;

function Sick(m: Integer; const s: string): string;
begin
  Result := IntToStr(m) + s;
  case Abs(m) of
  5: Result := 'dead ' + s;
  4: Result := 'comatose ' + s;
  3: Result := 'crippled ' + s;
  2: Result := 'sick ' + s;
  1: Result := 'undernourished ' + s;
  end;
end;

function Young(m: Integer; const s: string): string;
begin
  Result := IntToStr(m) + s;
  case Abs(m) of
  5: Result := 'foetal ' + s;
  4: Result := 'baby ' + s;
  3: Result := 'preadolescent ' + s;
  2: Result := 'teenage ' + s;
  1: Result := 'underage ' + s;
  end;
end;

function Big(m: Integer; const s: string): string;
begin
  Result := s;
  case Abs(m) of
  1: Result := 'greater ' + s;
  2: Result := 'massive ' + s;
  3: Result := 'enormous ' + s;
  4: Result := 'giant ' + s;
  5: Result := 'titanic ' + s;
  end;
end;

function Special(m: Integer; const s: string): string;
begin
  Result := s;
  case Abs(m) of
  1: if Pos(' ', s) > 0 then Result := 'veteran ' + s else Result := 'Battle-' + s;
  2: Result := 'cursed ' + s;
  3: if Pos(' ', s) > 0 then Result := 'warrior ' + s else Result := 'Were-' + s;
  4: Result := 'undead ' + s;
  5: Result := 'demon ' + s;
  end;
end;

function ProperCase(const s: string): string;
begin
  if s = '' then Result := '' else
    Result := UpperCase(Copy(s,1,1)) + Copy(s,2,MaxInt);
end;

{ ---- Name generation ---- }

function DPickPart(const s: string): string;
var count, i, idx, f: Integer;
begin
  count := 1;
  for i := 1 to Length(s) do
    if s[i] = '|' then Inc(count);
  idx := Random(count);
  Result := ''; f := 0;
  for i := 1 to Length(s) do begin
    if s[i] = '|' then begin
      if f = idx then Exit;
      Inc(f);
    end else
      if f = idx then Result := Result + s[i];
  end;
end;

function GenerateName: string;
const
  KParts: array[0..2] of string = (
    'br|cr|dr|fr|gr|j|kr|l|m|n|pr||||r|sh|tr|v|wh|x|y|z',
    'a|a|e|e|i|i|o|o|u|u|ae|ie|oo|ou',
    'b|ck|d|g|k|m|n|p|t|v|x|z');
var i: Integer;
begin
  Result := '';
  for i := 0 to 5 do
    Result := Result + DPickPart(KParts[i mod 3]);
  if Result <> '' then
    Result := UpperCase(Result[1]) + Copy(Result, 2, MaxInt);
end;

{ ---- Item generation ---- }

function BoringItem: string;
begin
  Result := DSplit(BoringItems[Random(Length(BoringItems))], 0);
end;

function InterestingItem: string;
begin
  Result := DSplit(ItemAttrib[Random(Length(ItemAttrib))], 0) + ' ' +
            DSplit(Specials[Random(Length(Specials))], 0);
end;

function SpecialItem: string;
begin
  Result := InterestingItem + ' of ' +
            DSplit(ItemOfs[Random(Length(ItemOfs))], 0);
end;

function NamedMonster(level: Integer): string;
var lev, i, bestLev: Integer;
    m: string;
begin
  Result := ''; bestLev := 0;
  for i := 1 to 5 do begin
    m := Monsters[Random(Length(Monsters))];
    lev := StrToIntDef(DSplit(m, 1), 1);
    if (Result = '') or (Abs(level - lev) < Abs(level - bestLev)) then begin
      Result := DSplit(m, 0);
      bestLev := lev;
    end;
  end;
  Result := GenerateName + ' the ' + Result;
end;

function ImpressiveGuy: string;
begin
  Result := ImpressiveTitles[Random(Length(ImpressiveTitles))];
  case Random(2) of
  0: Result := 'the ' + Result + ' of the ' + Plural(DSplit(Races[Random(Length(Races))], 0));
  1: Result := Result + ' ' + GenerateName + ' of ' + GenerateName;
  end;
end;

function RandSign: Integer;
begin
  if Random(2) = 0 then Result := 1 else Result := -1;
end;

function Odds(x, outof: Integer): Boolean;
begin
  Result := Random(outof) < x;
end;

{ pick from array with preference for low-indexed items }
function RandomLow(n: Integer): Integer;
begin
  Result := Min(Random(n), Random(n));
end;

{ ---- Win functions ---- }

procedure WinSpell(var GS: TGameState);
var idx: Integer;
begin
  idx := RandomLow(Min(GS.Stats[STAT_WIS] + GS.Level,
                       Length(Spells)));
  GS_AddSpellR(GS, DSplit(Spells[idx], 0), 1);
end;

procedure WinStat(var GS: TGameState);
var i: Integer;
    t, r: Int64;
begin
  Inc(GS.StaticSeq);
  if Odds(1, 2) then
    i := Random(STAT_COUNT - 2)  { exclude HP/MP max (indices 6,7) }
  else begin
    { favor high stats }
    t := 0;
    for i := 0 to 5 do Inc(t, GS.Stats[i] * GS.Stats[i]);
    if t = 0 then
      i := Random(6)
    else begin
      { $FFFFFFFF overflows LongInt → Random would receive -1 and return 0 always.
        Use $7FFFFFFF (max positive LongInt) for both halves; shl 31 tiles them. }
      r := (Int64(Random($3FFFFFFF)) shl 31) or Int64(Random($7FFFFFFF));
      r := r mod t;
      i := -1;
      while r >= 0 do begin
        Inc(i);
        Dec(r, GS.Stats[i] * GS.Stats[i]);
      end;
    end;
  end;
  if (i < 0) or (i > 5) then i := Random(6);
  Inc(GS.Stats[i]);
end;

procedure WinEquip(var GS: TGameState);
var posn, qual, plus, count: Integer;
    name, modifier: string;
    stuffLen, betterLen, worseLen: Integer;
    stuff, better, worse: PDSplitArr;
begin
  posn := Random(EQUIP_SLOTS);
  GS.BestEquip := posn;

  { select the appropriate item table }
  stuffLen := 0; betterLen := 0; worseLen := 0;
  if posn = 0 then begin
    stuff   := PDSplitArr(@Weapons);       stuffLen  := Length(Weapons);
    better  := PDSplitArr(@OffenseAttrib); betterLen := Length(OffenseAttrib);
    worse   := PDSplitArr(@OffenseBad);    worseLen  := Length(OffenseBad);
  end else begin
    better  := PDSplitArr(@DefenseAttrib); betterLen := Length(DefenseAttrib);
    worse   := PDSplitArr(@DefenseBad);    worseLen  := Length(DefenseBad);
    if posn = 1 then begin
      stuff := PDSplitArr(@Shields); stuffLen := Length(Shields);
    end else begin
      stuff := PDSplitArr(@Armors);  stuffLen := Length(Armors);
    end;
  end;

  { LPick: pick best of 6 for level }
  name := stuff^[Random(stuffLen)];
  qual := StrToIntDef(DSplit(name, 1), 1);
  for count := 1 to 5 do begin
    modifier := stuff^[Random(stuffLen)];
    if Abs(GS.Level - StrToIntDef(DSplit(modifier,1),1)) < Abs(GS.Level - qual) then begin
      name := modifier;
      qual := StrToIntDef(DSplit(name, 1), 1);
    end;
  end;
  qual := StrToIntDef(DSplit(name, 1), 1);
  name := DSplit(name, 0);

  plus := GS.Level - qual;
  if plus < 0 then begin
    { swap better/worse }
    stuff   := better;
    stuffLen := betterLen;
    better  := worse;
    betterLen := worseLen;
    worse   := stuff;
    worseLen := stuffLen;
  end;

  count := 0;
  while (count < 2) and (plus <> 0) do begin
    modifier := better^[Random(betterLen)];
    qual     := StrToIntDef(DSplit(modifier, 1), 0);
    modifier := DSplit(modifier, 0);
    if Pos(modifier, name) > 0 then Break;
    if Abs(plus) < Abs(qual) then Break;
    name := modifier + ' ' + name;
    Dec(plus, qual);
    Inc(count);
  end;
  if plus <> 0 then name := IntToStr(plus) + ' ' + name;
  if plus > 0  then name := '+' + name;

  GS_PutEquip(GS, posn, name);
  Inc(GS.StaticSeq);
end;

procedure WinItem(var GS: TGameState);
begin
  { Min(250, Random(999)) gives a threshold in 0..250, so the chance of picking
    an existing item scales with inventory size up to ~25% at 250 items. }
  if Min(250, Random(999)) < Length(GS.Inventory) then
    GS_AddInv(GS, GS.Inventory[Random(Length(GS.Inventory))].Key, 1)
  else
    GS_AddInv(GS, SpecialItem, 1);
end;

{ ---- Monster task ---- }

function MonsterTask(var GS: TGameState; var level: Integer): string;
var qty, lev, i, monIdx: Integer;
    monster, m1, item: string;
    definite: Boolean;
begin
  definite := false;

  { adjust level by ±1 with 2/5 odds per level }
  for i := level downto 1 do
    if Odds(2, 5) then Inc(level, RandSign);
  if level < 1 then level := 1;

  if Odds(1, 25) then begin
    { NPC opponent }
    monster := DSplit(Races[Random(Length(Races))], 0);
    if Odds(1, 2) then begin
      monster := 'passing ' + monster + ' ' + DSplit(Klasses[Random(Length(Klasses))], 0);
    end else begin
      monster := DSplit(Titles[RandomLow(Length(Titles))], 0) + ' ' +
                 GenerateName + ' the ' + monster;
      definite := true;
    end;
    lev := level;
    GS.TaskText := 'kill|' + monster + '|' + IntToStr(level) + '|*';
    monster := monster + '|' + IntToStr(level) + '|*';
  end else if (GS.QuestText <> '') and Odds(1, 4) then begin
     { quest monster }
     monster := GS.QuestText;
     try
       lev := StrToIntDef(DSplit(monster, 1), 1);
     except
       lev := level;
     end;
     GS.TaskText := 'kill|' + monster;
  end else begin
    { pick closest to target level from 6 random ones }
    monIdx := Random(Length(Monsters));
    monster := Monsters[monIdx];
    lev := StrToIntDef(DSplit(monster, 1), 1);
    for i := 1 to 5 do begin
      m1 := Monsters[Random(Length(Monsters))];
      if Abs(level - StrToIntDef(DSplit(m1,1),1)) < Abs(level - lev) then begin
        monster := m1;
        lev := StrToIntDef(DSplit(monster, 1), 1);
      end;
    end;
    GS.TaskText := 'kill|' + monster;
  end;

  item := Split(monster, 2);
  if (item = '*') or (item = '') then GS.TaskItem := '' else GS.TaskItem := item;

  Result := DSplit(monster, 0);

  qty := 1;
  if (level - lev) > 10 then begin
    qty := (level + Random(Max(lev, 1))) div Max(lev, 1);
    if qty < 1 then qty := 1;
    level := level div qty;
  end;

  if (level - lev) <= -10 then
    Result := 'imaginary ' + Result
  else if (level - lev) < -5 then begin
    i := 10 + (level - lev);
    i := 5 - Random(i + 1);
    Result := Sick(i, Young((lev - level) - i, Result));
  end else if ((level - lev) < 0) and (Random(2) = 1) then
    Result := Sick(level - lev, Result)
  else if (level - lev) < 0 then
    Result := Young(level - lev, Result)
  else if (level - lev) >= 10 then
    Result := 'messianic ' + Result
  else if (level - lev) > 5 then begin
    i := 10 - (level - lev);
    i := 5 - Random(i + 1);
    Result := Big(i, Special((level - lev) - i, Result));
  end else if ((level - lev) > 0) and (Random(2) = 1) then
    Result := Big(level - lev, Result)
  else if (level - lev) > 0 then
    Result := Special(level - lev, Result);

  lev := level;
  level := lev * qty;

  if not definite then Result := Indefinite(Result, qty);
end;

{ ---- Quest / Act completion ---- }

procedure CompleteQuest(var GS: TGameState);
var lev, level, l, i, montag, n: Integer;
    m: string;
    item: TListItem;
begin
  GS.QuestPos := 0;
  GS.QuestMax := 50 + Random(100);

  { mark last quest done }
  n := Length(GS.Quests);
  if n > 0 then begin
    GS.Quests[n-1].Done := true;
    case Random(4) of
    0: WinSpell(GS);
    1: WinEquip(GS);
    2: WinStat(GS);
    3: WinItem(GS);
    end;
  end;

  { trim old quests }
  while Length(GS.Quests) > 99 do
    Delete(GS.Quests, 0, 1);

  { add new quest }
  lev := 0;
  FillChar(item, SizeOf(item), 0);
  item.Done := false;
  case Random(5) of
  0: begin
       level := GS.Level;
       montag := 0;
       for i := 1 to 4 do begin
         montag := Random(Length(Monsters));
         m := Monsters[montag];
         l := StrToIntDef(DSplit(m, 1), 1);
         if (i = 1) or (Abs(l - level) < Abs(lev - level)) then begin
           lev := l;
           GS.QuestText := m;
           GS.QuestMonTag := montag;
         end;
       end;
       item.Text := 'Exterminate ' + Definite(DSplit(GS.QuestText, 0), 2);
     end;
  1: begin
       GS.QuestText := InterestingItem;
       item.Text := 'Seek ' + Definite(GS.QuestText, 1);
       GS.QuestText := '';
     end;
  2: begin
       GS.QuestText := BoringItem;
       item.Text := 'Deliver this ' + GS.QuestText;
       GS.QuestText := '';
     end;
  3: begin
       GS.QuestText := BoringItem;
       item.Text := 'Fetch me ' + Indefinite(GS.QuestText, 1);
       GS.QuestText := '';
     end;
  4: begin
       level := GS.Level;
       for i := 1 to 2 do begin
         montag := Random(Length(Monsters));
         m := Monsters[montag];
         l := StrToIntDef(DSplit(m, 1), 1);
         if (i = 1) or (Abs(l - level) < Abs(lev - level)) then begin
           lev := l;
           GS.QuestText := m;
         end;
       end;
       item.Text := 'Placate ' + Definite(DSplit(GS.QuestText, 0), 2);
       GS.QuestText := '';
     end;
  end;
  n := Length(GS.Quests);
  SetLength(GS.Quests, n+1);
  GS.Quests[n] := item;
end;

procedure CompleteAct(var GS: TGameState);
var n: Integer;
    item: TListItem;
begin
  GS.PlotPos := 0;
  n := Length(GS.Plots);
  if n > 0 then
    GS.Plots[n-1].Done := true;
  GS.PlotMax := 60 * 60 * (1 + 5 * (n + 1));

  FillChar(item, SizeOf(item), 0);
  item.Text := 'Act ' + IntToRoman(n);
  item.SubText := GetActName(n);
  item.Done := false;
  SetLength(GS.Plots, n+1);
  GS.Plots[n] := item;

  { trim old acts — mirror the Quests cap; prevents unbounded growth in long sessions }
  while Length(GS.Plots) > 99 do
    Delete(GS.Plots, 0, 1);

  if n + 1 > 2 then WinItem(GS);
  if n + 1 > 3 then WinEquip(GS);
end;

{ ---- Level up ---- }

procedure LevelUp(var GS: TGameState);
var i: Integer;
begin
  Inc(GS.Level);
  Inc(GS.Stats[STAT_HPMAX], GS.Stats[STAT_CON] div 3 + 1 + Random(4));
  Inc(GS.Stats[STAT_MPMAX], GS.Stats[STAT_INT] div 3 + 1 + Random(4));
  Inc(GS.StaticSeq);  { HP/MP max changed directly — WinStat covers the rest }
  for i := 1 to 2 do WinStat(GS);
  WinSpell(GS);
  GS.ExpPos := 0;
  GS.ExpMax  := LevelUpTime(GS.Level);
  UpdateEncum(GS);
end;

{ ---- Task helper ---- }

procedure Task(var GS: TGameState; const caption: string; msec: Int64);
begin
  GS.TaskText := caption;
  GS.TaskPos  := 0;
  GS.TaskMax  := msec;
end;

{ ---- Queue ---- }

procedure Q(var GS: TGameState; const s: string);
var n: Integer;
begin
  n := Length(GS.Queue);
  SetLength(GS.Queue, n+1);
  GS.Queue[n] := s;
end;

{ ---- Dequeue ---- }

procedure Dequeue(var GS: TGameState);
var s, a, old: string;
    n, l: Integer;
    taskDone: Boolean;
begin
  taskDone := GS.TaskPos >= GS.TaskMax;
  while taskDone do begin
    GS.TaskItem := '';
    { process completed task }
    if Copy(GS.TaskText, 1, 5) = 'kill|' then begin
      if DSplit(GS.TaskText, 3) = '*' then
        WinItem(GS)
      else if DSplit(GS.TaskText, 3) <> '' then
        GS_AddInv(GS, ProperCase(LowerCase(DSplit(GS.TaskText, 1)) + ' ' +
                      LowerCase(DSplit(GS.TaskText, 3))), 1);
    end else if GS.TaskText = 'buying' then begin
      GS_AddInv(GS, 'Gold', -EquipPrice(GS));
      WinEquip(GS);
    end else if (GS.TaskText = 'market') or (GS.TaskText = 'sell') then begin
      if GS.TaskText = 'sell' then begin
        if Length(GS.Inventory) > 1 then begin
          n := StrToIntDef(GS.Inventory[1].Val, 0) * GS.Level;
          if Pos(' of ', GS.Inventory[1].Key) > 0 then
            n := n * (1 + RandomLow(10)) * (1 + RandomLow(GS.Level));
          { delete item 1, add gold }
          Delete(GS.Inventory, 1, 1);
          GS_AddInv(GS, 'Gold', n);
        end;
      end;
      if Length(GS.Inventory) > 1 then begin
        Task(GS, 'Selling ' + Indefinite(GS.Inventory[1].Key,
                                         StrToIntDef(GS.Inventory[1].Val, 1)),
             1 * 1000);
        GS.TaskText := 'sell';
        Break;
      end;
    end;

    old := GS.TaskText;
    GS.TaskText := '';

    if Length(GS.Queue) > 0 then begin
      a := Split(GS.Queue[0], 0);
      n := StrToIntDef(Split(GS.Queue[0], 1), 1);
      s := Split(GS.Queue[0], 2);
      { pop queue }
      Delete(GS.Queue, 0, 1);
      if (a = 'task') or (a = 'plot') then begin
        if a = 'plot' then begin
          CompleteAct(GS);
          if Length(GS.Plots) > 0 then
            s := 'Loading ' + GS.Plots[High(GS.Plots)].Text;
        end;
        Task(GS, s, n * 1000);
      end;
    end else if GS.EncumPos >= GS.EncumMax then begin
      Task(GS, 'Heading to market to sell loot', 4 * 1000);
      GS.TaskText := 'market';
    end else if (Copy(old, 1, 5) <> 'kill|') and (old <> 'heading') then begin
      if GS_GetInvI(GS, 'Gold') > EquipPrice(GS) then begin
        Task(GS, 'Negotiating purchase of better equipment', 5 * 1000);
        GS.TaskText := 'buying';
      end else begin
        Task(GS, 'Heading to the killing fields', 4 * 1000);
        GS.TaskText := 'heading';
      end;
    end else begin
      n := GS.Level;
      l := n;
      s := MonsterTask(GS, n);  { sets GS.TaskText = 'kill|...' and GS.TaskItem }
      GS.TaskText := GS.TaskText + '|' + s;  { append display name as field 4 }
      n := (2 * GS.GameStyle * n * 1000) div Max(l, 1);
      GS.TaskPos := 0;
      GS.TaskMax := n;
    end;

    taskDone := GS.TaskPos >= GS.TaskMax;
  end;
  UpdateEncum(GS);
end;

{ ---- Plot cinematic ---- }

procedure InterplotCinematic(var GS: TGameState);
var nemesis: string;
    i, sv: Integer;
begin
  case Random(3) of
  0: begin
       Q(GS, 'task|1|Exhausted, you arrive at a friendly oasis in a hostile land');
       Q(GS, 'task|2|You greet old friends and meet new allies');
       Q(GS, 'task|2|You are privy to a council of powerful do-gooders');
       Q(GS, 'task|1|There is much to be done. You are chosen!');
     end;
  1: begin
       Q(GS, 'task|1|Your quarry is in sight, but a mighty enemy bars your path!');
       nemesis := NamedMonster(GS.Level + 3);
       Q(GS, 'task|4|A desperate struggle commences with ' + nemesis);
       sv := Random(3);
       for i := 1 to Random(1 + Length(GS.Plots)) do begin
         Inc(sv, 1 + Random(2));
         case sv mod 3 of
         0: Q(GS, 'task|2|Locked in grim combat with ' + nemesis);
         1: Q(GS, 'task|2|' + nemesis + ' seems to have the upper hand');
         2: Q(GS, 'task|2|You seem to gain the advantage over ' + nemesis);
         end;
       end;
       Q(GS, 'task|3|Victory! ' + nemesis + ' is slain! Exhausted, you lose conciousness');
       Q(GS, 'task|2|You awake in a friendly place, but the road awaits');
     end;
  2: begin
       nemesis := ImpressiveGuy;
       Q(GS, 'task|2|Oh sweet relief! You''ve reached the kind protection of ' + nemesis);
       Q(GS, 'task|3|There is rejoicing, and an unnerving encouter with ' + nemesis + ' in private');
       Q(GS, 'task|2|You forget your ' + BoringItem + ' and go back to get it');
       Q(GS, 'task|2|What''s this!? You overhear something shocking!');
       Q(GS, 'task|2|Could ' + nemesis + ' be a dirty double-dealer?');
       Q(GS, 'task|3|Who can possibly be trusted with this news!? -- Oh yes, of course');
     end;
  end;
  Q(GS, 'plot|2|Loading');
end;

{ ---- Encumbrance update ---- }

procedure UpdateEncum(var GS: TGameState);
begin
  GS.EncumMax  := 10 + GS.Stats[STAT_STR];
  GS.EncumPos  := GS_SumInv(GS) - GS_GetInvI(GS, 'Gold');
  if GS.EncumPos < 0 then GS.EncumPos := 0;
end;

{ ---- Tick (called each loop iteration with elapsed ms) ---- }

procedure TickGame(var GS: TGameState; elapsed: Int64);
var gain: Boolean;
begin
  gain := Pos('kill|', GS.TaskText) = 1;

  Inc(GS.TaskPos, elapsed);
  if GS.TaskPos >= GS.TaskMax then begin
    { gain XP }
    if gain then begin
      if GS.ExpPos >= GS.ExpMax then
        LevelUp(GS)
      else
        Inc(GS.ExpPos, GS.TaskMax div 1000);
    end;

    { advance quest }
    if gain and (Length(GS.Plots) > 1) then begin
      if GS.QuestPos >= GS.QuestMax then
        CompleteQuest(GS)
      else begin
        Inc(GS.QuestPos, GS.TaskMax div 1000);
        if GS.QuestPos > GS.QuestMax then GS.QuestPos := GS.QuestMax;
      end;
    end;

    { advance plot }
    if (GS.PlotPos >= GS.PlotMax) and gain then
      InterplotCinematic(GS)
    else if GS.TaskText <> 'load' then begin
      Inc(GS.PlotPos, GS.TaskMax div 1000);
      if GS.PlotPos > GS.PlotMax then GS.PlotPos := GS.PlotMax;
    end;

    Dequeue(GS);
  end;
end;

{ ---- Starting sequence ---- }

procedure StartTimer(var GS: TGameState);
begin
  { will be called after loading or new character }
  if GS.TaskMax = 0 then GS.TaskMax := 1;
  GS.TaskPos := GS.TaskMax; { trigger Dequeue on first tick }
end;

function EquipPrice(const GS: TGameState): Integer;
begin
  Result := 5 * GS.Level * GS.Level + 10 * GS.Level + 20;
end;

end.
