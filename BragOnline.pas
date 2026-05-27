unit BragOnline;
{ Send character progress reports to the Progress Quest server.
  Replicates the Delphi Brag() procedure from pq/Main.pas lines 1666–1715.

  Only runs for online characters (GS.TraitsTag <> 0).
  HTTP transport: raw POSIX sockets + libc getaddrinfo on Linux/Unix;
  no-op stub on Windows (use the original Delphi client there). }

{$mode objfpc}{$H+}

interface

uses GameState;

type
  TOnlineRealm = record
    Name:    string;
    Desc:    string;
    HostURL: string;   { Brag/knoram endpoint; stored in GS.EquipsHint }
    Options: Integer;  { bitmask: bit3(8)=needs credentials,
                                  bit4(16)=use pq.com create.php,
                                  bit5(32)=disabled }
  end;
  TOnlineRealmArr = array of TOnlineRealm;

{ Fetch the realm list from progressquest.com/list.php.
  Returns True and populates Realms/DefIdx on success;
  False on network error or if no realms are available. }
function BragFetchRealms(out Realms: TOnlineRealmArr;
                         out DefIdx: Integer): Boolean;

{ Register a new character with an online realm server.
  HostURL: realm's Brag endpoint from BragFetchRealms (empty = default server).
  RealmOpts: options bitmask from TOnlineRealm.Options.
  Account/Password: optional HTTP Basic Auth credentials (empty for most realms).
  On success: True, Passkey = server-issued passkey string.
  On failure: False, ErrMsg = reason (server message or 'No response'). }
function BragRegister(const CharName, RealmName, HostURL: string;
                      RealmOpts: Integer;
                      const Account, Password: string;
                      out Passkey, ErrMsg: string): Boolean;

{ Report character progress to the online server.
  trigger: 's'=new game start  'l'=level-up  'a'=act complete  'b'=manual
  No-ops silently if GS.TraitsTag = 0 (offline character).
  Returns True when the server responded (body non-empty); False on network
  failure (DNS error, refused connection, timeout, or offline character). }
function Brag(const GS: TGameState; const trigger: string): Boolean;

implementation

uses
  SysUtils,   { IntToStr, LowerCase, Copy, Pos }
  GameData,   { EquipSlots, StatNames }
  GameLogic,  { RomanToInt }
  TUI         { TUI_Popup }
  {$IFNDEF WINDOWS}, BaseUnix, Sockets{$ENDIF}; { POSIX socket primitives }

{ ---- URL encoding -------------------------------------------------------- }
{ Safe chars: RFC 3986 unreserved (A-Z a-z 0-9 - _ . ~).
  Spaces → %20; the + chars in Brag() URLs are explicit string concatenation,
  not form-encoding artifacts. }

function UrlEncode(const s: string): string;
const
  HexDigit: array[0..15] of Char = '0123456789ABCDEF';
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(s) do begin
    c := s[i];
    case c of
      'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~':
        Result += c;
    else
      Result += '%' + HexDigit[Ord(c) shr 4] + HexDigit[Ord(c) and $F];
    end;
  end;
end;

{ ---- LFSR checksum ------------------------------------------------------- }
{ Direct port of TMainForm.LFSR from pq/Main.pas lines 1651–1663.
  FPC Integer is 32-bit signed in objfpc mode, matching Delphi's Integer.
  shr on signed Integer is a logical (zero-filling) shift in both compilers. }

function LFSR(const pt: string; salt: Integer): Integer;
var k: Integer;
begin
  Result := salt;
  for k := 1 to Length(pt) do
    Result := Ord(pt[k])
          xor (Result shl 1)
          xor (1 and ((Result shr 31) xor (Result shr 5)));
  for k := 1 to 10 do
    Result := (Result shl 1)
          xor (1 and ((Result shr 31) xor (Result shr 5)));
end;

{ ---- URL parser ---------------------------------------------------------- }
{ Splits 'http://host[:port]/path?query' into components.
  Returns False if the URL doesn't start with 'http://'. }

function ParseUrl(const url: string;
                  out host: string; out port: Word;
                  out pathQuery: string): Boolean;
var
  s: string;
  p, q: Integer;
begin
  Result := False;
  if LowerCase(Copy(url, 1, 7)) <> 'http://' then Exit;
  s := Copy(url, 8, MaxInt);         { strip 'http://' }

  { strip optional user:pass@ auth info — not sent by raw socket HTTP }
  p := Pos('@', s);
  q := Pos('/', s);
  if (p > 0) and ((q = 0) or (p < q)) then
    s := Copy(s, p + 1, MaxInt);

  { split host[:port] from path }
  p := Pos('/', s);
  if p = 0 then begin
    host      := s;
    pathQuery := '/';
  end else begin
    host      := Copy(s, 1, p - 1);
    pathQuery := Copy(s, p, MaxInt);
  end;

  { extract port if present }
  p := Pos(':', host);
  if p > 0 then begin
    port := Word(StrToIntDef(Copy(host, p + 1, MaxInt), 80));
    host := Copy(host, 1, p - 1);
  end else
    port := 80;

  Result := True;
end;

{ ---- HTTP GET ------------------------------------------------------------ }
{ Platform-specific raw HTTP/1.0 GET.
  Linux/Unix: POSIX sockets + libc getaddrinfo.
  Windows: stub (use the original Delphi client on Windows). }

{$IFDEF WINDOWS}

function HttpGet(const url: string): string;
begin
  Result := ''; { not implemented on Windows — use the Delphi client }
end;

{$ELSE}  { Linux/Unix }

{ getaddrinfo / freeaddrinfo from libc
  BaseUnix + Sockets included via the implementation uses clause above. }
type
  { Mirrors C struct addrinfo on Linux x86-64.
    Natural record alignment adds 4 bytes of padding between ai_addrlen
    and ai_addr so that the pointer lands on an 8-byte boundary. }
  PAddrInfo = ^TAddrInfo;
  TAddrInfo = record
    ai_flags:     cint;      { offset  0 }
    ai_family:    cint;      { offset  4 }
    ai_socktype:  cint;      { offset  8 }
    ai_protocol:  cint;      { offset 12 }
    ai_addrlen:   cuint;     { offset 16 }
    { compiler inserts 4 bytes padding here → ai_addr at offset 24 }
    ai_addr:      PSockAddr; { offset 24 }
    ai_canonname: PChar;     { offset 32 }
    ai_next:      PAddrInfo; { offset 40 }
  end;                       { total 48 bytes }

function getaddrinfo(node, service: PChar;
                     hints: PAddrInfo; var res: PAddrInfo): cint; cdecl; external 'c';
procedure freeaddrinfo(res: PAddrInfo); cdecl; external 'c';

function HttpGet(const url: string): string;
const
  BufSize = 4096;
var
  host, pathQuery: string;
  port: Word;
  hints, res, cur: PAddrInfo;
  sock: cint;
  req, hdr: string;
  buf: array[0..BufSize-1] of Byte;
  n, sep: Integer;
begin
  Result := '';

  if not ParseUrl(url, host, port, pathQuery) then Exit;

  { DNS resolution via getaddrinfo }
  New(hints);
  FillChar(hints^, SizeOf(TAddrInfo), 0);
  hints^.ai_family   := AF_INET;
  hints^.ai_socktype := SOCK_STREAM;
  res := nil;
  if getaddrinfo(PChar(host), PChar(IntToStr(port)), hints, res) <> 0 then begin
    Dispose(hints);
    Exit;  { DNS failure — silently ignore }
  end;
  Dispose(hints);

  { Find a usable address and connect }
  sock := -1;
  cur  := res;
  while cur <> nil do begin
    sock := fpSocket(cur^.ai_family, cur^.ai_socktype, cur^.ai_protocol);
    if sock >= 0 then begin
      if fpConnect(sock, cur^.ai_addr, cur^.ai_addrlen) = 0 then
        Break;
      fpClose(sock);
      sock := -1;
    end;
    cur := cur^.ai_next;
  end;
  freeaddrinfo(res);

  if sock < 0 then Exit;  { connection failed }

  try
    { HTTP/1.0 GET — no keep-alive; server closes after response }
    req := 'GET ' + pathQuery + ' HTTP/1.0'#13#10
         + 'Host: ' + host + #13#10
         + 'User-Agent: PQ6.4'#13#10
         + 'Connection: close'#13#10
         + #13#10;
    fpSend(sock, @req[1], Length(req), 0);

    { Collect full response }
    hdr := '';
    repeat
      n := fpRecv(sock, @buf[0], BufSize, 0);
      if n > 0 then begin
        SetLength(hdr, Length(hdr) + n);
        Move(buf[0], hdr[Length(hdr) - n + 1], n);
      end;
    until n <= 0;

    { Strip HTTP headers (find blank line \r\n\r\n) }
    sep := Pos(#13#10#13#10, hdr);
    if sep > 0 then
      Result := Copy(hdr, sep + 4, MaxInt)
    else
      Result := hdr;
  finally
    fpClose(sock);
  end;
end;

{$ENDIF}  { WINDOWS / not WINDOWS }

{ ---- Pipe-delimited token splitter --------------------------------------- }
{ Mirrors Delphi's Take(var s): returns the leading token before the first
  '|' and advances s past it; or returns all of s and sets s := ''. }

function TakePipe(var s: string): string;
var p: Integer;
begin
  p := Pos('|', s);
  if p > 0 then begin
    Result := Copy(s, 1, p - 1);
    s := Copy(s, p + 1, MaxInt);
  end else begin
    Result := s;
    s := '';
  end;
end;

{ ---- Realm list fetch ---------------------------------------------------- }

function BragFetchRealms(out Realms: TOnlineRealmArr;
                         out DefIdx: Integer): Boolean;
{ Response format from list.php:
    ok|defaultName|name1|opts1|host1|desc1|name2|opts2|host2|desc2|...
  Disabled realms (Options and 32 <> 0) are filtered out. }
const
  ListURL = 'http://www.progressquest.com/list.php?rev=8';
var
  body, s, defName: string;
  r: TOnlineRealm;
begin
  Result := False;
  SetLength(Realms, 0);
  DefIdx := 0;

  body := HttpGet(ListURL);
  if body = '' then Exit;

  s := body;
  if LowerCase(TakePipe(s)) <> 'ok' then Exit;
  defName := TakePipe(s);     { name of the default realm }

  while s <> '' do begin
    r.Name    := TakePipe(s);
    if r.Name = '' then Break;
    r.Options := StrToIntDef(TakePipe(s), 0);
    r.HostURL := TakePipe(s);
    r.Desc    := TakePipe(s);
    if r.Options and 32 <> 0 then Continue;  { skip disabled realms }
    if r.Name = defName then DefIdx := Length(Realms);
    SetLength(Realms, Length(Realms) + 1);
    Realms[High(Realms)] := r;
  end;

  Result := Length(Realms) > 0;
end;

{ ---- Character registration ---------------------------------------------- }

function BragRegister(const CharName, RealmName, HostURL: string;
                      RealmOpts: Integer;
                      const Account, Password: string;
                      out Passkey, ErrMsg: string): Boolean;
{ Replicates Delphi NewGuy.SoldClick / ParseSoldResponse.
  Create endpoint:
    if RealmOpts bit4 set or HostURL empty → use pq.com/create.php
    otherwise                              → use HostURL
  Response: 'ok|passkey' on success, any other text on failure. }
var
  url, args, auth, body, tok: string;
begin
  Result  := False;
  Passkey := '';
  ErrMsg  := '';

  { Determine create endpoint (mirrors Delphi Label8.Tag and 16 check) }
  if (RealmOpts and 16 <> 0) or (HostURL = '') then
    url := 'http://www.progressquest.com/create.php?'
  else begin
    url := HostURL;
    { ensure the URL ends with '?' as a query separator }
    if (Length(url) = 0) or (url[Length(url)] <> '?') then
      url += '?';
  end;

  args := 'cmd=create'
        + '&name='  + UrlEncode(CharName)
        + '&realm=' + UrlEncode(RealmName)
        + '&rev=8';
  url += args;

  { Optional HTTP Basic Auth: insert 'user:pass@' right after 'http://' }
  if (Account <> '') or (Password <> '') then begin
    auth := UrlEncode(Account) + ':' + UrlEncode(Password) + '@';
    Insert(auth, url, 8);
  end;

  body := HttpGet(url);
  if body = '' then begin
    ErrMsg := 'No response from server.';
    Exit;
  end;

  tok := body;
  if LowerCase(TakePipe(tok)) = 'ok' then begin
    Passkey := Trim(TakePipe(tok));  { strip trailing CR/LF from raw HTTP body }
    if Passkey = '' then begin
      ErrMsg := 'Server returned an empty passkey.';
      Exit;
    end;
    Result := True;
  end else
    ErrMsg := body;  { server-side error message }
end;

{ ---- Main brag procedure ------------------------------------------------- }

function Brag(const GS: TGameState; const trigger: string): Boolean;
var
  q, url, auth, body, hostAddr: string;
  best, i, p: Integer;
begin
  Result := False;
  { Offline character — TraitsTag = 0 means no passkey, skip entirely }
  if GS.TraitsTag = 0 then Exit;
  try

  { Host address: custom realm server or default Progress Quest server }
  hostAddr := GS.EquipsHint;
  if hostAddr = '' then
    hostAddr := 'http://www.progressquest.com/knoram.php?';

  { ---- Build query string (matches Delphi Brag() field order exactly) ---- }

  q := 'cmd=b&t=' + trigger;

  { Traits: n=name  r=race  c=class  l=level
    Delphi: LowerCase(Items[i].Caption[1]) + '=' + UrlEncode(Items[i].Subitems[0])
    for Name/Race/Class/Level in that order. }
  q += '&n=' + UrlEncode(GS.CharName);
  q += '&r=' + UrlEncode(GS.Race);
  q += '&c=' + UrlEncode(GS.Klass);
  q += '&l=' + IntToStr(GS.Level);

  { XP position }
  q += '&x=' + IntToStr(GS.ExpPos);

  { Best equipment slot: item value, then slot-name suffix when slot > 1
    (slots 0=Weapon and 1=Shield omit the slot name, matching Delphi) }
  q += '&i=' + UrlEncode(GS.Equips[GS.BestEquip]);
  if GS.BestEquip > 1 then
    q += '+' + EquipSlots[GS.BestEquip];

  { Best spell: maximise (index+1)*romanLevel; index 0 is the fallback.
    Delphi uses const flat=1, so the weighting formula is (i+flat)=i+1. }
  if Length(GS.Spells) > 0 then begin
    best := 0;
    for i := 1 to High(GS.Spells) do
      if (i + 1) * RomanToInt(GS.Spells[i].Val) >
         (best + 1) * RomanToInt(GS.Spells[best].Val) then
        best := i;
    q += '&z=' + UrlEncode(GS.Spells[best].Key + ' ' + GS.Spells[best].Val);
  end;

  { Best primary stat (indices 0–5 only; HP Max and MP Max excluded).
    Delphi encodes as StatName + '+' + value with a literal +, not UrlEncode. }
  best := 0;
  for i := 1 to 5 do
    if GS.Stats[i] > GS.Stats[best] then best := i;
  q += '&k=' + StatNames[best] + '+' + IntToStr(GS.Stats[best]);

  { Current plot act (last entry in the Plots list) }
  if Length(GS.Plots) > 0 then
    q += '&a=' + UrlEncode(GS.Plots[High(GS.Plots)].Text);

  { Realm hostname (Spells.Hint in Delphi = GS.SpellsHint in FPC) }
  q += '&h=' + UrlEncode(GS.SpellsHint);

  { Protocol revision: rev=8 = PQ 6.4.1 (RevString constant in pq/Main.pas) }
  q += '&rev=8';

  { LFSR checksum over everything built so far }
  q += '&p=' + IntToStr(LFSR(q, GS.TraitsTag));

  { Motto appended after checksum (matches Delphi field order exactly) }
  q += '&m=' + UrlEncode(GS.StatsHint);

  { ---- Assemble full URL with optional HTTP Basic Auth -------------------- }

  url := hostAddr + q;

  { Delphi's AuthenticateUrl inserts login:pass@ at position 8 (right after
    'http://') when either credential field is non-empty. }
  if (GS.InventoryHint <> '') or (GS.PlotsHint <> '') then begin
    auth := UrlEncode(GS.InventoryHint) + ':' + UrlEncode(GS.PlotsHint) + '@';
    Insert(auth, url, 8); { 1-based; position 8 = first char after 'http://' }
  end;

  { ---- Send and handle server response ------------------------------------ }

  body := HttpGet(url);
  Result := True;   { network failure is silently OK — matches Delphi '// 'ats okay.' }

  { Server may send 'report|<message>' to display to the player.
    Delphi: Split(body,0)='report' → ShowMessage(Split(body,1)) }
  p := Pos('|', body);
  if (p > 0) and (LowerCase(Copy(body, 1, p - 1)) = 'report') then
    TUI_Popup(Copy(body, p + 1, MaxInt));
  except
    { Brag is best-effort — never let a network or string error kill the game }
  end;
end;

end.
