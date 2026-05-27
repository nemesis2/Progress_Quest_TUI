unit SaveFile;
{ Reads and writes .pq save files (zlib-compressed Delphi DFM streams)
  Full round-trip compatibility with existing save files. }

{$mode objfpc}{$H+}

interface

uses Classes, GameState, zlibc, Math;

function  LoadSave(const FileName: string; out GS: TGameState): Boolean;
function  SaveSave(const FileName: string; const GS: TGameState;
                   MakeBackup: Boolean): Boolean;

{ Export character sheet to .sheet text file }
procedure ExportCharSheet(const FileName: string; const GS: TGameState);

implementation

uses SysUtils, GameData, GameLogic;

{ ---- DFM Stream Helpers ---- }

const
  vaInt8       = $02;
  vaInt16      = $03;
  vaInt32      = $04;
  vaString     = $06;
  vaIdent      = $07;
  vaFalse      = $08;
  vaTrue       = $09;
  vaBinary     = $0A;
  vaSet        = $0B;
  vaLString    = $0C;
  vaCollection = $0E;
  vaUTF8String = $12;

type
  TByteArray = array of Byte;

  TDFMReader = class
  private
    FData: TByteArray;
    FSize: Integer;
    FPos: Integer;
    function  ReadByte: Byte;
    procedure ReadBuf(var Buf; Count: Integer);
    function  ReadPascalStr: string;
    function  ReadInt32: Integer;
    function  ReadCard32: LongInt;
    function  ReadString: string;
    function  ReadLString: string;
    function  ReadBinary: TBytes;
    function  ReadUTF8: string;
    procedure SkipBinary;
    procedure SkipIdent;
    procedure SkipSet;
    procedure SkipCollection;
    procedure ReadComponent;
    procedure ReadProperties;
    function  HasData: Boolean;
  public
    constructor Create(const Data: TBytes);
  end;

constructor TDFMReader.Create(const Data: TBytes);
begin
  FData := Data;
  FSize := Length(Data);
  FPos  := 0;
end;

function TDFMReader.ReadByte: Byte;
begin
  Result := FData[FPos];
  Inc(FPos);
end;

procedure TDFMReader.ReadBuf(var Buf; Count: Integer);
begin
  Move(FData[FPos], Buf, Count);
  Inc(FPos, Count);
end;

function TDFMReader.ReadInt32: Integer;
begin
  ReadBuf(Result, 4);
end;

function TDFMReader.ReadCard32: LongInt;
begin
  ReadBuf(Result, 4);
end;

function TDFMReader.ReadPascalStr: string;
var Len: Byte;
begin
  Len := ReadByte;
  if Len = 0 then Result := ''
  else begin
    SetLength(Result, Len);
    if Len > 0 then ReadBuf(Result[1], Len);
  end;
end;

function TDFMReader.ReadString: string;
var Len: Byte;
begin
  Len := ReadByte;
  if Len = 0 then Result := ''
  else begin
    SetLength(Result, Len);
    if Len > 0 then ReadBuf(Result[1], Len);
  end;
end;

function TDFMReader.ReadLString: string;
var Len: Integer;
begin
  Len := ReadInt32;
  if Len = 0 then Result := ''
  else begin
    SetLength(Result, Len);
    if Len > 0 then ReadBuf(Result[1], Len);
  end;
end;

function TDFMReader.ReadUTF8: string;
begin
  Result := ReadLString;
end;

function TDFMReader.ReadBinary: TBytes;
var Len: Integer;
begin
  SetLength(Result, 0);
  Len := ReadInt32;
  SetLength(Result, Len);
  if Len > 0 then ReadBuf(Result[0], Len);
end;

procedure TDFMReader.SkipBinary;
var Len: Integer;
begin
  Len := ReadInt32;
  Inc(FPos, Len);
end;

procedure TDFMReader.SkipIdent;
var Len: Byte;
begin
  Len := ReadByte;
  Inc(FPos, Len);
end;

procedure TDFMReader.SkipSet;
var Len: Byte;
begin
  repeat
    Len := ReadByte;
    if Len > 0 then Inc(FPos, Len);
  until Len = 0;
end;

procedure TDFMReader.SkipCollection;
var First, pType: Byte;
    pName: string;
begin
  while True do begin
    First := ReadByte;
    if First = 0 then Break; { end of collection }
    if First <> $01 then Break; { not an item marker }
    { skip properties of this item until 0x00 }
    while True do begin
      pName := ReadPascalStr;
      if pName = '' then Break; { end of item properties }
      pType := ReadByte;
      case pType of
        vaInt8:       ReadByte;
        vaInt16:      Inc(FPos, 2);
        vaInt32:      Inc(FPos, 4);
        vaString:     ReadString;
        vaIdent:      SkipIdent;
        vaFalse:      ;
        vaTrue:       ;
        vaBinary:     SkipBinary;
        vaSet:        SkipSet;
        vaLString:    ReadLString;
        vaUTF8String: ReadUTF8;
        vaCollection: SkipCollection;
        0:            Break;
        else Break;
      end;
    end;
  end;
end;

function TDFMReader.HasData: Boolean;
begin
  Result := (FPos < FSize) and (FData[FPos] <> $00);
end;

procedure TDFMReader.ReadProperties;
var PropType: Byte;
begin
  while True do begin
    ReadPascalStr;
    PropType := ReadByte;
    if PropType = $00 then Break;
    case PropType of
      vaInt8:       ReadByte;
      vaInt16:      Inc(FPos, 2);
      vaInt32:      Inc(FPos, 4);
      vaString:     ReadString;
      vaIdent:      SkipIdent;
      vaFalse:      ;
      vaTrue:       ;
      vaBinary:     SkipBinary;
      vaSet:        SkipSet;
      vaLString:    ReadLString;
      vaUTF8String: ReadUTF8;
      vaCollection: SkipCollection;
      else Break;
    end;
  end;
end;

procedure TDFMReader.ReadComponent;
begin
  { magic "TPF0" already consumed }
  ReadPascalStr; { class name }
  ReadPascalStr; { instance name }
  ReadProperties;
  ReadByte; { 0x00 end of child components }
end;

{ ---- TListView Blob Parser ---- }

function ParseListViewBlob(const Data: TBytes; var subCount: Integer): TListItems;
{ Original Delphi .pq3 format:
    Header:   [1] version=0x06, [4] content_size, [4] item_count  (9 bytes)
    Per item: 7 × int32 (28 bytes) + UTF-16LE strings + 8-byte zero footer (multi-col)
    Trailing: 2 × item_count bytes of 0xFF (multi-column lists only) }
var
  item_count, i, nParsed: Integer;
  pos: Integer;
  img, sCount: Integer;
  charCount: Byte;
  cap, sub: string;
  j: Integer;
begin
  SetLength(Result, 0);
  subCount := 0;
  if Length(Data) < 9 then Exit;

  { [1] version, [4] content_size, [4] item_count }
  item_count := Integer(PLongWord(@Data[5])^);
  pos := 9;

  if (item_count <= 0) or (item_count > 10000) then Exit;

  SetLength(Result, item_count);
  nParsed := 0;
  for i := 0 to item_count - 1 do begin
    if pos + 28 > Length(Data) then Break;

    Inc(pos, 4);                                { state   (unused) }
    img    := PInteger(@Data[pos])^; Inc(pos, 4);  { iImage }
    Inc(pos, 4);                                { iOverlay (unused) }
    sCount := PInteger(@Data[pos])^; Inc(pos, 4);  { subCount }
    Inc(pos, 4);                                { unknown (-1) }
    Inc(pos, 4);                                { indent  (0)  }
    Inc(pos, 4);                                { unknown (0)  }

    { Caption: 1-byte char_count then char_count×2 bytes UTF-16LE }
    if pos >= Length(Data) then Break;
    charCount := Data[pos]; Inc(pos);
    SetLength(cap, charCount);
    for j := 1 to charCount do begin
      if pos + 1 >= Length(Data) then Break;
      cap[j] := Chr(Data[pos]);   { high byte is 0 for ASCII }
      Inc(pos, 2);
    end;

    Result[i].Text    := cap;
    Result[i].SubText := '';
    subCount          := sCount;

    if sCount > 0 then begin
      { Subitem: 1-byte char_count then char_count×2 bytes UTF-16LE }
      if pos >= Length(Data) then Break;
      charCount := Data[pos]; Inc(pos);
      SetLength(sub, charCount);
      for j := 1 to charCount do begin
        if pos + 1 >= Length(Data) then Break;
        sub[j] := Chr(Data[pos]);
        Inc(pos, 2);
      end;
      Result[i].SubText := sub;
      Inc(pos, 8);   { 8-byte zero footer }
    end;

    { For Quests and Plots (single-column), iImage encodes done state }
    Result[i].Done := (sCount = 0) and (img = 1);
    Inc(nParsed);
  end;
  SetLength(Result, nParsed);
end;

function BuildListViewBlob(const Items: TListItems; subCount: Integer;
                            hasTrailing: Boolean): TBytes;
{ Writes original Delphi .pq3 blob format:
    [1] version=0x06, [4] content_size, [4] item_count
    Per item: 7 × int32, UTF-16LE caption, [UTF-16LE subitem + 8-byte footer]
    Trailing: 2 × count bytes of 0xFF (multi-column only) }
var
  count, i, totalSize, pos: Integer;
  capLen, subLen: Integer;
  state, img, overlay, unknown1, indent, unknown2: Integer;
  content_size: LongWord;
  j: Integer;
begin
  count := Length(Items);

  { Calculate total blob size }
  totalSize := 9;  { header: version(1) + content_size(4) + item_count(4) }
  for i := 0 to count - 1 do begin
    Inc(totalSize, 28);  { 7 × 4-byte DWORDs }
    Inc(totalSize, 1 + Length(Items[i].Text) * 2);  { char_count + UTF-16LE }
    if subCount > 0 then begin
      Inc(totalSize, 1 + Length(Items[i].SubText) * 2);
      Inc(totalSize, 8);  { 8-byte zero footer }
    end;
  end;
  if hasTrailing then
    Inc(totalSize, 2 * count);

  SetLength(Result, totalSize);

  { Header }
  Result[0] := $06;  { version }
  content_size := LongWord(totalSize) + LongWord(count) - 9;
  PLongWord(@Result[1])^ := content_size;
  PLongWord(@Result[5])^ := LongWord(count);
  pos := 9;

  overlay  := -1;
  unknown1 := -1;
  indent   := 0;
  unknown2 := 0;

  for i := 0 to count - 1 do begin
    state := 0;
    if subCount = 0 then begin
      if Items[i].Done then img := 1 else img := 0;
    end else
      img := -1;

    PInteger(@Result[pos])^ := state;    Inc(pos, 4);
    PInteger(@Result[pos])^ := img;      Inc(pos, 4);
    PInteger(@Result[pos])^ := overlay;  Inc(pos, 4);
    PInteger(@Result[pos])^ := subCount; Inc(pos, 4);
    PInteger(@Result[pos])^ := unknown1; Inc(pos, 4);
    PInteger(@Result[pos])^ := indent;   Inc(pos, 4);
    PInteger(@Result[pos])^ := unknown2; Inc(pos, 4);

    { Caption as UTF-16LE }
    capLen := Length(Items[i].Text);
    Result[pos] := Byte(capLen); Inc(pos);
    for j := 1 to capLen do begin
      Result[pos] := Ord(Items[i].Text[j]); Inc(pos);
      Result[pos] := 0;                      Inc(pos);
    end;

    if subCount > 0 then begin
      { Subitem as UTF-16LE }
      subLen := Length(Items[i].SubText);
      Result[pos] := Byte(subLen); Inc(pos);
      for j := 1 to subLen do begin
        Result[pos] := Ord(Items[i].SubText[j]); Inc(pos);
        Result[pos] := 0;                         Inc(pos);
      end;
      FillChar(Result[pos], 8, 0);  { 8-byte zero footer }
      Inc(pos, 8);
    end;
  end;

  if hasTrailing then
    FillChar(Result[pos], 2 * count, $FF);
end;

{ ---- DFM Writer ---- }

type
  TDFMWriter = class
  private
    FStream: TMemoryStream;
    procedure WritePascalStr(const s: string);
    procedure WriteInt32(v: Integer);
    procedure WriteString(v: Integer; const s: string);
    procedure WriteBinary(const Data: TBytes);
    procedure WriteLString(const s: string);
    procedure WriteUTF8(const s: string);
    procedure WriteInt32Prop(const Name: string; Value: Integer);
    procedure WriteStringProp(const Name: string; const Value: string);
    procedure WriteBinaryProp(const Name: string; const Data: TBytes);
    procedure WriteBoolProp(const Name: string; Value: Boolean);
    procedure WriteIdentProp(const Name: string; const Value: string);
   procedure WriteComponentStart(const Class_: string; const Name: string);
    procedure WriteComponentEnd;
    procedure WriteEnd;
  public
    constructor Create;
    destructor Destroy; override;
    function GetData: TBytes;
  end;

constructor TDFMWriter.Create;
begin
  inherited Create;
  FStream := TMemoryStream.Create;
end;

destructor TDFMWriter.Destroy;
begin
  FStream.Free;
  inherited Destroy;
end;

function TDFMWriter.GetData: TBytes;
begin
  SetLength(Result, FStream.Size);
  FStream.Position := 0;
  FStream.ReadBuffer(Result[0], FStream.Size);
end;

procedure TDFMWriter.WritePascalStr(const s: string);
var Len: Byte;
begin
  Len := Length(s);
  FStream.WriteBuffer(Len, 1);
  if Len > 0 then FStream.WriteBuffer(s[1], Len);
end;

procedure TDFMWriter.WriteInt32(v: Integer);
begin
  FStream.WriteBuffer(v, 4);
end;

procedure TDFMWriter.WriteString(v: Integer; const s: string);
var Len: Byte; b: Byte;
begin
  b := Byte(v);
  FStream.WriteBuffer(b, 1);
  Len := Length(s);
  FStream.WriteBuffer(Len, 1);
  if Len > 0 then FStream.WriteBuffer(s[1], Len);
end;

procedure TDFMWriter.WriteBinary(const Data: TBytes);
var Len: Integer; b: Byte;
begin
  b := $0A;
  FStream.WriteBuffer(b, 1);
  Len := Length(Data);
  FStream.WriteBuffer(Len, 4);
  if Len > 0 then FStream.WriteBuffer(Data[0], Len);
end;

procedure TDFMWriter.WriteLString(const s: string);
var Len: Integer; b: Byte;
begin
  b := $0C;
  FStream.WriteBuffer(b, 1);
  Len := Length(s);
  FStream.WriteBuffer(Len, 4);
  if Len > 0 then FStream.WriteBuffer(s[1], Len);
end;

procedure TDFMWriter.WriteUTF8(const s: string);
var Len: Integer; b: Byte;
begin
  b := $12;
  FStream.WriteBuffer(b, 1);
  Len := Length(s);
  FStream.WriteBuffer(Len, 4);
  if Len > 0 then FStream.WriteBuffer(s[1], Len);
end;

procedure TDFMWriter.WriteInt32Prop(const Name: string; Value: Integer);
var b: Byte;
begin
  WritePascalStr(Name);
  b := $04;
  FStream.WriteBuffer(b, 1);
  FStream.WriteBuffer(Value, 4);
end;

procedure TDFMWriter.WriteStringProp(const Name: string; const Value: string);
var b: Byte; Len: Integer;
begin
  WritePascalStr(Name);
  Len := Length(Value);
  if Len <= 255 then begin
    b := vaString;   { $06: 1-byte length + chars }
    FStream.WriteBuffer(b, 1);
    FStream.WriteBuffer(Len, 1);
    if Len > 0 then FStream.WriteBuffer(Value[1], Len);
  end else begin
    b := vaLString;  { $0C: 4-byte length + chars }
    FStream.WriteBuffer(b, 1);
    FStream.WriteBuffer(Len, 4);
    FStream.WriteBuffer(Value[1], Len);
  end;
end;

procedure TDFMWriter.WriteBinaryProp(const Name: string; const Data: TBytes);
var Len: Integer; b: Byte;
begin
  WritePascalStr(Name);
  b := $0A;
  FStream.WriteBuffer(b, 1);
  Len := Length(Data);
  FStream.WriteBuffer(Len, 4);
  if Len > 0 then FStream.WriteBuffer(Data[0], Len);
end;

procedure TDFMWriter.WriteBoolProp(const Name: string; Value: Boolean);
var b: Byte;
begin
  WritePascalStr(Name);
  if Value then b := $09 else b := $08;
  FStream.WriteBuffer(b, 1);
end;

procedure TDFMWriter.WriteIdentProp(const Name: string; const Value: string);
var b: Byte; Len: Integer;
begin
  WritePascalStr(Name);
  b := $07;
  FStream.WriteBuffer(b, 1);
  Len := Length(Value);
  FStream.WriteBuffer(Len, 1);
  if Len > 0 then FStream.WriteBuffer(Value[1], Len);
end;

procedure TDFMWriter.WriteComponentStart(const Class_: string; const Name: string);
begin
  FStream.WriteBuffer('TPF0', 4);
  WritePascalStr(Class_);
  WritePascalStr(Name);
end;

procedure TDFMWriter.WriteComponentEnd;
var b: Byte;
begin
  b := $00;
  FStream.WriteBuffer(b, 1);
  FStream.WriteBuffer(b, 1);
end;

procedure TDFMWriter.WriteEnd;
begin
  { nothing to do }
end;

{ ---- Save File Reader ---- }

type
  TSaveContext = record
    GS: TGameState;
    fTaskCaption: string;
    fQuestCaption: string;
    Label8Tag: Integer;
    GameStyle: Integer;
    BestEquip: Integer;
    QuestMonTag: Integer;
    TraitsBlob: TBytes;
    StatsBlob: TBytes;
    SpellsBlob: TBytes;
    InventoryBlob: TBytes;
    EquipsBlob: TBytes;
    QuestsBlob: TBytes;
    PlotsBlob: TBytes;
    ExpPos, ExpMax: Integer;
    QuestPos, QuestMax: Integer;
    PlotPos, PlotMax: Integer;
    EncumPos, EncumMax: Integer;
    TaskPos, TaskMax: Integer;
    { Round-trip credential / hint fields }
    TraitsTag:     Integer;
    TraitsHint:    string;
    StatsHint:     string;
    SpellsHint:    string;
    EquipsHint:    string;
    InventoryHint: string;
    QuestsHint:    string;
    PlotsHint:     string;
    ExpBarHint:    string;
    QuestBarHint:  string;
    PlotBarHint:   string;
    EncumBarHint:  string;
    TaskBarHint:   string;
    GuildHint:     string;
  end;


procedure ExtractState(const GS: TBytes; out ctx: TSaveContext);
var
  Reader: TDFMReader;
  Magic: string;
  InstName: string;
  PropType: Byte;
  propName: string;
  v8: Byte;
  v32: Integer;
  vs: string;
begin
  FillChar(ctx, SizeOf(ctx), 0);
  ctx.GameStyle := 3;

  Reader := TDFMReader.Create(GS);
  try
    while Reader.FPos + 4 <= Reader.FSize do begin
      SetLength(Magic, 4);
      Reader.ReadBuf(Magic[1], 4);
      if Magic <> 'TPF0' then Break;

      Reader.ReadPascalStr; { class name — consumed to advance reader }
      InstName  := Reader.ReadPascalStr;

      { Parse properties: propName(pascal_str) + propType(byte) + value }
      while True do begin
        propName := Reader.ReadPascalStr;
        if propName = '' then Break; { end of properties marker }
        PropType := Reader.ReadByte;
        if PropType = $00 then Break;

        case PropType of
          vaInt8: begin
            { Always consume the byte first, then check if interesting }
            v8 := Reader.ReadByte;
            case InstName of
              'Traits':
                if propName = 'Tag' then ctx.TraitsTag := v8;
              'InventoryLabelAlsoGameStyle':
                if propName = 'Tag' then ctx.GameStyle := v8;
              'Label8':
                if propName = 'Tag' then ctx.Label8Tag := v8;
              'Equips':
                if propName = 'Tag' then ctx.BestEquip := v8;
              'fQuest':
                if propName = 'Tag' then ctx.QuestMonTag := v8;
              'ExpBar':
                if propName = 'Position' then ctx.ExpPos := v8
                else if propName = 'Max' then ctx.ExpMax := v8;
              'QuestBar':
                if propName = 'Position' then ctx.QuestPos := v8
                else if propName = 'Max' then ctx.QuestMax := v8;
              'PlotBar':
                if propName = 'Position' then ctx.PlotPos := v8
                else if propName = 'Max' then ctx.PlotMax := v8;
              'EncumBar':
                if propName = 'Position' then ctx.EncumPos := v8
                else if propName = 'Max' then ctx.EncumMax := v8;
              'TaskBar':
                if propName = 'Position' then ctx.TaskPos := v8
                else if propName = 'Max' then ctx.TaskMax := v8;
            end;
          end;
          vaInt16: begin
            { Always consume 2 bytes first, then check if interesting }
            v32 := SmallInt(PWord(@Reader.FData[Reader.FPos])^);
            Inc(Reader.FPos, 2);
            case InstName of
              'Traits':
                if propName = 'Tag' then ctx.TraitsTag := v32;
              'InventoryLabelAlsoGameStyle':
                if propName = 'Tag' then ctx.GameStyle := v32;
              'Label8':
                if propName = 'Tag' then ctx.Label8Tag := v32;
              'Equips':
                if propName = 'Tag' then ctx.BestEquip := v32;
              'fQuest':
                if propName = 'Tag' then ctx.QuestMonTag := v32;
              'ExpBar':
                if propName = 'Position' then ctx.ExpPos := v32
                else if propName = 'Max' then ctx.ExpMax := v32;
              'QuestBar':
                if propName = 'Position' then ctx.QuestPos := v32
                else if propName = 'Max' then ctx.QuestMax := v32;
              'PlotBar':
                if propName = 'Position' then ctx.PlotPos := v32
                else if propName = 'Max' then ctx.PlotMax := v32;
              'EncumBar':
                if propName = 'Position' then ctx.EncumPos := v32
                else if propName = 'Max' then ctx.EncumMax := v32;
              'TaskBar':
                if propName = 'Position' then ctx.TaskPos := v32
                else if propName = 'Max' then ctx.TaskMax := v32;
            end;
          end;
          vaInt32: begin
            { Always consume the int first, then check if interesting }
            v32 := Reader.ReadInt32;
            case InstName of
              'Traits':
                if propName = 'Tag' then ctx.TraitsTag := v32;
              'InventoryLabelAlsoGameStyle':
                if propName = 'Tag' then ctx.GameStyle := v32;
              'Label8':
                if propName = 'Tag' then ctx.Label8Tag := v32;
              'Equips':
                if propName = 'Tag' then ctx.BestEquip := v32;
              'fQuest':
                if propName = 'Tag' then ctx.QuestMonTag := v32;
              'ExpBar':
                if propName = 'Position' then ctx.ExpPos := v32
                else if propName = 'Max' then ctx.ExpMax := v32;
              'QuestBar':
                if propName = 'Position' then ctx.QuestPos := v32
                else if propName = 'Max' then ctx.QuestMax := v32;
              'PlotBar':
                if propName = 'Position' then ctx.PlotPos := v32
                else if propName = 'Max' then ctx.PlotMax := v32;
              'EncumBar':
                if propName = 'Position' then ctx.EncumPos := v32
                else if propName = 'Max' then ctx.EncumMax := v32;
              'TaskBar':
                if propName = 'Position' then ctx.TaskPos := v32
                else if propName = 'Max' then ctx.TaskMax := v32;
            end;
          end;
          vaString: begin
            { Always consume the string first, then check if interesting }
            vs := Reader.ReadString;
            case InstName of
              'fTask':      if propName = 'Caption' then ctx.fTaskCaption  := vs;
              'fQuest':     if propName = 'Caption' then ctx.fQuestCaption := vs;
              'Label1':     if propName = 'Hint' then ctx.GuildHint     := vs;
              'Traits':     if propName = 'Hint' then ctx.TraitsHint    := vs;
              'Stats':      if propName = 'Hint' then ctx.StatsHint     := vs;
              'Spells':     if propName = 'Hint' then ctx.SpellsHint    := vs;
              'Equips':     if propName = 'Hint' then ctx.EquipsHint    := vs;
              'Inventory':  if propName = 'Hint' then ctx.InventoryHint := vs;
              'Quests':     if propName = 'Hint' then ctx.QuestsHint    := vs;
              'Plots':      if propName = 'Hint' then ctx.PlotsHint     := vs;
              'ExpBar':     if propName = 'Hint' then ctx.ExpBarHint    := vs;
              'QuestBar':   if propName = 'Hint' then ctx.QuestBarHint  := vs;
              'PlotBar':    if propName = 'Hint' then ctx.PlotBarHint   := vs;
              'EncumBar':   if propName = 'Hint' then ctx.EncumBarHint  := vs;
              'TaskBar':    if propName = 'Hint' then ctx.TaskBarHint   := vs;
            end;
          end;
          vaIdent: Reader.SkipIdent;
          vaFalse: ;
          vaTrue: ;
          vaBinary: begin
            { Must check first (blobs can be large), but always consume }
            case InstName of
              'Traits':
                if propName = 'Items.ItemData' then ctx.TraitsBlob    := Reader.ReadBinary
                else Reader.SkipBinary;
              'Stats':
                if propName = 'Items.ItemData' then ctx.StatsBlob     := Reader.ReadBinary
                else Reader.SkipBinary;
              'Spells':
                if propName = 'Items.ItemData' then ctx.SpellsBlob    := Reader.ReadBinary
                else Reader.SkipBinary;
              'Inventory':
                if propName = 'Items.ItemData' then ctx.InventoryBlob := Reader.ReadBinary
                else Reader.SkipBinary;
              'Equips':
                if propName = 'Items.ItemData' then ctx.EquipsBlob    := Reader.ReadBinary
                else Reader.SkipBinary;
              'Quests':
                if propName = 'Items.ItemData' then ctx.QuestsBlob    := Reader.ReadBinary
                else Reader.SkipBinary;
              'Plots':
                if propName = 'Items.ItemData' then ctx.PlotsBlob     := Reader.ReadBinary
                else Reader.SkipBinary;
            else
              Reader.SkipBinary;
            end;
          end;
          vaSet: Reader.SkipSet;
          vaLString: begin
            vs := Reader.ReadLString;
            case InstName of
              'fTask':      if propName = 'Caption' then ctx.fTaskCaption  := vs;
              'fQuest':     if propName = 'Caption' then ctx.fQuestCaption := vs;
              'Label1':     if propName = 'Hint' then ctx.GuildHint     := vs;
              'Traits':     if propName = 'Hint' then ctx.TraitsHint    := vs;
              'Stats':      if propName = 'Hint' then ctx.StatsHint     := vs;
              'Spells':     if propName = 'Hint' then ctx.SpellsHint    := vs;
              'Equips':     if propName = 'Hint' then ctx.EquipsHint    := vs;
              'Inventory':  if propName = 'Hint' then ctx.InventoryHint := vs;
              'Quests':     if propName = 'Hint' then ctx.QuestsHint    := vs;
              'Plots':      if propName = 'Hint' then ctx.PlotsHint     := vs;
              'ExpBar':     if propName = 'Hint' then ctx.ExpBarHint    := vs;
              'QuestBar':   if propName = 'Hint' then ctx.QuestBarHint  := vs;
              'PlotBar':    if propName = 'Hint' then ctx.PlotBarHint   := vs;
              'EncumBar':   if propName = 'Hint' then ctx.EncumBarHint  := vs;
              'TaskBar':    if propName = 'Hint' then ctx.TaskBarHint   := vs;
            end;
          end;
          vaUTF8String: begin
            vs := Reader.ReadUTF8;
            case InstName of
              'fTask':      if propName = 'Caption' then ctx.fTaskCaption  := vs;
              'fQuest':     if propName = 'Caption' then ctx.fQuestCaption := vs;
              'Label1':     if propName = 'Hint' then ctx.GuildHint     := vs;
              'Traits':     if propName = 'Hint' then ctx.TraitsHint    := vs;
              'Stats':      if propName = 'Hint' then ctx.StatsHint     := vs;
              'Spells':     if propName = 'Hint' then ctx.SpellsHint    := vs;
              'Equips':     if propName = 'Hint' then ctx.EquipsHint    := vs;
              'Inventory':  if propName = 'Hint' then ctx.InventoryHint := vs;
              'Quests':     if propName = 'Hint' then ctx.QuestsHint    := vs;
              'Plots':      if propName = 'Hint' then ctx.PlotsHint     := vs;
              'ExpBar':     if propName = 'Hint' then ctx.ExpBarHint    := vs;
              'QuestBar':   if propName = 'Hint' then ctx.QuestBarHint  := vs;
              'PlotBar':    if propName = 'Hint' then ctx.PlotBarHint   := vs;
              'EncumBar':   if propName = 'Hint' then ctx.EncumBarHint  := vs;
              'TaskBar':    if propName = 'Hint' then ctx.TaskBarHint   := vs;
            end;
          end;
          vaCollection: Reader.SkipCollection;
        else
          Break;
        end;
      end;
      Reader.ReadByte; { 0x00 end of child components }
    end;
  finally
    Reader.Free;
  end;
end;

procedure ParseBlobToState(const ctx: TSaveContext; var GS: TGameState);
var
  subCount: Integer;
  items: TListItems;
  i: Integer;
begin
  if Length(ctx.TraitsBlob) > 0 then begin
    items := ParseListViewBlob(ctx.TraitsBlob, subCount);
    if Length(items) >= 4 then begin
      GS.CharName := items[0].SubText;
      GS.Race     := items[1].SubText;
      GS.Klass    := items[2].SubText;
      GS.Level    := StrToIntDef(items[3].SubText, 1);
    end;
  end;

  if Length(ctx.StatsBlob) > 0 then begin
    items := ParseListViewBlob(ctx.StatsBlob, subCount);
    for i := 0 to Min(Length(items), STAT_COUNT-1) do
      GS.Stats[i] := StrToInt64Def(items[i].SubText, 0);
  end;

  if Length(ctx.SpellsBlob) > 0 then begin
    items := ParseListViewBlob(ctx.SpellsBlob, subCount);
    SetLength(GS.Spells, Length(items));
    for i := 0 to Length(items)-1 do begin
      GS.Spells[i].Key := items[i].Text;
      GS.Spells[i].Val := items[i].SubText;
    end;
  end;

  if Length(ctx.InventoryBlob) > 0 then begin
    items := ParseListViewBlob(ctx.InventoryBlob, subCount);
    SetLength(GS.Inventory, Length(items));
    for i := 0 to Length(items)-1 do begin
      GS.Inventory[i].Key := items[i].Text;
      GS.Inventory[i].Val := items[i].SubText;
    end;
  end;

  if Length(ctx.EquipsBlob) > 0 then begin
    items := ParseListViewBlob(ctx.EquipsBlob, subCount);
    for i := 0 to Min(Length(items), EQUIP_SLOTS-1) do
      GS.Equips[i] := items[i].SubText;
  end;

  if Length(ctx.QuestsBlob) > 0 then begin
    items := ParseListViewBlob(ctx.QuestsBlob, subCount);
    SetLength(GS.Quests, Length(items));
    for i := 0 to Length(items)-1 do
      GS.Quests[i] := items[i];
  end;

  if Length(ctx.PlotsBlob) > 0 then begin
    items := ParseListViewBlob(ctx.PlotsBlob, subCount);
    SetLength(GS.Plots, Length(items));
    for i := 0 to Length(items)-1 do
      GS.Plots[i] := items[i];
  end;

  GS.ExpPos   := ctx.ExpPos;
  GS.ExpMax   := ctx.ExpMax;
  GS.QuestPos := ctx.QuestPos;
  GS.QuestMax := ctx.QuestMax;
  GS.PlotPos  := ctx.PlotPos;
  GS.PlotMax  := ctx.PlotMax;
  GS.EncumPos := ctx.EncumPos;
  GS.EncumMax := ctx.EncumMax;
  GS.TaskPos  := ctx.TaskPos;
  GS.TaskMax  := ctx.TaskMax;
  { Delphi default captions equal the component name; treat those as empty }
  if ctx.fTaskCaption  = 'fTask'  then GS.TaskText  := '' else GS.TaskText  := ctx.fTaskCaption;
  if ctx.fQuestCaption = 'fQuest' then GS.QuestText := '' else GS.QuestText := ctx.fQuestCaption;
  GS.GameStyle   := ctx.GameStyle;
  GS.Label8Tag   := ctx.Label8Tag;
  GS.BestEquip   := ctx.BestEquip;
  GS.QuestMonTag := ctx.QuestMonTag;
  GS.TraitsTag     := ctx.TraitsTag;
  GS.TraitsHint    := ctx.TraitsHint;
  GS.StatsHint     := ctx.StatsHint;
  GS.SpellsHint    := ctx.SpellsHint;
  GS.EquipsHint    := ctx.EquipsHint;
  GS.InventoryHint := ctx.InventoryHint;
  GS.QuestsHint    := ctx.QuestsHint;
  GS.PlotsHint     := ctx.PlotsHint;
  GS.ExpBarHint    := ctx.ExpBarHint;
  GS.QuestBarHint  := ctx.QuestBarHint;
  GS.PlotBarHint   := ctx.PlotBarHint;
  GS.EncumBarHint  := ctx.EncumBarHint;
  GS.TaskBarHint   := ctx.TaskBarHint;
  GS.GuildHint     := ctx.GuildHint;
end;

{ ---- Load ---- }

function LoadSave(const FileName: string; out GS: TGameState): Boolean;
var
  FS: TFileStream;
  MS: TMemoryStream;
  Data: TBytes;
  Size: Integer;
  ctx: TSaveContext;
  i: Integer;
begin
  Result := False;
  InitNewGame(GS);
  try
    FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      MS := TMemoryStream.Create;
      try
        ZDecompressStream(FS, MS);
        Size := MS.Size;
        SetLength(Data, Size);
        MS.Position := 0;
        MS.ReadBuffer(Data[0], Size);
      finally
        MS.Free;
      end;
    finally
      FS.Free;
    end;

    ExtractState(Data, ctx);
    ParseBlobToState(ctx, GS);
    
    for i := 0 to Length(GS.Plots) - 1 do
      if GS.Plots[i].SubText = '' then
        GS.Plots[i].SubText := GetActName(i);
    
    Result := True;
  except
    on E: Exception do
      WriteLn('LoadSave error: ' + E.ClassName + ' - ' + E.Message);
  end;
  if not Result then
    InitNewGame(GS);
end;

{ ---- Save ---- }

function BuildItemsFromState(const Items: TListItems; subCount: Integer;
                              hasTrailing: Boolean): TBytes;
begin
  Result := BuildListViewBlob(Items, subCount, hasTrailing);
end;

{ ---- Char Sheet Helpers ---- }

function RoughTime(s: Integer): string;
begin
  if s < 120 then Result := IntToStr(s) + ' seconds'
  else if s < 60*120 then Result := IntToStr(s div 60) + ' minutes'
  else if s < 60*60*48 then Result := IntToStr(s div 3600) + ' hours'
  else Result := IntToStr(s div (3600*24)) + ' days';
end;

function IndefiniteArticle(const s: string): string;
const Vowels = 'aeiouAEIOU';
begin
  if (Length(s) > 0) and (Pos(s[1], Vowels) > 0) then Result := 'an' else Result := 'a';
end;

function SaveSave(const FileName: string; const GS: TGameState;
                  MakeBackup: Boolean): Boolean;
var
  MS: TMemoryStream;
  FS: TFileStream;
  Writer: TDFMWriter;
  Data: TBytes;
  i: Integer;
  traitsItems, statsItems, spellsItems, inventoryItems, equipsItems,
  questsItems, plotsItems: TListItems;
  traitsBlob, statsBlob, spellsBlob, inventoryBlob, equipsBlob,
  questsBlob, plotsBlob: TBytes;
begin
  Result := False;

  { Build list item arrays from TGameState }
  SetLength(traitsItems, 4);
  traitsItems[0].Text := 'Name';    traitsItems[0].SubText := GS.CharName; traitsItems[0].Done := False;
  traitsItems[1].Text := 'Race';    traitsItems[1].SubText := GS.Race;     traitsItems[1].Done := False;
  traitsItems[2].Text := 'Class';   traitsItems[2].SubText := GS.Klass;    traitsItems[2].Done := False;
  traitsItems[3].Text := 'Level';   traitsItems[3].SubText := IntToStr(GS.Level); traitsItems[3].Done := False;

  SetLength(statsItems, STAT_COUNT);
  for i := 0 to STAT_COUNT-1 do begin
    statsItems[i].Text := StatNames[i];
    statsItems[i].SubText := IntToStr(GS.Stats[i]);
    statsItems[i].Done := False;
  end;

  SetLength(spellsItems, Length(GS.Spells));
  for i := 0 to Length(spellsItems)-1 do begin
    spellsItems[i].Text := GS.Spells[i].Key;
    spellsItems[i].SubText := GS.Spells[i].Val;
    spellsItems[i].Done := False;
  end;

  SetLength(inventoryItems, Length(GS.Inventory));
  for i := 0 to Length(inventoryItems)-1 do begin
    inventoryItems[i].Text := GS.Inventory[i].Key;
    inventoryItems[i].SubText := GS.Inventory[i].Val;
    inventoryItems[i].Done := False;
  end;

  SetLength(equipsItems, EQUIP_SLOTS);
  for i := 0 to EQUIP_SLOTS-1 do begin
    equipsItems[i].Text := EquipSlots[i];
    equipsItems[i].SubText := GS.Equips[i];
    equipsItems[i].Done := False;
  end;

  SetLength(questsItems, Length(GS.Quests));
  for i := 0 to Length(questsItems)-1 do
    questsItems[i] := GS.Quests[i];

  SetLength(plotsItems, Length(GS.Plots));
  for i := 0 to Length(plotsItems)-1 do
    plotsItems[i] := GS.Plots[i];

  { Build blobs }
  traitsBlob    := BuildItemsFromState(traitsItems,  1, True);
  statsBlob     := BuildItemsFromState(statsItems,   1, True);
  spellsBlob    := BuildItemsFromState(spellsItems,  1, True);
  inventoryBlob := BuildItemsFromState(inventoryItems, 1, True);
  equipsBlob    := BuildItemsFromState(equipsItems,  1, True);
  questsBlob    := BuildItemsFromState(questsItems,  0, False);
  plotsBlob     := BuildItemsFromState(plotsItems,   0, False);

  { Backup }
  if MakeBackup then begin
    if FileExists(FileName) then begin
      DeleteFile(ChangeFileExt(FileName, '.bak'));
      RenameFile(FileName, ChangeFileExt(FileName, '.bak'));
    end;
  end;

  { Write DFM stream }
  Writer := TDFMWriter.Create;
  try
    MS := TMemoryStream.Create;
    try
      { Component 1: Panel1 }
      Writer.WriteComponentStart('TPanel', 'Panel1'); Writer.WriteComponentEnd;
      { Component 2: Label1 }
      Writer.WriteComponentStart('TLabel', 'Label1');
      if GS.GuildHint <> '' then
        Writer.WriteStringProp('Hint', GS.GuildHint);
      Writer.WriteComponentEnd;
      { Component 3: Label6 }
      Writer.WriteComponentStart('TLabel', 'Label6'); Writer.WriteComponentEnd;
      { Component 4: Label4 }
      Writer.WriteComponentStart('TLabel', 'Label4'); Writer.WriteComponentEnd;
      { Component 5: Traits }
      Writer.WriteComponentStart('TListView', 'Traits');
      if GS.TraitsTag <> 0 then
        Writer.WriteInt32Prop('Tag', GS.TraitsTag);
      if GS.TraitsHint <> '' then
        Writer.WriteStringProp('Hint', GS.TraitsHint);
      Writer.WriteBinaryProp('Items.ItemData', traitsBlob);
      Writer.WriteComponentEnd;
      { Component 6: Stats }
      Writer.WriteComponentStart('TListView', 'Stats');
      if GS.StatsHint <> '' then
        Writer.WriteStringProp('Hint', GS.StatsHint);
      Writer.WriteBinaryProp('Items.ItemData', statsBlob);
      Writer.WriteComponentEnd;
      { Component 7: ExpBar }
      Writer.WriteComponentStart('TProgressBar', 'ExpBar');
      Writer.WriteInt32Prop('Position', GS.ExpPos);
      Writer.WriteInt32Prop('Max', GS.ExpMax);
      if GS.ExpMax > 0 then
        Writer.WriteStringProp('Hint',
          IntToStr(GS.ExpMax - GS.ExpPos) + ' XP needed for next level');
      Writer.WriteComponentEnd;
      { Component 8: Spells }
      Writer.WriteComponentStart('TListView', 'Spells');
      if GS.SpellsHint <> '' then
        Writer.WriteStringProp('Hint', GS.SpellsHint);
      Writer.WriteBinaryProp('Items.ItemData', spellsBlob);
      Writer.WriteComponentEnd;
      { Component 9-14: Cheats, buttons }
      Writer.WriteComponentStart('TPanel', 'Cheats'); Writer.WriteComponentEnd;
      Writer.WriteComponentStart('TButton', 'CashIn'); Writer.WriteComponentEnd;
      Writer.WriteComponentStart('TButton', 'Button1'); Writer.WriteComponentEnd;
      Writer.WriteComponentStart('TButton', 'FinishQuest'); Writer.WriteComponentEnd;
      Writer.WriteComponentStart('TButton', 'Button3'); Writer.WriteComponentEnd;
      Writer.WriteComponentStart('TButton', 'CheatPlot'); Writer.WriteComponentEnd;
      { Component 15: Panel3 }
      Writer.WriteComponentStart('TPanel', 'Panel3'); Writer.WriteComponentEnd;
      { Component 16: Label3 }
      Writer.WriteComponentStart('TLabel', 'Label3'); Writer.WriteComponentEnd;
      { Component 17: Label2 }
      Writer.WriteComponentStart('TLabel', 'Label2'); Writer.WriteComponentEnd;
      { Component 18: QuestBar }
      Writer.WriteComponentStart('TProgressBar', 'QuestBar');
      Writer.WriteInt32Prop('Position', GS.QuestPos);
      Writer.WriteInt32Prop('Max', GS.QuestMax);
      if GS.QuestMax > 0 then
        Writer.WriteStringProp('Hint',
          IntToStr(100 * GS.QuestPos div GS.QuestMax) + '% complete');
      Writer.WriteComponentEnd;
      { Component 19: Plots }
      Writer.WriteComponentStart('TListView', 'Plots');
      if GS.PlotsHint <> '' then
        Writer.WriteStringProp('Hint', GS.PlotsHint);
      Writer.WriteBinaryProp('Items.ItemData', plotsBlob);
      Writer.WriteComponentEnd;
      { Component 20: PlotBar }
      Writer.WriteComponentStart('TProgressBar', 'PlotBar');
      Writer.WriteInt32Prop('Position', GS.PlotPos);
      Writer.WriteInt32Prop('Max', GS.PlotMax);
      if GS.PlotMax > 0 then
        Writer.WriteStringProp('Hint',
          RoughTime(GS.PlotMax - GS.PlotPos) + ' remaining');
      Writer.WriteComponentEnd;
      { Component 21: Quests }
      Writer.WriteComponentStart('TListView', 'Quests');
      if GS.QuestsHint <> '' then
        Writer.WriteStringProp('Hint', GS.QuestsHint);
      Writer.WriteBinaryProp('Items.ItemData', questsBlob);
      Writer.WriteComponentEnd;
      { Component 22: Panel2 }
      Writer.WriteComponentStart('TPanel', 'Panel2'); Writer.WriteComponentEnd;
      { Component 23: InventoryLabelAlsoGameStyle }
      Writer.WriteComponentStart('TLabel', 'InventoryLabelAlsoGameStyle');
      Writer.WriteInt32Prop('Tag', GS.GameStyle);
      Writer.WriteComponentEnd;
      { Component 24: Label7 }
      Writer.WriteComponentStart('TLabel', 'Label7'); Writer.WriteComponentEnd;
      { Component 25: Label8 }
      Writer.WriteComponentStart('TLabel', 'Label8');
      Writer.WriteInt32Prop('Tag', GS.Label8Tag);
      Writer.WriteComponentEnd;
      { Component 26: Inventory }
      Writer.WriteComponentStart('TListView', 'Inventory');
      if GS.InventoryHint <> '' then
        Writer.WriteStringProp('Hint', GS.InventoryHint);
      Writer.WriteBinaryProp('Items.ItemData', inventoryBlob);
      Writer.WriteComponentEnd;
      { Component 27: EncumBar }
      Writer.WriteComponentStart('TProgressBar', 'EncumBar');
      Writer.WriteInt32Prop('Position', GS.EncumPos);
      Writer.WriteInt32Prop('Max', GS.EncumMax);
      Writer.WriteStringProp('Hint',
        IntToStr(GS.EncumPos) + '/' + IntToStr(GS.EncumMax) + ' cubits');
      Writer.WriteComponentEnd;
      { Component 28: Equips }
      Writer.WriteComponentStart('TListView', 'Equips');
      Writer.WriteInt32Prop('Tag', GS.BestEquip);
      if GS.EquipsHint <> '' then
        Writer.WriteStringProp('Hint', GS.EquipsHint);
      Writer.WriteBinaryProp('Items.ItemData', equipsBlob);
      Writer.WriteComponentEnd;
      { Component 29: vars }
      Writer.WriteComponentStart('TPanel', 'vars'); Writer.WriteComponentEnd;
      { Component 30: fTask }
      Writer.WriteComponentStart('TLabel', 'fTask');
      Writer.WriteStringProp('Caption', GS.TaskText);
      Writer.WriteComponentEnd;
      { Component 31: fQuest }
      Writer.WriteComponentStart('TLabel', 'fQuest');
      Writer.WriteStringProp('Caption', GS.QuestText);
      Writer.WriteInt32Prop('Tag', GS.QuestMonTag);
      Writer.WriteComponentEnd;
      { Component 32: fQueue }
      Writer.WriteComponentStart('TListBox', 'fQueue'); Writer.WriteComponentEnd;
      { Component 33: Panel4 }
      Writer.WriteComponentStart('TPanel', 'Panel4'); Writer.WriteComponentEnd;
      { Component 34: Kill }
      Writer.WriteComponentStart('TStatusBar', 'Kill'); Writer.WriteComponentEnd;
      { Component 35: TaskBar }
      Writer.WriteComponentStart('TProgressBar', 'TaskBar');
      Writer.WriteInt32Prop('Position', GS.TaskPos);
      Writer.WriteInt32Prop('Max', GS.TaskMax);
      { Delphi never sets TaskBar.Hint — do not write it }
      Writer.WriteComponentEnd;
      { Component 36: Timer1 }
      Writer.WriteComponentStart('TTimer', 'Timer1'); Writer.WriteComponentEnd;
      { Component 37: ImageList1 }
      Writer.WriteComponentStart('TImageList', 'ImageList1'); Writer.WriteComponentEnd;

      Data := Writer.GetData;

      { Zlib compress and write }
      if MakeBackup or not FileExists(FileName) then begin
        FS := TFileStream.Create(FileName, fmCreate);
      end else begin
        FS := TFileStream.Create(FileName, fmOpenWrite or fmShareExclusive);
        FS.Size := 0;
      end;
      try
        MS.Position := 0;
        MS.SetSize(Length(Data));
        MS.WriteBuffer(Data[0], Length(Data));
        MS.Position := 0;
        ZCompressStream(MS, FS);
      finally
        FS.Free;
      end;
      Result := True;
    finally
      MS.Free;
    end;
  finally
    Writer.Free;
  end;
end;

{ ---- Char Sheet ---- }

procedure ExportCharSheet(const FileName: string; const GS: TGameState);
var
  f: TextFile;
  i: Integer;
  hdr: string;
begin
  AssignFile(f, FileName);
  Rewrite(f);
  try
    { === Character === }
    WriteLn(f, GS.CharName);
    WriteLn(f, GS.Race + ' ' + GS.Klass);
    WriteLn(f, Format('Level %d', [GS.Level]));
    WriteLn(f);

    { === Online Identity (only when credentials are present) === }
    if (GS.TraitsTag <> 0) or (GS.StatsHint <> '') or
       (GS.InventoryHint <> '') or (GS.SpellsHint <> '') or
       (GS.GuildHint <> '') then begin
      WriteLn(f, 'Online Identity:');
      if GS.TraitsHint <> '' then
        WriteLn(f, '  Passkey:  ' + GS.TraitsHint)
      else if GS.TraitsTag <> 0 then
        WriteLn(f, '  Passkey:  ' + IntToStr(GS.TraitsTag));
      if GS.StatsHint <> '' then
        WriteLn(f, '  Motto:    ' + GS.StatsHint);
      if GS.GuildHint <> '' then
        WriteLn(f, '  Guild:    ' + GS.GuildHint);
      if GS.InventoryHint <> '' then
        WriteLn(f, '  Username: ' + GS.InventoryHint);
      if GS.PlotsHint <> '' then
        WriteLn(f, '  Password: ' + GS.PlotsHint);
      if GS.SpellsHint <> '' then
        WriteLn(f, '  Realm:    ' + GS.SpellsHint);
      if GS.EquipsHint <> '' then
        WriteLn(f, '  Host:     ' + GS.EquipsHint);
      if GS.QuestsHint <> '' then
        WriteLn(f, '  (Quests hint: ' + GS.QuestsHint + ')');
      WriteLn(f);
    end;

    { === Progress (hints computed from current values, matching Delphi's timer logic) === }
    WriteLn(f, 'Progress:');
    if GS.ExpMax > 0 then
      WriteLn(f, Format('  Experience:  %d / %d  [%s]',
        [GS.ExpPos, GS.ExpMax,
         IntToStr(GS.ExpMax - GS.ExpPos) + ' XP needed for next level']))
    else
      WriteLn(f, Format('  Experience:  %d / %d', [GS.ExpPos, GS.ExpMax]));
    if GS.QuestMax > 0 then
      WriteLn(f, Format('  Quest:       %d / %d  [%d%% complete]',
        [GS.QuestPos, GS.QuestMax, 100 * GS.QuestPos div GS.QuestMax]))
    else
      WriteLn(f, Format('  Quest:       %d / %d', [GS.QuestPos, GS.QuestMax]));
    if GS.PlotMax > 0 then
      WriteLn(f, Format('  Plot:        %d / %d  [%s remaining]',
        [GS.PlotPos, GS.PlotMax, RoughTime(GS.PlotMax - GS.PlotPos)]))
    else
      WriteLn(f, Format('  Plot:        %d / %d', [GS.PlotPos, GS.PlotMax]));
    WriteLn(f, Format('  Encumbrance: %d / %d  [%s]',
      [GS.EncumPos, GS.EncumMax,
       IntToStr(GS.EncumPos) + '/' + IntToStr(GS.EncumMax) + ' cubits']));
    if GS.TaskMax > 0 then
      WriteLn(f, Format('  Task:        %d / %d ms', [GS.TaskPos, GS.TaskMax]));
    WriteLn(f);

    { === Current Activity === }
    if (GS.TaskText <> '') or (GS.QuestText <> '') then begin
      WriteLn(f, 'Current Activity:');
      if GS.TaskText <> '' then
        WriteLn(f, '  Task:         ' + GS.TaskText);
      if GS.QuestText <> '' then
        WriteLn(f, '  Quest target: ' + GS.QuestText);
      WriteLn(f);
    end;

    { === Stats === }
    WriteLn(f, 'Stats:');
    WriteLn(f, Format('  STR%7d', [GS.Stats[STAT_STR]]));
    WriteLn(f, Format('  CON%7d', [GS.Stats[STAT_CON]]));
    WriteLn(f, Format('  DEX%7d', [GS.Stats[STAT_DEX]]));
    WriteLn(f, Format('  INT%7d', [GS.Stats[STAT_INT]]));
    WriteLn(f, Format('  WIS%7d      HP Max%7d', [GS.Stats[STAT_WIS], GS.Stats[STAT_HPMAX]]));
    WriteLn(f, Format('  CHA%7d      MP Max%7d', [GS.Stats[STAT_CHA], GS.Stats[STAT_MPMAX]]));
    WriteLn(f);

    { === Equipment === }
    if (GS.BestEquip >= 0) and (GS.BestEquip < EQUIP_SLOTS) then
      hdr := Format('Equipment (last purchased: %s):', [EquipSlots[GS.BestEquip]])
    else
      hdr := 'Equipment:';
    WriteLn(f, hdr);
    for i := 0 to EQUIP_SLOTS-1 do
      WriteLn(f, Format('  %-12s %s', [EquipSlots[i], GS.Equips[i]]));
    WriteLn(f);

    { === Spell Book === }
    WriteLn(f, Format('Spell Book (%d spells):', [Length(GS.Spells)]));
    for i := 0 to Length(GS.Spells)-1 do
      WriteLn(f, Format('  %s %s', [GS.Spells[i].Key, GS.Spells[i].Val]));
    WriteLn(f);

    { === Inventory === }
    WriteLn(f, Format('Inventory (%d/%d cubits):', [GS.EncumPos, GS.EncumMax]));
    WriteLn(f, Format('  %d gold piece', [GS_GetInvI(GS, 'Gold')]));
    for i := 1 to Length(GS.Inventory)-1 do
      WriteLn(f, Format('  %s %s', [GS.Inventory[i].Val, GS.Inventory[i].Key]));
    WriteLn(f);

    { === Quests (full list with completion markers) === }
    WriteLn(f, Format('Quests (%d):', [Length(GS.Quests)]));
    for i := 0 to Length(GS.Quests)-1 do begin
      if GS.Quests[i].Done then
        WriteLn(f, '  [x] ' + GS.Quests[i].Text)
      else
        WriteLn(f, '  [ ] ' + GS.Quests[i].Text);
    end;
    WriteLn(f);

    { === Plots (full list with completion markers) === }
    WriteLn(f, Format('Plot (%d acts):', [Length(GS.Plots)]));
    for i := 0 to Length(GS.Plots)-1 do begin
      if GS.Plots[i].Done then
        WriteLn(f, '  [x] ' + GS.Plots[i].Text)
      else
        WriteLn(f, '  [ ] ' + GS.Plots[i].Text);
    end;
    WriteLn(f);

    { === Action Queue (usually empty at save time) === }
    if Length(GS.Queue) > 0 then begin
      WriteLn(f, Format('Action Queue (%d):', [Length(GS.Queue)]));
      for i := 0 to Length(GS.Queue)-1 do
        WriteLn(f, '  ' + GS.Queue[i]);
      WriteLn(f);
    end;

    { === Game Flags === }
    WriteLn(f, Format('Game: style=%d  flags=%d  quest-mon=%d',
      [GS.GameStyle, GS.Label8Tag, GS.QuestMonTag]));
    WriteLn(f);

    { === Footer === }
    WriteLn(f, '-- ' + DateTimeToStr(Now));
    WriteLn(f, '-- Progress Quest 6.4 - http://progressquest.com/');
  finally
    CloseFile(f);
  end;
end;

end.
