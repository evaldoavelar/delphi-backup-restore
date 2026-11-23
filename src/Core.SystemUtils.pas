unit Core.SystemUtils;

interface

uses System.Classes, System.Win.Registry;

function IsRunningAsAdmin: Boolean;
function IsDelphiIdeRunning(out AProcessNames: string): Boolean;
function ExpandEnvVars(const AText: string): string;
function GetUserProfileDir: string;
function GetPublicDir: string;
function GetAppDataDir: string;
function GetDocumentsDir: string;
function GetSystem32Dir: string;
function GetSysWow64Dir: string;
function RealFileSystemPath(const APath: string): string;
function GetFileVersionText(const AFileName: string): string;
function GetFileCompany(const AFileName: string): string;
function CompareVersionText(const A, B: string): Integer;
function IsAbsoluteFileSystemPath(const APath: string): Boolean;
function PathHasReparsePoint(const APath: string): Boolean;
function NormalizePath(const APath: string): string;
function IsPathInside(const APath, AParent: string): Boolean;
function GetUserPathEnv: string;
procedure SetUserPathEnv(const AValue: string);
procedure WritePathValue(ARegistry: TRegistry; const AValue: string);
function ToolVersion: string;
function MachineName: string;
{ Number of files below AFolder (recursive, long paths supported, reparse points
  not followed). -1 when the folder cannot be read. }
function CountFilesInTree(const AFolder: string): Integer;
function ListFilesInTree(const AFolder: string; AFiles: TStrings): Boolean;
function CreateTempDirectory(const APrefix: string): string;
{ Deletes AFolder and everything below it (long paths supported). True when the
  folder no longer exists afterwards. }
function DeleteTree(const AFolder: string): Boolean;

implementation

uses
  System.SysUtils, System.IOUtils, Winapi.Windows, Winapi.ShlObj,
  Winapi.TlHelp32, Core.Types, Core.Logger;

function GetSystemWow64Directory(lpBuffer: PWideChar; uSize: UINT): UINT;
  stdcall; external kernel32 name 'GetSystemWow64DirectoryW';

function QueryTokenInformation(AToken: THandle; AClass: Longint;
  AInformation: Pointer; ALength: DWORD; out AReturned: DWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'GetTokenInformation';

function QueryWow64Process(AProcess: THandle; out AIsWow64: BOOL): BOOL;
  stdcall; external 'kernel32.dll' name 'IsWow64Process';

type
  TLocalTokenElevation = record
    TokenIsElevated: DWORD;
  end;

const
  TOKEN_ELEVATION_CLASS = 20;
  WM_SETTINGCHANGE_MESSAGE = $001A;

function IsRunningAsAdmin: Boolean;
var
  Token: THandle;
  Elevation: TLocalTokenElevation;
  Returned: DWORD;
begin
  Result := False;
  Token := 0;
  if OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, Token) then
    try
      if QueryTokenInformation(Token, TOKEN_ELEVATION_CLASS, @Elevation,
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

function RealFileSystemPath(const APath: string): string;
var
  IsWow: BOOL;
  NativeDir, P: string;
  L: ILogger;
begin
  L := CreateLogger;
  L.Debug('Resolvendo caminho para acesso ao sistema de arquivos: ' + APath);
  Result := APath;
  if not QueryWow64Process(GetCurrentProcess, IsWow) then
    RaiseLastOSError;
  if not IsWow or not IsAbsoluteFileSystemPath(APath) then
    Exit;
  NativeDir := GetSystem32Dir;
  P := NormalizePath(StringReplace(APath, '/', '\', [rfReplaceAll]));
  if IsPathInside(P, NativeDir) then
  begin
    Result := ExtractFileDir(NativeDir) + '\Sysnative' +
      Copy(P, Length(NativeDir) + 1, MaxInt);
    L.Debug('Caminho nativo no WOW64: ' + Result);
  end;
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
    TransLen) and (TransLen >= SizeOf(Longint)) then
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

function IsAbsoluteFileSystemPath(const APath: string): Boolean;
var
  P, Part: string;
  I, Start: Integer;
  IsUnc: Boolean;
begin
  Result := False;
  P := StringReplace(APath, '/', '\', [rfReplaceAll]);
  IsUnc := Copy(P, 1, 2) = '\\';
  if IsUnc then
  begin
    I := Pos('\', Copy(P, 3, MaxInt)) + 2;
    if (I <= 3) or (I >= Length(P)) or (P[I + 1] = '\') then
      Exit;
    Start := 3;
  end
  else
  begin
    if (Length(P) < 3) or not CharInSet(P[1], ['A' .. 'Z', 'a' .. 'z']) or
      (P[2] <> ':') or (P[3] <> '\') then
      Exit;
    Start := 4;
  end;
  for I := Start to Length(P) + 1 do
  begin
    if (I <= Length(P)) and CharInSet(P[I], [#0 .. #31, ':', '*', '?', '"', '<',
      '>', '|']) then
      Exit;
    if (I > Length(P)) or (P[I] = '\') then
    begin
      Part := Copy(P, Start, I - Start);
      if ((Part = '') and (I <= Length(P))) or (Part = '.') or (Part = '..')
      then
        Exit;
      if (Part <> '') and CharInSet(Part[Length(Part)], [' ', '.']) then
        Exit;
      Start := I + 1;
    end;
  end;
  Result := True;
end;

function LongPathName(const APath: string): string;
var
  Buffer: array [0 .. 32767] of Char;
  Len: DWORD;
begin
  Len := GetLongPathName(PChar(APath), Buffer, Length(Buffer));
  if (Len > 0) and (Len < DWORD(Length(Buffer))) then
    SetString(Result, Buffer, Len)
  else
    Result := APath;
end;

function NormalizePath(const APath: string): string;
begin
  Result := '';
  if Trim(APath) = '' then
    Exit;
  try
    Result := ExpandFileName(APath);
    { resolve 8.3 aliases ("PROGRA~2") of existing paths, so an alias never escapes
      a comparison against the long name }
    if (Pos('~', Result) > 0) and (FileExists(Result) or DirectoryExists(Result))
    then
      Result := LongPathName(Result);
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

procedure WritePathValue(ARegistry: TRegistry; const AValue: string);
var
  L: ILogger;
begin
  L := CreateLogger;
  L.Debug('Gravando valor Path no registro.');
  if (Pos('%', AValue) > 0) or (ARegistry.ValueExists('Path') and
    (ARegistry.GetDataType('Path') = rdExpandString)) then
    ARegistry.WriteExpandString('Path', AValue)
  else
    ARegistry.WriteString('Path', AValue);
  L.Debug('Valor Path gravado.');
end;

procedure SetUserPathEnv(const AValue: string);
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_QUERY_VALUE or KEY_SET_VALUE);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if not Reg.OpenKey('Environment', True) then
      RaiseLastOSError;
    try
      WritePathValue(Reg, AValue);
    finally
      Reg.CloseKey;
    end;
  finally
    Reg.Free;
  end;
  SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE_MESSAGE, 0,
    LPARAM(PChar('Environment')), SMTO_ABORTIFHUNG, 5000, nil);
end;

function LongPathPrefix(const APath: string): string;
begin
  if Copy(APath, 1, 4) = '\\?\' then
    Result := APath
  else if Copy(APath, 1, 2) = '\\' then
    Result := '\\?\UNC\' + Copy(APath, 3, MaxInt)
  else
    Result := '\\?\' + APath;
end;

function PathHasReparsePoint(const APath: string): Boolean;
var
  P, Parent: string;
  Attr, Err: DWORD;
begin
  P := NormalizePath(StringReplace(APath, '/', '\', [rfReplaceAll]));
  while P <> '' do
  begin
    Attr := GetFileAttributesW(PChar(LongPathPrefix(P)));
    if Attr <> INVALID_FILE_ATTRIBUTES then
    begin
      if (Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
        Exit(True);
    end
    else
    begin
      Err := GetLastError;
      if (Err <> ERROR_FILE_NOT_FOUND) and (Err <> ERROR_PATH_NOT_FOUND) and
        (Err <> ERROR_BAD_NETPATH) and (Err <> ERROR_BAD_NET_NAME) and
        (Err <> ERROR_BAD_PATHNAME) then
        Exit(True);
    end;
    Parent := ExcludeTrailingPathDelimiter(ExtractFilePath(P));
    if (Parent = P) or ((Length(Parent) = 2) and (Parent[2] = ':')) or
      (Copy(Parent, 1, 2) = '\\') and (Pos('\', Copy(Parent, 3, MaxInt)) = 0)
    then
      Break;
    P := Parent;
  end;
  Result := False;
end;

function CountFilesInTreeLong(const ALongDir, ARelDir: string;
  AFiles: TStrings): Integer;
var
  Find: TWin32FindData;
  H: THandle;
  Name: string;
  Sub: Integer;
begin
  Result := 0;
  H := FindFirstFile(PChar(IncludeTrailingPathDelimiter(ALongDir) + '*'), Find);
  if H = INVALID_HANDLE_VALUE then
  begin
    if GetLastError = ERROR_FILE_NOT_FOUND then
      Exit(0);
    Exit(-1);
  end;
  try
    repeat
      Name := Find.cFileName;
      if (Name <> '.') and (Name <> '..') then
      begin
        if (Find.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
        begin
          if AFiles <> nil then
            Exit(-1);
          if (Find.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) = 0 then
            Inc(Result);
        end
        else if (Find.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
        begin
          Sub := CountFilesInTreeLong(IncludeTrailingPathDelimiter(ALongDir) +
            Name, ARelDir + Name + '\', AFiles);
          if Sub < 0 then
            Exit(-1);
          Inc(Result, Sub);
        end
        else
        begin
          Inc(Result);
          if AFiles <> nil then
            AFiles.Add(ARelDir + Name);
        end;
      end;
      if not FindNextFile(H, Find) then
      begin
        if GetLastError <> ERROR_NO_MORE_FILES then
          Exit(-1);
        Break;
      end;
    until False;
  finally
    Winapi.Windows.FindClose(H);
  end;
end;

function CountFilesInTree(const AFolder: string): Integer;
var
  P: string;
begin
  P := NormalizePath(AFolder);
  if (P = '') or not DirectoryExists(P) then
    Exit(-1);
  Result := CountFilesInTreeLong(LongPathPrefix(P), '', nil);
end;

function ListFilesInTree(const AFolder: string; AFiles: TStrings): Boolean;
var
  L: ILogger;
begin
  L := CreateLogger;
  L.Debug('Listando nomes dos arquivos em ' + AFolder);
  AFiles.Clear;
  Result := IsAbsoluteFileSystemPath(AFolder) and
    not PathHasReparsePoint(AFolder) and
    (CountFilesInTreeLong(LongPathPrefix(NormalizePath(AFolder)), '',
    AFiles) >= 0);
  if Result then
    L.Debug(Format('%d nomes de arquivos encontrados.', [AFiles.Count]))
  else
  begin
    AFiles.Clear;
    L.Warn('Não foi possível listar os arquivos em ' + AFolder);
  end;
end;

function CreateTempDirectory(const APrefix: string): string;
var
  G: TGUID;
  Bases: array [0 .. 2] of string;
  Base, Name: string;
  I: Integer;
  Err: DWORD;
  L: ILogger;
begin
  L := CreateLogger;
  L.Debug('Criando pasta temporária.');
  if CreateGUID(G) <> S_OK then
    raise EDelphiBackupError.Create
      ('Não foi possível gerar um nome temporário.');
  Name := APrefix + GUIDToString(G);
  { %TEMP% may be empty or point to a missing folder (sandboxes, broken
    profiles): fall back to %LOCALAPPDATA%\Temp, then to <exe>\temp. }
  Bases[0] := TPath.GetTempPath;
  Bases[1] := EnvValue('LOCALAPPDATA');
  if Bases[1] <> '' then
    Bases[1] := TPath.Combine(Bases[1], 'Temp');
  Bases[2] := TPath.Combine(ExtractFilePath(ParamStr(0)), 'temp');
  Err := ERROR_PATH_NOT_FOUND;
  for I := Low(Bases) to High(Bases) do
  begin
    Base := Bases[I];
    if (Base = '') or not IsAbsoluteFileSystemPath
      (ExcludeTrailingPathDelimiter(Base)) then
      Continue;
    if (I = High(Bases)) and not DirectoryExists(Base) then
      ForceDirectories(Base);
    if not DirectoryExists(Base) then
    begin
      L.Warn('Pasta temporária indisponível: ' + Base);
      Continue;
    end;
    Result := TPath.Combine(Base, Name);
    if Winapi.Windows.CreateDirectory(PChar(Result), nil) then
    begin
      L.Debug('Pasta temporária criada: ' + Result);
      Exit;
    end;
    Err := GetLastError;
    L.Warn('Não foi possível criar pasta temporária em ' + Base + ': ' +
      SysErrorMessage(Err));
  end;
  RaiseLastOSError(Err);
end;

procedure DeleteTreeLong(const ALongDir: string);
var
  Find: TWin32FindData;
  H: THandle;
  Name, Full: string;
begin
  H := FindFirstFile(PChar(IncludeTrailingPathDelimiter(ALongDir) + '*'), Find);
  if H <> INVALID_HANDLE_VALUE then
    try
      repeat
        Name := Find.cFileName;
        if (Name = '.') or (Name = '..') then
          Continue;
        Full := IncludeTrailingPathDelimiter(ALongDir) + Name;
        if (Find.dwFileAttributes and FILE_ATTRIBUTE_READONLY <> 0) and
          (Find.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT = 0) then
          SetFileAttributes(PChar(Full), Find.dwFileAttributes and
            not FILE_ATTRIBUTE_READONLY);
        if (Find.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
        begin
          { a reparse point (junction/symlink) is removed, never followed }
          if (Find.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) = 0 then
            DeleteTreeLong(Full);
          Winapi.Windows.RemoveDirectory(PChar(Full));
        end
        else
          Winapi.Windows.DeleteFile(PChar(Full));
      until not FindNextFile(H, Find);
    finally
      Winapi.Windows.FindClose(H);
    end;
  Winapi.Windows.RemoveDirectory(PChar(ExcludeTrailingPathDelimiter(ALongDir)));
end;

function DeleteTree(const AFolder: string): Boolean;
var
  P, LongDir: string;
  Attr, Err: DWORD;
  Attempt, ShareStart: Integer;
  L: ILogger;
begin
  L := CreateLogger;
  L.Debug('Removendo pasta: ' + AFolder);
  Result := False;
  if not IsAbsoluteFileSystemPath(AFolder) then
    Exit;
  P := NormalizePath(StringReplace(AFolder, '/', '\', [rfReplaceAll]));
  if Length(P) <= 3 then
    Exit;
  if Copy(P, 1, 2) = '\\' then
  begin
    ShareStart := Pos('\', Copy(P, 3, MaxInt)) + 3;
    if Pos('\', Copy(P, ShareStart, MaxInt)) = 0 then
      Exit;
  end;
  LongDir := LongPathPrefix(P);
  for Attempt := 1 to 5 do
  begin
    if PathHasReparsePoint(P) then
    begin
      L.Warn('Remoção recusada por ponto de nova análise no caminho: ' + P);
      Exit;
    end;
    Attr := GetFileAttributesW(PChar(LongDir));
    if Attr = INVALID_FILE_ATTRIBUTES then
    begin
      Err := GetLastError;
      Result := (Err = ERROR_FILE_NOT_FOUND) or (Err = ERROR_PATH_NOT_FOUND);
      if Result then
        L.Debug('Pasta removida: ' + P);
      Exit;
    end;
    if (Attr and FILE_ATTRIBUTE_DIRECTORY) = 0 then
      Exit;
    DeleteTreeLong(LongDir);
    if GetFileAttributesW(PChar(LongDir)) = INVALID_FILE_ATTRIBUTES then
    begin
      Err := GetLastError;
      if (Err = ERROR_FILE_NOT_FOUND) or (Err = ERROR_PATH_NOT_FOUND) then
      begin
        L.Debug('Pasta removida: ' + P);
        Exit(True);
      end;
    end;
    if Attempt < 5 then
      Sleep(2000);
  end;
  L.Warn('Não foi possível remover a pasta: ' + P);
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
