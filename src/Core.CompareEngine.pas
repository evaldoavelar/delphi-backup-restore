unit Core.CompareEngine;

interface

uses Core.Types;

type
  TCompareEngine = class
  private
    FLogger: ILogger;
    FRunner: IProcessRunner;
  public
    constructor Create(const ALogger: ILogger; const ARunner: IProcessRunner);
    function Execute(const AOptions: Core.Types.TCompareOptions;
      AInstalled: TDelphiVersionList; AConfig: TToolConfig;
      const AProgress: TProgressProc = nil): TCompareResult;
  end;

function DiffManifests(ABackup, ACurrent: TManifest;
  const AVersions: TArray<string>): TCompareResult;
function TolerantFileSummary(ACount: Integer): string;
function FormatCompareEntry(AEntry: TDiffEntry): string;

implementation

uses System.SysUtils, System.IOUtils, System.Classes, System.DateUtils,
  System.Generics.Collections, System.StrUtils, Core.Manifest, Core.SystemUtils,
  Core.Logger, Core.VersionCatalog, Core.Zip;

type
  TFileIndex = TDictionary<string, TManifestFile>;
  TFileGroups = TObjectDictionary<string, TList<TManifestFile>>;
  TRegistryDetails = TFunc<TManifestItem, string, string>;

function Remap(const P, OldProfile, NewProfile: string): string;
var
  N: Integer;
begin
  Result := P;
  N := Length(ExcludeTrailingPathDelimiter(OldProfile));
  if (N > 0) and SameText(Copy(P, 1, N), Copy(OldProfile, 1, N)) and
    ((Length(P) = N) or (P[N + 1] = '\')) then
    Result := ExcludeTrailingPathDelimiter(NewProfile) + Copy(P, N + 1, MaxInt);
end;

function Applicable(It: TBackupItem; const Versions: TArray<string>): Boolean;
var
  S: string;
begin
  Result := (Length(Versions) = 0) or (It.Versions.Count = 0);
  if Result then
    Exit;
  for S in Versions do
    if It.UsedByVersion(S) then
      Exit(True);
end;

function FindItem(M: TManifest; It: TManifestItem; const Source: string)
  : TManifestItem;
var
  X: TManifestItem;
begin
  Result := nil;
  for X in M.Items do
    if (X.Item.Kind = It.Item.Kind) and
      SameText(ExcludeTrailingPathDelimiter(X.Item.SourcePath),
      ExcludeTrailingPathDelimiter(Source)) then
      Exit(X);
end;

function SameModifiedTime(const A, B: string): Boolean;
var
  LeftTime, RightTime: TDateTime;
begin
  if A = B then
    Exit(True);
  try
    LeftTime := ISO8601ToDate(A);
    RightTime := ISO8601ToDate(B);
  except
    on E: EConvertError do
      Exit(False);
  end;
  Result := MilliSecondsBetween(LeftTime, RightTime) <= 2000;
end;

function SameFileMetadata(A, B: TManifestFile): Boolean;
begin
  Result := (A.Size = B.Size) and SameModifiedTime(A.ModifiedUtc,
    B.ModifiedUtc);
end;

procedure IndexFiles(AItem: TManifestItem; AIndex: TFileIndex;
  AGroups: TFileGroups);
var
  F: TManifestFile;
  Path, Mask: string;
  Group: TList<TManifestFile>;
begin
  for F in AItem.Files do
  begin
    Path := AnsiUpperCase(F.RelPath);
    AIndex.AddOrSetValue(Path, F);
    Mask := MaskNonAscii(F.RelPath);
    if Mask = F.RelPath then
      Continue;
    Mask := UpperCase(Mask);
    if not AGroups.TryGetValue(Mask, Group) then
    begin
      Group := TList<TManifestFile>.Create;
      AGroups.Add(Mask, Group);
    end;
    Group.Add(F);
  end;
end;

function ReplacedByAlias(ACurrent: TManifestFile; const AMask: string;
  ABackupGroups: TFileGroups; ACurrentIndex: TFileIndex): Boolean;
var
  Group: TList<TManifestFile>;
  F: TManifestFile;
begin
  if ABackupGroups.TryGetValue(AMask, Group) then
    for F in Group do
      if not ACurrentIndex.ContainsKey(AnsiUpperCase(F.RelPath)) and
        SameFileMetadata(F, ACurrent) then
        Exit(True);
  Result := False;
end;

procedure CompareFiles(ABackup, ACurrent: TManifestItem; ADiff: TCompareResult);
var
  BackupIndex, CurrentIndex: TFileIndex;
  BackupGroups, CurrentGroups: TFileGroups;
  MatchedAliases: TDictionary<string, Integer>;
  F, G: TManifestFile;
  Mask: string;
  Count: Integer;
begin
  BackupIndex := TFileIndex.Create;
  CurrentIndex := TFileIndex.Create;
  BackupGroups := TFileGroups.Create([doOwnsValues]);
  CurrentGroups := TFileGroups.Create([doOwnsValues]);
  MatchedAliases := TDictionary<string, Integer>.Create;
  try
    IndexFiles(ABackup, BackupIndex, BackupGroups);
    IndexFiles(ACurrent, CurrentIndex, CurrentGroups);
    for F in ABackup.Files do
    begin
      Mask := UpperCase(MaskNonAscii(F.RelPath));
      if CurrentIndex.TryGetValue(AnsiUpperCase(F.RelPath), G) then
      begin
        if SameFileMetadata(F, G) then
          Continue;
        { tar can overwrite the exact name with the contents of a sibling
          whose non-ASCII name collapsed to the same path. }
        if ReplacedByAlias(G, Mask, BackupGroups, CurrentIndex) then
          Inc(ADiff.TolerantFileCount)
        else
          ADiff.Add(dkChanged, ABackup.Item.Id, F.RelPath, 'Arquivo alterado');
      end
      else if CurrentGroups.ContainsKey(Mask) then
      begin
        Inc(ADiff.TolerantFileCount);
        if not MatchedAliases.TryGetValue(Mask, Count) then
          Count := 0;
        MatchedAliases.AddOrSetValue(Mask, Count + 1);
      end
      else
        ADiff.Add(dkRemoved, ABackup.Item.Id, F.RelPath, 'Arquivo ausente');
    end;
    for F in ACurrent.Files do
    begin
      if BackupIndex.ContainsKey(AnsiUpperCase(F.RelPath)) then
        Continue;
      Mask := UpperCase(MaskNonAscii(F.RelPath));
      if not BackupGroups.ContainsKey(Mask) then
        ADiff.Add(dkAdded, ABackup.Item.Id, F.RelPath, 'Arquivo adicionado')
      else if MatchedAliases.TryGetValue(Mask, Count) and (Count > 0) then
        MatchedAliases[Mask] := Count - 1
      else
        Inc(ADiff.TolerantFileCount);
    end;
  finally
    MatchedAliases.Free;
    CurrentGroups.Free;
    BackupGroups.Free;
    CurrentIndex.Free;
    BackupIndex.Free;
  end;
end;

function TolerantFileSummary(ACount: Integer): string;
begin
  if ACount = 1 then
    Result := '1 arquivo com nome não-ASCII comparado de forma tolerante.'
  else
    Result := Format
      ('%d arquivos com nomes não-ASCII comparados de forma tolerante.',
      [ACount]);
end;

function FormatCompareEntry(AEntry: TDiffEntry): string;
var
  Mark: Char;
  FirstBreak: Integer;
begin
  case AEntry.Kind of
    dkAdded:
      Mark := '+';
    dkRemoved:
      Mark := '-';
    dkChanged:
      Mark := '~';
  else
    Mark := 'i';
  end;
  Result := Mark + ' ' + AEntry.Path;
  if AEntry.Detail = '' then
    Exit;
  FirstBreak := Pos(sLineBreak, AEntry.Detail);
  if FirstBreak = 0 then
    Result := Result + '  (' + AEntry.Detail + ')'
  else
    Result := Result + '  (' + Copy(AEntry.Detail, 1, FirstBreak - 1) + ')' +
      Copy(AEntry.Detail, FirstBreak, MaxInt);
end;

function CompareManifests(ABackup, ACurrent: TManifest;
  const AVersions: TArray<string>; const ARegistryDetails: TRegistryDetails)
  : TCompareResult;
var
  V, C: TManifestVersion;
  B, M: TManifestItem;
  P, Detail: string;
  L: ILogger;
begin
  L := CreateLogger;
  L.Debug('Comparando manifestos.');
  Result := TCompareResult.Create;
  try
    for V in ABackup.Versions do
    begin
      if (Length(AVersions) > 0) and not Core.Types.ContainsText(AVersions,
        V.BdsVersion) then
        Continue;
      C := ACurrent.FindVersion(V.BdsVersion);
      if C = nil then
        Result.Add(dkRemoved, '', V.BdsVersion, 'Versão não instalada')
      else
      begin
        if V.ProductVersion <> C.ProductVersion then
          Result.Add(dkChanged, '', V.BdsVersion,
            'Versão do produto diferente');
        if V.InstalledUpdates <> C.InstalledUpdates then
          Result.Add(dkChanged, '', V.BdsVersion,
            'Atualizações instaladas diferentes');
      end;
    end;
    for B in ABackup.Items do
    begin
      if not Applicable(B.Item, AVersions) then
        Continue;
      P := Remap(B.Item.SourcePath, ABackup.SourceUserProfile,
        ACurrent.SourceUserProfile);
      if (B.Item.Kind = ikRegistry) and IsInstallerKey(P) then
        Continue;
      M := FindItem(ACurrent, B, P);
      if M = nil then
      begin
        Result.Add(dkRemoved, B.Item.Id, P, 'Item ausente');
        Continue;
      end;
      if B.Item.Kind = ikRegistry then
      begin
        if B.Hash <> M.Hash then
        begin
          Detail := 'Registro diferente';
          if Assigned(ARegistryDetails) then
            Detail := ARegistryDetails(B, P);
          Result.Add(dkChanged, B.Item.Id, P, Detail);
        end;
        Continue;
      end;
      CompareFiles(B, M, Result);
    end;
    L.Debug(Format('Comparação de manifestos concluída: %d diferenças.',
      [Result.Entries.Count]));
  except
    Result.Free;
    raise;
  end;
end;

function DiffManifests(ABackup, ACurrent: TManifest;
  const AVersions: TArray<string>): TCompareResult;
begin
  Result := CompareManifests(ABackup, ACurrent, AVersions, nil);
end;

type
  TRegistryValue = record
    Path: string;
    Data: string;
  end;

  TRegistryValues = TDictionary<string, TRegistryValue>;

function ShortRegistryPath(const AKey: string): string;
const
  CurrentUser = 'HKEY_CURRENT_USER\';
  LocalMachine = 'HKEY_LOCAL_MACHINE\';
begin
  Result := AKey;
  if StartsText(CurrentUser, AKey) then
    Result := 'HKCU\' + Copy(AKey, Length(CurrentUser) + 1, MaxInt)
  else if StartsText(LocalMachine, AKey) then
    Result := 'HKLM\' + Copy(AKey, Length(LocalMachine) + 1, MaxInt);
end;

function ReadValueName(const ALine: string; out AName: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  AName := '';
  if StartsStr('@=', ALine) then
    Exit(2);
  if (ALine = '') or (ALine[1] <> '"') then
    Exit;
  I := 2;
  while I <= Length(ALine) do
  begin
    if ALine[I] = '"' then
    begin
      Result := I + 1;
      if (Result > Length(ALine)) or (ALine[Result] <> '=') then
        Result := 0;
      Exit;
    end;
    if ALine[I] = '\' then
      Inc(I);
    if I <= Length(ALine) then
      AName := AName + ALine[I];
    Inc(I);
  end;
end;

procedure ReadRegistryValues(const AFile, ARoot: string;
  AValues: TRegistryValues);
var
  Lines: TStringList;
  Line, Key, Name, Subkey: string;
  Value: TRegistryValue;
  I, Separator: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := NormalizeRegFile(AFile);
    I := 0;
    Key := '';
    while I < Lines.Count do
    begin
      Line := Lines[I];
      Inc(I);
      if StartsStr('[', Line) and EndsStr(']', Line) then
      begin
        Key := ShortRegistryPath(Copy(Line, 2, Length(Line) - 2));
        Subkey := Key + '\';
        if SameText(Key, ARoot) then
          Subkey := ''
        else if StartsText(ARoot + '\', Key) then
          Subkey := Copy(Key, Length(ARoot) + 2, MaxInt) + '\';
        Continue;
      end;
      Separator := ReadValueName(Line, Name);
      if (Key = '') or (Separator = 0) then
        Continue;
      Value.Data := Copy(Line, Separator + 1, MaxInt);
      while EndsStr('\', Value.Data) and (I < Lines.Count) do
      begin
        SetLength(Value.Data, Length(Value.Data) - 1);
        Value.Data := Value.Data + Lines[I];
        Inc(I);
      end;
      if StartsText('hex', Value.Data) or StartsText('dword:', Value.Data) then
        Value.Data := LowerCase(Value.Data);
      if Name = '' then
        Value.Path := Subkey + '(Padrão)'
      else
        Value.Path := Subkey + Name;
      AValues.AddOrSetValue(AnsiUpperCase(Key) + #0 +
        AnsiUpperCase(Name), Value);
    end;
  finally
    Lines.Free;
  end;
end;

function RegistryDetails(const ABackupFile, ACurrentFile, AKey: string;
  const ALogger: ILogger): string;
const
  MaxDetails = 20;
var
  Backup, Current: TRegistryValues;
  Pair: TPair<string, TRegistryValue>;
  CurrentValue: TRegistryValue;
  Differences: TStringList;
  I: Integer;
begin
  Result := 'Registro diferente';
  Backup := TRegistryValues.Create;
  Current := TRegistryValues.Create;
  Differences := TStringList.Create;
  try
    ReadRegistryValues(ABackupFile, AKey, Backup);
    ReadRegistryValues(ACurrentFile, AKey, Current);
    for Pair in Backup do
      if not Current.TryGetValue(Pair.Key, CurrentValue) then
        Differences.Add(Pair.Value.Path + ': ausente')
      else if Pair.Value.Data <> CurrentValue.Data then
        Differences.Add(Pair.Value.Path + ': alterado');
    for Pair in Current do
      if not Backup.ContainsKey(Pair.Key) then
        Differences.Add(Pair.Value.Path + ': adicionado');
    Differences.Sort;
    for I := 0 to Differences.Count - 1 do
    begin
      ALogger.Debug(AKey + '\' + Differences[I]);
      if I < MaxDetails then
        Result := Result + sLineBreak + '  ' + Differences[I];
    end;
    if Differences.Count > MaxDetails then
      Result := Result + sLineBreak + Format('  ... mais %d',
        [Differences.Count - MaxDetails]);
  finally
    Differences.Free;
    Current.Free;
    Backup.Free;
  end;
end;

constructor TCompareEngine.Create(const ALogger: ILogger;
  const ARunner: IProcessRunner);
begin
  inherited Create;
  FLogger := ALogger;
  FRunner := ARunner;
  FLogger.Debug('Criando serviço de comparação.');
end;

function TCompareEngine.Execute(const AOptions: Core.Types.TCompareOptions;
  AInstalled: TDelphiVersionList; AConfig: TToolConfig;
  const AProgress: TProgressProc): TCompareResult;
var
  Root, Temp, RegistryTemp, P: string;
  B, C: TManifest;
  Items: TBackupItemList;
  Exclusions: TToolConfig;
  It: TBackupItem;
  M: TManifestItem;
  Dirs: TArray<string>;
  RegistryExports: TDictionary<string, string>;
  ManifestFailures: Integer;
begin
  FLogger.Info('Iniciando comparação.');
  Result := nil;
  B := nil;
  C := nil;
  Items := TBackupItemList.Create(True);
  Temp := '';
  RegistryTemp := '';
  RegistryExports := TDictionary<string, string>.Create;
  Exclusions := nil;
  try
    try
      if Assigned(AProgress) then
        AProgress(0, 0, 'Abrindo backup...');
      Root := ExpandFileName(AOptions.Source);
      if SameText(ExtractFileExt(Root), '.zip') then
      begin
        Temp := CreateTempDirectory('DelphiBackupRestore_compare_');
        if not ExtractBackupZip(Root, Temp, FRunner, FLogger, AProgress) then
          raise EDelphiBackupError.Create('Falha ao extrair backup.');
        Dirs := TDirectory.GetDirectories(Temp);
        if Length(Dirs) <> 1 then
          raise EDelphiBackupError.Create
            ('Arquivo ZIP não contém uma única pasta de backup.');
        Root := Dirs[0];
        if PathHasReparsePoint(TPath.Combine(Root, BACKUP_MANIFEST_FILE)) then
          raise EDelphiBackupError.Create
            ('Caminho inválido dentro do ZIP: ' + Root);
      end;
      if Assigned(AProgress) then
        AProgress(0, 0, 'Lendo manifesto...');
      B := LoadManifest(TPath.Combine(Root, BACKUP_MANIFEST_FILE));
      if B.HasExclusions then
      begin
        Exclusions := TToolConfig.Create;
        Exclusions.ExcludeDirs.Assign(B.ExcludeDirs);
        Exclusions.ExcludeFiles.Assign(B.ExcludeFiles);
      end;
      for M in B.Items do
      begin
        if not Applicable(M.Item, AOptions.Versions) then
          Continue;
        if (M.Item.Kind = ikRegistry) and IsInstallerKey(M.Item.SourcePath) then
        begin
          FLogger.Debug('Chave do instalador ignorada: ' + M.Item.SourcePath);
          Continue;
        end;
        It := TBackupItem.Create;
        Items.Add(It);
        It.Id := M.Item.Id;
        It.Kind := M.Item.Kind;
        It.Category := M.Item.Category;
        It.SourcePath := Remap(M.Item.SourcePath, B.SourceUserProfile,
          GetUserProfileDir);
        if ((It.Kind = ikFolder) and not DirectoryExists(It.SourcePath)) or
          ((It.Kind in [ikFile, ikDll]) and
          not FileExists(RealFileSystemPath(It.SourcePath))) or
          ((It.Kind = ikRegistry) and not FRunner.RegKeyExists(It.SourcePath))
        then
        begin
          Items.Delete(Items.Count - 1);
          Continue;
        end;
        It.Description := M.Item.Description;
        It.Versions.Assign(M.Item.Versions);
        It.Company := M.Item.Company;
        It.FileVersion := M.Item.FileVersion;
        It.DllOrigin := M.Item.DllOrigin;
        It.ReinstalledByIde := M.Item.ReinstalledByIde;
      end;
      for It in Items do
        if It.Kind = ikRegistry then
        begin
          if RegistryTemp = '' then
            RegistryTemp := CreateTempDirectory
              ('DelphiBackupRestore_compare_reg_');
          P := TPath.Combine(RegistryTemp, Format('registro_%d.reg',
            [RegistryExports.Count + 1]));
          if not FRunner.RegExport(It.SourcePath, P) then
            raise EDelphiBackupError.Create('Falha ao exportar registro: ' +
              It.SourcePath);
          RegistryExports.AddOrSetValue(AnsiUpperCase(It.SourcePath), P);
        end;
      if Exclusions = nil then
        Exclusions := AConfig;
      C := BuildEnvironmentManifest(AInstalled, Items,
        function(AItem: TBackupItem): string
        begin
          if AItem.Kind = ikRegistry then
            Result := RegistryExports[AnsiUpperCase(AItem.SourcePath)]
          else
            Result := RealFileSystemPath(AItem.SourcePath);
        end, Exclusions, FLogger, ManifestFailures);
      if ManifestFailures > 0 then
        FLogger.Warn(Format('Manifesto atual contém %d itens com falha.',
          [ManifestFailures]));
      Result := CompareManifests(B, C, AOptions.Versions,
        function(AItem: TManifestItem; AKey: string): string
        var
          BackupFile, CurrentFile, Id: string;
        begin
          Result := 'Registro diferente';
          Id := AItem.Item.Id;
          if (Id = '') or (Id = '.') or (Id = '..') or (Pos('\', Id) > 0) or
            (Pos('/', Id) > 0) or (Pos(':', Id) > 0) then
          begin
            FLogger.Warn('Identificador de registro inválido no backup: ' + Id);
            Exit;
          end;
          BackupFile := TPath.Combine(TPath.Combine(Root, BACKUP_REGISTRY_DIR),
            Id + '.reg');
          if not IsPathInside(BackupFile, Root) or
            PathHasReparsePoint(BackupFile) then
          begin
            FLogger.Warn('Caminho de registro inválido no backup: ' +
              BackupFile);
            Exit;
          end;
          CurrentFile := RegistryExports[AnsiUpperCase(AKey)];
          try
            Result := RegistryDetails(BackupFile, CurrentFile, AKey, FLogger);
          except
            on E: Exception do
              FLogger.Warn('Falha ao detalhar registro ' + AKey + ': ' +
                E.Message);
          end;
        end);
      if Result.TolerantFileCount > 0 then
        FLogger.Debug(TolerantFileSummary(Result.TolerantFileCount));
      FLogger.Info(Format('Comparação concluída: %d diferenças.',
        [Result.Entries.Count]));
    except
      on E: Exception do
      begin
        FLogger.Error('Erro na comparação: ' + E.Message);
        raise;
      end;
    end;
  finally
    C.Free;
    B.Free;
    Items.Free;
    RegistryExports.Free;
    if (RegistryTemp <> '') and not DeleteTree(RegistryTemp) then
      FLogger.Warn('Não foi possível remover a pasta temporária: ' +
        RegistryTemp);
    if Exclusions <> AConfig then
      Exclusions.Free;
    if (Temp <> '') and not DeleteTree(Temp) then
      FLogger.Warn('Não foi possível remover a pasta temporária: ' + Temp);
  end;
end;

end.
