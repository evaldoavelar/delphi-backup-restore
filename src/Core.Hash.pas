unit Core.Hash;

interface

function Sha256Hex(const AText: string): string;

implementation

uses System.SysUtils, Winapi.Windows, Core.Types, Core.Logger;

const
  PROV_RSA_AES = 24;
  CRYPT_VERIFYCONTEXT = $F0000000;
  CALG_SHA_256 = $0000800C;
  HP_HASHVAL = 2;

function CryptAcquireContextW(out AProvider: NativeUInt; AContainer,
  AProviderName: PWideChar; AProviderType, AFlags: DWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptAcquireContextW';
function CryptReleaseContext(AProvider: NativeUInt; AFlags: DWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptReleaseContext';
function CryptCreateHash(AProvider: NativeUInt; AAlgorithm: DWORD;
  AKey: NativeUInt; AFlags: DWORD; out AHash: NativeUInt): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptCreateHash';
function CryptDestroyHash(AHash: NativeUInt): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptDestroyHash';
function CryptHashData(AHash: NativeUInt; AData: PByte; ASize,
  AFlags: DWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptHashData';
function CryptGetHashParam(AHash: NativeUInt; AParam: DWORD;
  AData: PByte; var ASize: DWORD; AFlags: DWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptGetHashParam';

function Sha256Hex(const AText: string): string;
const
  Hex: string = '0123456789abcdef';
var
  Provider, Hash: NativeUInt;
  Data: TBytes;
  Digest: array [0..31] of Byte;
  Size: DWORD;
  I: Integer;
  L: ILogger;
begin
  L := CreateLogger;
  L.Debug('Calculando SHA-256 do texto UTF-8.');
  Data := TEncoding.UTF8.GetBytes(AText);
  try
    if not CryptAcquireContextW(Provider, nil, nil, PROV_RSA_AES,
      CRYPT_VERIFYCONTEXT) then
      RaiseLastOSError;
    try
      if not CryptCreateHash(Provider, CALG_SHA_256, 0, 0, Hash) then
        RaiseLastOSError;
      try
        if (Length(Data) > 0) and not CryptHashData(Hash, @Data[0], Length(Data), 0) then
          RaiseLastOSError;
        Size := SizeOf(Digest);
        if not CryptGetHashParam(Hash, HP_HASHVAL, @Digest[0], Size, 0) then
          RaiseLastOSError;
        SetLength(Result, 2 * SizeOf(Digest));
        for I := 0 to High(Digest) do
        begin
          Result[2 * I + 1] := Hex[(Digest[I] shr 4) + 1];
          Result[2 * I + 2] := Hex[(Digest[I] and $0F) + 1];
        end;
      finally
        CryptDestroyHash(Hash);
      end;
    finally
      CryptReleaseContext(Provider, 0);
    end;
    L.Debug('SHA-256 calculado.');
  except
    on E: Exception do
    begin
      L.Error('Falha ao calcular SHA-256: ' + E.Message);
      raise;
    end;
  end;
end;

end.
