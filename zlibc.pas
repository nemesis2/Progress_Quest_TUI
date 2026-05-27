unit zlibc;
{ zlib compress/decompress streams — pure Pascal via bundled paszlib.
  No external DLL required on any platform. }

{$mode objfpc}{$H+}

interface

uses SysUtils, Classes;

procedure ZCompressStream(Source, Dest: TStream);
procedure ZDecompressStream(Source, Dest: TStream);

implementation

uses zbase, zdeflate, zinflate;

const
  BufSize = 32768;

function ZCheck(code: Integer): Integer;
const
  Msgs: array[-6..2] of string = (
    'incompatible version', 'buffer error', 'insufficient memory',
    'data error', 'stream error', 'file error',
    '', 'stream end', 'need dictionary');
begin
  Result := code;
  if code < 0 then
    raise Exception.Create('zlib error: ' + Msgs[code]);
end;

procedure ZCompressStream(Source, Dest: TStream);
var
  s: z_stream;
  inBuf: array[0..BufSize-1] of Byte;
  outBuf: array[0..BufSize-1] of Byte;
  inSize, outSize: Integer;
begin
  FillChar(s, SizeOf(s), 0);
  ZCheck(deflateInit(s, Z_DEFAULT_COMPRESSION));
  try
    inSize := Source.Read(inBuf, BufSize);
    while inSize > 0 do begin
      s.next_in := @inBuf[0];
      s.avail_in := inSize;
      repeat
        s.next_out := @outBuf[0];
        s.avail_out := BufSize;
        ZCheck(deflate(s, Z_NO_FLUSH));
        outSize := BufSize - Integer(s.avail_out);
        Dest.Write(outBuf, outSize);
      until (s.avail_in = 0) and (s.avail_out > 0);
      inSize := Source.Read(inBuf, BufSize);
    end;
    repeat
      s.next_out := @outBuf[0];
      s.avail_out := BufSize;
      ZCheck(deflate(s, Z_FINISH));
      outSize := BufSize - Integer(s.avail_out);
      Dest.Write(outBuf, outSize);
    until (s.avail_out > 0);
  finally
    deflateEnd(s);
  end;
end;

procedure ZDecompressStream(Source, Dest: TStream);
var
  s: z_stream;
  inBuf: array[0..BufSize-1] of Byte;
  outBuf: array[0..BufSize-1] of Byte;
  inSize, outSize: Integer;
  r: Integer;
begin
  FillChar(s, SizeOf(s), 0);
  ZCheck(inflateInit(s));
  try
    inSize := Source.Read(inBuf, BufSize);
    while inSize > 0 do begin
      s.next_in := @inBuf[0];
      s.avail_in := inSize;
      repeat
        s.next_out := @outBuf[0];
        s.avail_out := BufSize;
        ZCheck(inflate(s, Z_NO_FLUSH));
        outSize := BufSize - Integer(s.avail_out);
        Dest.Write(outBuf, outSize);
      until (s.avail_in = 0) and (s.avail_out > 0);
      inSize := Source.Read(inBuf, BufSize);
    end;
    repeat
      s.next_out := @outBuf[0];
      s.avail_out := BufSize;
      r := ZCheck(inflate(s, Z_FINISH));
      outSize := BufSize - Integer(s.avail_out);
      Dest.Write(outBuf, outSize);
    until (r = Z_STREAM_END) and (s.avail_out > 0);
  finally
    inflateEnd(s);
  end;
end;

end.
