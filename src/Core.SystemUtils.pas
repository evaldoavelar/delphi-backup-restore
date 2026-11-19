unit Core.SystemUtils;

interface

function IsRunningAsAdmin: Boolean;
function IsDelphiIdeRunning(out AProcessNames: string): Boolean;
function ExpandEnvVars(const AText: string): string;
function GetUserProfileDir: string;
function GetPublicDir: string;
function GetAppDataDir: string;
function GetDocumentsDir: string;
function GetSystem32Dir: string;
function GetSysWow64Dir: string;
function GetFileVersionText(const AFileName: string): string;
function GetFileCompany(const AFileName: string): string;
function CompareVersionText(const A, B: string): Integer;
function NormalizePath(const APath: string): string;
function IsPathInside(const APath, AParent: string): Boolean;
function GetUserPathEnv: string;
procedure SetUserPathEnv(const AValue: string);
function ToolVersion: string;
function MachineName: string;

implementation

uses
  System.SysUtils, System.Classes, System.Win.Registry, Winapi.Windows,
  Winapi.ShlObj, Winapi.TlHelp32;

function GetSystemWow64Directory(lpBuffer: PWideChar; uSize: UINT): UINT;
  stdcall; external kernel32 name 'GetSystemWow64DirectoryW';

const
  WM_SETTINGCHANGE_MESSAGE = $001A;

function IsRunningAsAdmin: Boolean;
var
  Token: THandle;
  Elevation: TOKEN_ELEVATION;
  Returned: DWORD;
begin
  Result := False;
  Token := 0;
  if OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, Token) then
    try
      if GetTokenInformation(Token, TokenElevation, @Elevation,
        SizeOf(Elevation), Returned) then
        Result := Elevation.TokenIsElevated <> 0;
    finally
      CloseHandle(Token);
    end;
end;

function IsDelphiIdeRunning(out AProcessNames: string): Boolean;
var
  Snapshot: THandle;
  Entry: TProcessEntry32;
begin
  AProcessNames := '';
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    Entry.dwSize := SizeOf(Entry);
    if Process32First(Snapshot, Entry) then
      repeat
        if SameText(Entry.szExeFile, 'bds.exe') or
          SameText(Entry.szExeFile, 'delphi32.exe') then
        begin
          if AProcessNames <> '' then
            AProcessNames := AProcessNames + ', ';
          AProcessNames := AProcessNames + string(Entry.szExeFile);
        end;
        Entry.dwSize := SizeOf(Entry);
      until not Process32Next(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
  Result := AProcessNames <> '';
end;

function ExpandEnvVars(const AText: string): string;
var
  Needed: DWORD;
begin
  Needed := ExpandEnvironmentStrings(PChar(AText), nil, 0);
  if Needed = 0 then
    RaiseLastOSError;
  SetLength(Result, Needed - 1);
  if Needed > 1 then
    if ExpandEnvironmentStrings(PChar(AText), PChar(Result), Needed) = 0 then
      RaiseLastOSError;
end;

function EnvValue(const AName: string): string;
var
  N: DWORD;
begin
  N := GetEnvironmentVariable(PChar(AName), nil, 0);
  if N = 0 then
    Exit('');
  SetLength(Result, N);
  N := GetEnvironmentVariable(PChar(AName), PChar(Result), N);
  SetLength(Result, N);
end;

function GetUserProfileDir: string;
begin
  Result := ExcludeTrailingPathDelimiter(EnvValue('USERPROFILE'));
end;

function GetPublicDir: string;
begin
  Result := ExcludeTrailingPathDelimiter(EnvValue('PUBLIC'));
end;

function GetAppDataDir: string;
begin
  Result := ExcludeTrailingPathDelimiter(EnvValue('APPDATA'));
end;

function GetDocumentsDir: string;
var
  Buffer: array [0 .. MAX_PATH] of Char;
begin
  FillChar(Buffer, SizeOf(Buffer), 0);
  if SHGetFolderPath(0, CSIDL_PERSONAL, 0, SHGFP_TYPE_CURRENT, Buffer) <> S_OK
  then
    RaiseLastOSError;
  Result := ExcludeTrailingPathDelimiter(string(Buffer));
end;

function GetSystem32Dir: string;
var
  Buffer: array [0 .. MAX_PATH] of Char;
begin
  FillChar(Buffer, SizeOf(Buffer), 0);
  if GetSystemDirectory(Buffer, MAX_PATH) = 0 then
    RaiseLastOSError;
  Result := ExcludeTrailingPathDelimiter(string(Buffer));
end;

function GetSysWow64Dir: string;
var
  Buffer: array [0 .. MAX_PATH] of Char;
begin
  Result := '';
  FillChar(Buffer, SizeOf(Buffer), 0);
  if GetSystemWow64Directory(Buffer, MAX_PATH) = 0 then
    Exit;
  Result := ExcludeTrailingPathDelimiter(string(Buffer));
end;

function VersionValue(const AFileName, AName: string): string;
var
  Size, Handle: DWORD;
  Data: TBytes;
  Value: PChar;
  ValueLen: UINT;
  Translation: PLongInt;
  TransLen: UINT;
  Query: string;
begin
  Result := '';
  Size := GetFileVersionInfoSize(PChar(AFileName), Handle);
  if Size = 0 then
    Exit;
  SetLength(Data, Size);
  if not GetFileVersionInfo(PChar(AFileName), 0, Size, @Data[0]) then
    Exit;
  Translation := nil;
  if VerQueryValue(@Data[0], '\VarFileInfo\Translation', Pointer(Translation),
    TransLen) and (TransLen >= SizeOf(LongInt)) then
    Query := Format('\StringFileInfo\%.4x%.4x\%s',
      [LoWord(Translation^), HiWord(Translation^), AName])
  else
    Query := '\StringFileInfo\040904B0\' + AName;
  Value := nil;
  ValueLen := 0;
  if VerQueryValue(@Data[0], PChar(Query), Pointer(Value), ValueLen) and
    (ValueLen > 0) then
    Result := Trim(string(Value));
end;

function GetFileVersionText(const AFileName: string): string;
var
  Size, Handle: DWORD;
  Data: TBytes;
  Fixed: PVSFixedFileInfo;
  FixedSize: UINT;
begin
  Result := '';
  Size := GetFileVersionInfoSize(PChar(AFileName), Handle);
  if Size = 0 then
    Exit;
  SetLength(Data, Size);
  if not GetFileVersionInfo(PChar(AFileName), 0, Size, @Data[0]) then
    Exit;
  Fixed := nil;
  FixedSize := 0;
  if VerQueryValue(@Data[0], '\', Pointer(Fixed), FixedSize) and
    (FixedSize >= SizeOf(TVSFixedFileInfo)) then
    Result := Format('%d.%d.%d.%d', [HiWord(Fixed.dwFileVersionMS),
      LoWord(Fixed.dwFileVersionMS), HiWord(Fixed.dwFileVersionLS),
      LoWord(Fixed.dwFileVersionLS)]);
end;

function GetFileCompany(const AFileName: string): string;
begin
  Result := VersionValue(AFileName, 'CompanyName');
end;

function VersionParts(const S: string): TArray<Int64>;
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    L.Delimiter := '.';
    L.StrictDelimiter := True;
    L.DelimitedText := S;
    SetLength(Result, L.Count);
    for I := 0 to L.Count - 1 do
      if not TryStrToInt64(Trim(L[I]), Result[I]) then
        Result[I] := 0;
  finally
    L.Free;
  end;
end;

function CompareVersionText(const A, B: string): Integer;
var
  PA, PB: TArray<Int64>;
  I, N: Integer;
  VA, VB: Int64;
begin
  PA := VersionParts(A);
  PB := VersionParts(B);
  N := Length(PA);
  if Length(PB) > N then
    N := Length(PB);
  for I := 0 to N - 1 do
  begin
    VA := 0;
    VB := 0;
    if I < Length(PA) then
      VA := PA[I];
    if I < Length(PB) then
      VB := PB[I];
    if VA < VB then
      Exit(-1);
    if VA > VB then
      Exit(1);
  end;
  Result := 0;
end;

function NormalizePath(const APath: string): string;
begin
  Result := '';
  if Trim(APath) = '' then
    Exit;
  try
    Result := ExpandFileName(APath);
    { keep drive roots as "C:\": a bare "C:" means "current folder of drive C" }
    if not((Length(Result) = 3) and (Result[2] = ':')) then
      Result := ExcludeTrailingPathDelimiter(Result);
    if Result = '' then
      Result := '\';
  except
    Result := '';
  end;
end;

function IsPathInside(const APath, AParent: string): Boolean;
var
  P, R: string;
begin
  { Lexical only: never touches the disk. Empty or invalid input is never inside. }
  Result := False;
  P := NormalizePath(APath);
  R := NormalizePath(AParent);
  if (P = '') or (R = '') then
    Exit;
  P := IncludeTrailingPathDelimiter(P);
  R := IncludeTrailingPathDelimiter(R);
  Result := (Length(P) >= Length(R)) and SameText(Copy(P, 1, Length(R)), R);
end;

function GetUserPathEnv: string;
var
  Reg: TRegistry;
begin
  Result := '';
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKeyReadOnly('Environment') then
      try
        if Reg.ValueExists('Path') then
          Result := Reg.ReadString('Path');
      finally
        Reg.CloseKey;
      end;
  finally
    Reg.Free;
  end;
end;

procedure SetUserPathEnv(const AValue: string);
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_WRITE);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if not Reg.OpenKey('Environment', True) then
      RaiseLastOSError;
    try
      Reg.WriteString('Path', AValue);
    finally
      Reg.CloseKey;
    end;
  finally
    Reg.Free;
  end;
  SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE_MESSAGE, 0,
    LPARAM(PChar('Environment')), SMTO_ABORTIFHUNG, 5000, nil);
end;

function ToolVersion: string;
begin
  Result := VersionValue(ParamStr(0), 'ProductVersion');
  if Result = '' then
    Result := '0.0.0';
end;

function MachineName: string;
var
  Buffer: array [0 .. MAX_COMPUTERNAME_LENGTH] of Char;
  Size: DWORD;
begin
  Size := Length(Buffer);
  if not GetComputerName(Buffer, Size) then
    RaiseLastOSError;
  Result := string(Buffer);
end;

end.
