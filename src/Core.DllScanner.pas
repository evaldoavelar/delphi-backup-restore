unit Core.DllScanner;

interface

uses
  System.Classes, Core.Types;

function CreateDllScanner(const ALogger: ILogger): IDllScanner;
function ReadPeImports(const AFileName: string; AImports: TStrings): Boolean;
function ReadPeMachine(const AFileName: string): Word;

implementation

uses
  Winapi.Windows, System.SysUtils, System.IOUtils, System.StrUtils,
  Core.SystemUtils, Core.Logger;

type
  TPeSection = record
    Rva, RawSize, RawOffset: Cardinal;
  end;

  TPeReader = class
  private
    FStream: TFileStream;
    FSections: TArray<TPeSection>;
    FHeaderSize: Cardinal;
    FImageBase: UInt64;
    FIs64: Boolean;
    FMachine: Word;
    procedure Check(AOffset, ACount: Int64);
    function U16(AOffset: Int64): Word;
    function U32(AOffset: Int64): Cardinal;
    function U64(AOffset: Int64): UInt64;
    function NtHeaderOffset: Int64;
    function MapRva(ARva: Cardinal; out AAvailable: Int64): Int64;
    function ImportName(ARva: Cardinal): string;
    procedure ReadDirectory(ARva, ASize: Cardinal; ADelay: Boolean;
      AImports: TStrings);
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    procedure ReadImports(AImports: TStrings);
  end;

  TDllScanner = class(TInterfacedObject, IDllScanner)
  private
    FLogger: ILogger;
    FCoveredNames: TStringList;
    FFiles: TStringList;
    FSystemDirs: TStringList;
    FSearchDirs: TStringList;
    FVisited: TStringList;
    FResult: TBackupItemList;
    procedure CollectFiles(const ADirectory: string;
      ARecursive, ACovered: Boolean);
    function IsCovered(const AName: string): Boolean;
    function ResolveImport(const AName, AParentFile: string;
      AIs64: Boolean): string;
    procedure AddDll(const AFileName: string; AOrigin: TDllOrigin);
    procedure InspectDependencies(const AFileName: string);
    procedure ScanSystemDirectory(const ADirectory: string);
  public
    constructor Create(const ALogger: ILogger);
    destructor Destroy; override;
    procedure Scan(AVersions: TDelphiVersionList; ACovered: TBackupItemList;
      AResult: TBackupItemList);
  end;

function DisableWow64Redirection(out AOldValue: Pointer): BOOL; stdcall;
  external 'kernel32.dll' name 'Wow64DisableWow64FsRedirection';

function RevertWow64Redirection(AOldValue: Pointer): BOOL; stdcall;
  external 'kernel32.dll' name 'Wow64RevertWow64FsRedirection';

function BeginNativeFileCall(const APath: string; out APhysicalPath: string;
  out AOldValue: Pointer): Boolean;
begin
  APhysicalPath := RealFileSystemPath(APath);
  Result := not SameText(APath, APhysicalPath) and
    DisableWow64Redirection(AOldValue);
  if Result then
    APhysicalPath := APath;
end;

function NativeFileExists(const APath: string): Boolean;
var
  PhysicalPath: string;
  OldValue: Pointer;
  Disabled: Boolean;
begin
  Disabled := BeginNativeFileCall(APath, PhysicalPath, OldValue);
  try
    Result := FileExists(PhysicalPath);
  finally
    if Disabled then
      RevertWow64Redirection(OldValue);
  end;
end;

function NativeFindFirst(const ADirectory: string;
  out ASearch: TSearchRec): Integer;
var
  PhysicalPath: string;
  OldValue: Pointer;
  Disabled: Boolean;
begin
  Disabled := BeginNativeFileCall(ADirectory, PhysicalPath, OldValue);
  try
    Result := FindFirst(IncludeTrailingPathDelimiter(PhysicalPath) + '*',
      faAnyFile, ASearch);
  finally
    if Disabled then
      RevertWow64Redirection(OldValue);
  end;
end;

constructor TPeReader.Create(const AFileName: string);
var
  PhysicalPath: string;
  OldValue: Pointer;
  Disabled: Boolean;
begin
  inherited Create;
  Disabled := BeginNativeFileCall(AFileName, PhysicalPath, OldValue);
  try
    FStream := TFileStream.Create(PhysicalPath, fmOpenRead or fmShareDenyNone);
  finally
    if Disabled then
      RevertWow64Redirection(OldValue);
  end;
end;

destructor TPeReader.Destroy;
begin
  FStream.Free;
  inherited;
end;

procedure TPeReader.Check(AOffset, ACount: Int64);
begin
  if (AOffset < 0) or (ACount < 0) or (AOffset > FStream.Size) or
    (ACount > FStream.Size - AOffset) then
    raise EReadError.Create('Estrutura PE fora dos limites do arquivo.');
end;

function TPeReader.U16(AOffset: Int64): Word;
begin
  Check(AOffset, SizeOf(Result));
  FStream.Position := AOffset;
  FStream.ReadBuffer(Result, SizeOf(Result));
end;

function TPeReader.U32(AOffset: Int64): Cardinal;
begin
  Check(AOffset, SizeOf(Result));
  FStream.Position := AOffset;
  FStream.ReadBuffer(Result, SizeOf(Result));
end;

function TPeReader.U64(AOffset: Int64): UInt64;
begin
  Check(AOffset, SizeOf(Result));
  FStream.Position := AOffset;
  FStream.ReadBuffer(Result, SizeOf(Result));
end;

function TPeReader.MapRva(ARva: Cardinal; out AAvailable: Int64): Int64;
var
  S: TPeSection;
  Delta: Int64;
begin
  if ARva < FHeaderSize then
  begin
    AAvailable := Int64(FHeaderSize) - ARva;
    Exit(ARva);
  end;
  for S in FSections do
  begin
    Delta := Int64(ARva) - S.Rva;
    if (Delta >= 0) and (Delta < S.RawSize) then
    begin
      AAvailable := Int64(S.RawSize) - Delta;
      Exit(Int64(S.RawOffset) + Delta);
    end;
  end;
  raise EReadError.Create
    ('RVA do PE não corresponde a dados presentes no arquivo.');
end;

function TPeReader.ImportName(ARva: Cardinal): string;
var
  Available: Int64;
  I: Integer;
  B: Byte;
begin
  Result := '';
  FStream.Position := MapRva(ARva, Available);
  if Available > 4096 then
    Available := 4096;
  for I := 1 to Integer(Available) do
  begin
    FStream.ReadBuffer(B, 1);
    if B = 0 then
    begin
      if Result = '' then
        raise EReadError.Create('Nome de importação vazio.');
      Exit;
    end;
    if (B < 32) or (B = 127) then
      raise EReadError.Create('Nome de importação inválido.');
    Result := Result + Char(B);
  end;
  raise EReadError.Create('Nome de importação sem terminador.');
end;

procedure TPeReader.ReadDirectory(ARva, ASize: Cardinal; ADelay: Boolean;
  AImports: TStrings);
var
  Step, Position, NameRva, Attrs: Cardinal;
  Offset, Available: Int64;
  I: Integer;
  Zero: Boolean;
  VA: UInt64;
  Name: string;
begin
  if ARva = 0 then
    Exit;
  Step := 20;
  if ADelay then
    Step := 32;
  if (ASize < Step) or (UInt64(ARva) + ASize > UInt64(High(Cardinal)) + 1) then
    raise EReadError.Create('Tamanho inválido do diretório de importações.');
  Offset := MapRva(ARva, Available);
  if Available > ASize then
    Available := ASize;
  Position := 0;
  while (Int64(Position) + Step <= Available) and (Position div Step < 65536) do
  begin
    Zero := True;
    for I := 0 to (Step div 4) - 1 do
      if U32(Offset + I * 4) <> 0 then
        Zero := False;
    if Zero then
      Exit;
    if ADelay then
    begin
      Attrs := U32(Offset);
      NameRva := U32(Offset + 4);
      if (Attrs and 1) = 0 then
      begin
        VA := NameRva;
        if (VA < FImageBase) or (VA - FImageBase > High(Cardinal)) then
          raise EReadError.Create
            ('Endereço virtual inválido no diretório delay-load.');
        NameRva := Cardinal(VA - FImageBase);
      end;
    end
    else
      NameRva := U32(Offset + 12);
    if NameRva = 0 then
      raise EReadError.Create('Importação sem nome de DLL.');
    Name := ImportName(NameRva);
    if (AImports <> nil) and (AImports.IndexOf(Name) < 0) then
      AImports.Add(Name);
    Inc(Position, Step);
    Inc(Offset, Step);
  end;
  raise EReadError.Create('Diretório de importações sem descritor terminador.');
end;

function TPeReader.NtHeaderOffset: Int64;
begin
  if U16(0) <> $5A4D then
    raise EReadError.Create('Assinatura DOS inválida.');
  Result := U32($3C);
  if Result < $40 then
    raise EReadError.Create('Deslocamento de cabeçalho PE inválido.');
  if U32(Result) <> $00004550 then
    raise EReadError.Create('Assinatura PE inválida.');
  Check(Result, 24);
end;

procedure TPeReader.ReadImports(AImports: TStrings);
var
  Nt, Optional, Sections, Dirs: Int64;
  Count, OptionalSize, Magic: Word;
  NumberDirs, ImportRva, ImportSize, DelayRva, DelaySize: Cardinal;
  I: Integer;
begin
  Nt := NtHeaderOffset;
  FMachine := U16(Nt + 4);
  Count := U16(Nt + 6);
  if (Count = 0) or (Count > 4096) then
    raise EReadError.Create('Número de seções PE inválido.');
  OptionalSize := U16(Nt + 20);
  Optional := Nt + 24;
  Check(Optional, OptionalSize);
  Magic := U16(Optional);
  FIs64 := Magic = $20B;
  if Magic = $10B then
  begin
    if OptionalSize < 96 then
      raise EReadError.Create('Cabeçalho PE32 incompleto.');
    FImageBase := U32(Optional + 28);
    NumberDirs := U32(Optional + 92);
    Dirs := Optional + 96;
  end
  else if Magic = $20B then
  begin
    if OptionalSize < 112 then
      raise EReadError.Create('Cabeçalho PE32+ incompleto.');
    FImageBase := U64(Optional + 24);
    NumberDirs := U32(Optional + 108);
    Dirs := Optional + 112;
  end
  else
    raise EReadError.Create('Formato de cabeçalho PE desconhecido.');
  if UInt64(NumberDirs) * 8 > UInt64(Optional + OptionalSize - Dirs) then
    raise EReadError.Create('Diretórios PE excedem o cabeçalho opcional.');
  FHeaderSize := U32(Optional + 60);
  if FHeaderSize > FStream.Size then
    raise EReadError.Create('Cabeçalhos PE truncados.');
  Sections := Optional + OptionalSize;
  Check(Sections, Int64(Count) * 40);
  SetLength(FSections, Count);
  for I := 0 to Count - 1 do
  begin
    FSections[I].Rva := U32(Sections + I * 40 + 12);
    FSections[I].RawSize := U32(Sections + I * 40 + 16);
    FSections[I].RawOffset := U32(Sections + I * 40 + 20);
    Check(FSections[I].RawOffset, FSections[I].RawSize);
  end;
  ImportRva := 0;
  ImportSize := 0;
  DelayRva := 0;
  DelaySize := 0;
  if NumberDirs > 1 then
  begin
    ImportRva := U32(Dirs + 8);
    ImportSize := U32(Dirs + 12);
  end;
  if NumberDirs > 13 then
  begin
    DelayRva := U32(Dirs + 13 * 8);
    DelaySize := U32(Dirs + 13 * 8 + 4);
  end;
  ReadDirectory(ImportRva, ImportSize, False, AImports);
  ReadDirectory(DelayRva, DelaySize, True, AImports);
end;

function ReadPeImportsLogged(const AFileName: string; AImports: TStrings;
  const ALogger: ILogger; out AIs64: Boolean): Boolean;
var
  Reader: TPeReader;
  Names: TStringList;
begin
  Result := False;
  AIs64 := False;
  ALogger.Debug('Lendo importações PE: ' + AFileName);
  Reader := nil;
  Names := TStringList.Create;
  try
    try
      if AImports = nil then
        raise EArgumentNilException.Create('AImports');
      AImports.Clear;
      Reader := TPeReader.Create(AFileName);
      Reader.ReadImports(Names);
      AIs64 := Reader.FIs64;
      AImports.Assign(Names);
      ALogger.Debug(Format('Importações PE lidas: %d em %s.',
        [Names.Count, AFileName]));
      Result := True;
    except
      on E: Exception do
        ALogger.Warn('Não foi possível ler importações PE de ' + AFileName +
          ': ' + E.Message);
    end;
  finally
    Reader.Free;
    Names.Free;
  end;
end;

function ReadPeImports(const AFileName: string; AImports: TStrings): Boolean;
var
  Is64: Boolean;
begin
  Result := ReadPeImportsLogged(AFileName, AImports, CreateLogger, Is64);
end;

function ReadPeMachine(const AFileName: string): Word;
var
  Reader: TPeReader;
  L: ILogger;
begin
  L := CreateLogger;
  L.Debug('Lendo arquitetura PE: ' + AFileName);
  Result := 0;
  try
    Reader := TPeReader.Create(AFileName);
    try
      Reader.ReadImports(nil);
      Result := Reader.FMachine;
      L.Debug('Arquitetura PE: ' + IntToHex(Result, 4));
    finally
      Reader.Free;
    end;
  except
    on E: Exception do
      L.Warn('Não foi possível ler a arquitetura PE de ' + AFileName + ': ' +
        E.Message);
  end;
end;

function CreateDllScanner(const ALogger: ILogger): IDllScanner;
var
  L: ILogger;
begin
  L := ALogger;
  if L = nil then
    L := CreateLogger;
  L.Debug('Criando scanner de DLLs.');
  Result := TDllScanner.Create(L);
  L.Debug('Scanner de DLLs criado.');
end;

function NewNameList: TStringList;
begin
  Result := TStringList.Create;
  Result.CaseSensitive := False;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
end;

constructor TDllScanner.Create(const ALogger: ILogger);
begin
  inherited Create;
  FLogger := ALogger;
  FLogger.Debug('Inicializando scanner de DLLs.');
  FCoveredNames := NewNameList;
  FFiles := NewNameList;
  FFiles.Sorted := False;
  FSystemDirs := NewNameList;
  FSearchDirs := NewNameList;
  FVisited := NewNameList;
end;

destructor TDllScanner.Destroy;
begin
  if FLogger <> nil then
    FLogger.Debug('Liberando scanner de DLLs.');
  FVisited.Free;
  FSearchDirs.Free;
  FSystemDirs.Free;
  FFiles.Free;
  FCoveredNames.Free;
  inherited;
end;

procedure TDllScanner.CollectFiles(const ADirectory: string;
  ARecursive, ACovered: Boolean);
var
  Search: TSearchRec;
  Path, Ext: string;
  Code: Integer;
begin
  if not DirectoryExists(RealFileSystemPath(ADirectory)) then
    Exit;
  Code := NativeFindFirst(ADirectory, Search);
  if Code <> 0 then
  begin
    if Code <> ERROR_FILE_NOT_FOUND then
      FLogger.Warn('Não foi possível listar pasta: ' + ADirectory + ': ' +
        SysErrorMessage(Code));
    Exit;
  end;
  try
    repeat
      if (Search.Name <> '.') and (Search.Name <> '..') then
      begin
        Path := TPath.Combine(ADirectory, Search.Name);
        if (Search.Attr and faDirectory) <> 0 then
        begin
          if ARecursive and
            ((Search.FindData.dwFileAttributes and
            FILE_ATTRIBUTE_REPARSE_POINT) = 0) then
            CollectFiles(Path, True, ACovered);
        end
        else
        begin
          Ext := ExtractFileExt(Search.Name);
          if SameText(Ext, '.dll') or SameText(Ext, '.bpl') then
          begin
            FFiles.Add(Path);
            if ACovered then
              FCoveredNames.Add(Search.Name);
          end;
        end;
      end;
      Code := FindNext(Search);
    until Code <> 0;
    if Code <> ERROR_NO_MORE_FILES then
      FLogger.Warn('Listagem incompleta de ' + ADirectory + ': ' +
        SysErrorMessage(Code));
  finally
    System.SysUtils.FindClose(Search);
  end;
end;

function TDllScanner.IsCovered(const AName: string): Boolean;
begin
  Result := StartsText('api-ms-', AName) or StartsText('ext-ms-', AName) or
    (FCoveredNames.IndexOf(AName) >= 0);
end;

function TDllScanner.ResolveImport(const AName, AParentFile: string;
  AIs64: Boolean): string;
var
  Dir, Candidate: string;
begin
  Result := '';
  { A PE name must never turn into an arbitrary absolute or traversal path. }
  if (ExtractFileName(AName) <> AName) or (Pos(':', AName) > 0) or
    (Pos('/', AName) > 0) or (AName = '.') or (AName = '..') then
    Exit;
  Candidate := TPath.Combine(ExtractFileDir(AParentFile), AName);
  if NativeFileExists(Candidate) then
    Exit(Candidate);
  Dir := GetSystem32Dir;
  if not AIs64 and (GetSysWow64Dir <> '') then
    Dir := GetSysWow64Dir;
  Candidate := TPath.Combine(Dir, AName);
  if NativeFileExists(Candidate) then
    Exit(Candidate);
  for Dir in FSearchDirs do
  begin
    if FSystemDirs.IndexOf(ExcludeTrailingPathDelimiter(Dir)) >= 0 then
      Continue;
    Candidate := TPath.Combine(Dir, AName);
    if NativeFileExists(Candidate) then
      Exit(Candidate);
  end;
end;

procedure TDllScanner.AddDll(const AFileName: string; AOrigin: TDllOrigin);
var
  Company, Lower: string;
  Item: TBackupItem;
begin
  try
    Item := FResult.FindBySource(ikDll, AFileName);
    if Item <> nil then
    begin
      if AOrigin = doDependency then
        Item.DllOrigin := doDependency;
      Exit;
    end;
    Company := Trim(GetFileCompany(RealFileSystemPath(AFileName)));
    Lower := LowerCase(Company);
    if (Pos('microsoft', Lower) > 0) and
      (FSystemDirs.IndexOf(ExcludeTrailingPathDelimiter
      (ExtractFileDir(AFileName))) >= 0) then
      Exit;
    if (AOrigin = doSystemScan) and (Company = '') then
      Exit;
    Item := TBackupItem.Create;
    try
      Item.Id := FResult.NextId(ikDll);
      Item.Kind := ikDll;
      Item.Category := icSystemDll;
      Item.SourcePath := AFileName;
      Item.Selected := False;
      Item.Description := 'DLL de terceiros: ' + ExtractFileName(AFileName);
      Item.Company := Company;
      Item.FileVersion := GetFileVersionText(RealFileSystemPath(AFileName));
      Item.DllOrigin := AOrigin;
      Item.ReinstalledByIde := (Pos('borland', Lower) > 0) or
        (Pos('codegear', Lower) > 0) or (Pos('embarcadero', Lower) > 0);
      FResult.Add(Item);
    except
      Item.Free;
      raise;
    end;
    FLogger.Info('DLL encontrada: ' + AFileName + ' (' + Company + ').');
  except
    on E: Exception do
      FLogger.Warn('Falha ao examinar DLL ' + AFileName + ': ' + E.Message);
  end;
end;

procedure TDllScanner.InspectDependencies(const AFileName: string);
var
  Imports: TStringList;
  Name, Resolved, Company: string;
  Is64: Boolean;
begin
  if FVisited.IndexOf(AFileName) >= 0 then
    Exit;
  FVisited.Add(AFileName);
  Imports := TStringList.Create;
  try
    if not ReadPeImportsLogged(AFileName, Imports, FLogger, Is64) then
      Exit;
    for Name in Imports do
    begin
      if IsCovered(Name) then
        Continue;
      Resolved := ResolveImport(Name, AFileName, Is64);
      if Resolved = '' then
      begin
        FLogger.Warn('Dependência não localizada: ' + Name + ' (importada por '
          + AFileName + ').');
        Continue;
      end;
      Company := GetFileCompany(RealFileSystemPath(Resolved));
      if System.StrUtils.ContainsText(Company, 'Microsoft') and
        (FSystemDirs.IndexOf(ExcludeTrailingPathDelimiter
        (ExtractFileDir(Resolved))) >= 0) then
        Continue;
      AddDll(Resolved, doDependency);
      { Queue instead of recursively following untrusted chains of imports. }
      if FFiles.IndexOf(Resolved) < 0 then
        FFiles.Add(Resolved);
    end;
  finally
    Imports.Free;
  end;
end;

procedure TDllScanner.ScanSystemDirectory(const ADirectory: string);
var
  Search: TSearchRec;
  Code: Integer;
  Ext: string;
begin
  if not DirectoryExists(RealFileSystemPath(ADirectory)) then
    Exit;
  FLogger.Info('Procurando DLLs de terceiros em ' + ADirectory);
  Code := NativeFindFirst(ADirectory, Search);
  if Code <> 0 then
  begin
    FLogger.Warn('Não foi possível listar pasta de sistema: ' + ADirectory +
      ': ' + SysErrorMessage(Code));
    Exit;
  end;
  try
    repeat
      if (Search.Attr and faDirectory) = 0 then
      begin
        Ext := ExtractFileExt(Search.Name);
        if SameText(Ext, '.dll') or SameText(Ext, '.bpl') then
          AddDll(TPath.Combine(ADirectory, Search.Name), doSystemScan);
      end;
      Code := FindNext(Search);
    until Code <> 0;
    if Code <> ERROR_NO_MORE_FILES then
      FLogger.Warn('Listagem incompleta de ' + ADirectory + ': ' +
        SysErrorMessage(Code));
  finally
    System.SysUtils.FindClose(Search);
  end;
end;

procedure TDllScanner.Scan(AVersions: TDelphiVersionList;
  ACovered: TBackupItemList; AResult: TBackupItemList);
var
  Item: TBackupItem;
  V: TDelphiVersion;
  Dir, PathEntry, FileName: string;
  Paths: TStringList;
  I: Integer;
begin
  FLogger.Info('Iniciando varredura de DLLs (somente leitura).');
  try
    try
      if AResult = nil then
        raise EArgumentNilException.Create('AResult');
      FResult := AResult;
      FCoveredNames.Clear;
      FFiles.Clear;
      FSystemDirs.Clear;
      FSearchDirs.Clear;
      FVisited.Clear;
      Dir := GetSystem32Dir;
      if Dir <> '' then
        FSystemDirs.Add(Dir);
      Dir := GetSysWow64Dir;
      if Dir <> '' then
        FSystemDirs.Add(Dir);
      for Dir in FSystemDirs do
        FSearchDirs.Add(Dir);
      Paths := TStringList.Create;
      try
        Paths.StrictDelimiter := True;
        Paths.Delimiter := ';';
        Paths.QuoteChar := #0;
        Paths.DelimitedText := GetEnvironmentVariable('PATH');
        for PathEntry in Paths do
        begin
          Dir := ExpandEnvVars(StringReplace(Trim(PathEntry), '"', '',
            [rfReplaceAll]));
          if (Dir <> '') and DirectoryExists(RealFileSystemPath(Dir)) then
            FSearchDirs.Add(Dir);
        end;
      finally
        Paths.Free;
      end;
      if ACovered <> nil then
        for Item in ACovered do
          try
            case Item.Kind of
              ikFolder:
                CollectFiles(Item.SourcePath, True, True);
              ikFile:
                if NativeFileExists(Item.SourcePath) then
                begin
                  FFiles.Add(Item.SourcePath);
                  FCoveredNames.Add(ExtractFileName(Item.SourcePath));
                  FSearchDirs.Add(ExtractFileDir(Item.SourcePath));
                end;
            end;
          except
            on E: Exception do
              FLogger.Warn('Falha ao examinar item ' + Item.SourcePath + ': ' +
                E.Message);
          end;
      if AVersions <> nil then
        for V in AVersions do
        begin
          CollectFiles(TPath.Combine(V.RootDir, 'bin'), False, True);
          CollectFiles(TPath.Combine(V.RootDir, 'bin64'), False, True);
          FSearchDirs.Add(TPath.Combine(V.RootDir, 'bin'));
          FSearchDirs.Add(TPath.Combine(V.RootDir, 'bin64'));
        end;
      { Dependency inspection upgrades matching system-scan items to doDependency. }
      for Dir in FSystemDirs do
        ScanSystemDirectory(Dir);
      I := 0;
      while I < FFiles.Count do
      begin
        FileName := FFiles[I];
        try
          InspectDependencies(FileName);
        except
          on E: Exception do
            FLogger.Warn('Falha ao analisar dependências de ' + FileName + ': '
              + E.Message);
        end;
        Inc(I);
      end;
      FLogger.Info
        (Format('Varredura concluída: %d DLLs disponíveis para seleção.',
        [AResult.Count]));
    except
      on E: Exception do
        FLogger.Error('Falha na varredura de DLLs: ' + E.Message);
    end;
  finally
    FResult := nil;
  end;
end;

end.
