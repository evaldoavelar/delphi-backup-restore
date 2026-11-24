unit Core.BackupEngine;

interface

uses System.SysUtils, Core.Types;

type
  TBackupEngine = class
  private
    FLogger: ILogger;
    FRunner: IProcessRunner;
    FFailureCount: Integer;
    procedure RemoveFolderAfterZip(const AFolder, AZip, ADestination: string);
  protected
    procedure DetectInstalledVersions(AInstalled: TDelphiVersionList); virtual;
  public
    constructor Create(const ALogger: ILogger; const ARunner: IProcessRunner);
    function Execute(const AOptions: TBackupOptions;
      AVersions: TDelphiVersionList; AItems: TBackupItemList;
      AConfig: TToolConfig; const AProgress: TProgressProc;
      const AZipProgress: TProgressProc = nil): string;
    { Items that could not be copied/exported in the last Execute (0 = complete backup). }
    property FailureCount: Integer read FFailureCount;
  end;

  { True when the item would be processed by a backup with these options. }
function ItemInScope(AItem: TBackupItem; const AOptions: TBackupOptions;
  AVersions: TDelphiVersionList): Boolean;
{ Bytes the item occupies on disk (metadata only, files are never opened).
  Registry keys count as 0. }
function EstimateItemSize(AItem: TBackupItem; AConfig: TToolConfig;
  const ALogger: ILogger = nil): Int64;
{ Free bytes on the volume of APath (walks up to the first existing folder). }
function FreeSpaceAt(const APath: string): Int64;
function FormatBytes(ABytes: Int64): string;

implementation

uses System.Classes, System.IOUtils, System.StrUtils, Winapi.Windows,
  Core.SystemUtils,
  Core.Manifest, Core.PathDiscovery, Core.VersionDetector,
  Core.Logger, Core.Zip;

function ItemInScope(AItem: TBackupItem; const AOptions: TBackupOptions;
  AVersions: TDelphiVersionList): Boolean;
var
  V: TDelphiVersion;
begin
  Result := False;
  if not AItem.Selected or not(AItem.Category in AOptions.Categories) then
    Exit;
  if AItem.Versions.Count = 0 then
    Exit(True);
  for V in AVersions do
    if ((Length(AOptions.Versions) = 0) or
      Core.Types.ContainsText(AOptions.Versions, V.BdsVersion)) and
      AItem.UsedByVersion(V.BdsVersion) then
      Exit(True);
end;

function EstimateItemSize(AItem: TBackupItem; AConfig: TToolConfig;
  const ALogger: ILogger): Int64;
var
  M: TManifestItem;
  F: TManifestFile;
  D, X: TStrings;
  Info: TWin32FileAttributeData;
  L: ILogger;
begin
  L := ALogger;
  if L = nil then
    L := CreateLogger;
  L.Debug('Estimando tamanho do item: ' + AItem.SourcePath);
  Result := 0;
  try
    case AItem.Kind of
      ikFolder:
        begin
          D := nil;
          X := nil;
          if AConfig <> nil then
          begin
            D := AConfig.ExcludeDirs;
            X := AConfig.ExcludeFiles;
          end;
          M := TManifestItem.Create;
          try
            { ScanItemFiles reads M.Item (kind/path); M owns and frees it }
            M.Item := TBackupItem.Create;
            M.Item.Kind := AItem.Kind;
            M.Item.SourcePath := AItem.SourcePath;
            ScanItemFiles(AItem.SourcePath, M, D, X);
            for F in M.Files do
              Inc(Result, F.Size);
          finally
            M.Free;
          end;
        end;
      ikFile, ikDll:
        if GetFileAttributesEx(PChar(RealFileSystemPath(AItem.SourcePath)),
          GetFileExInfoStandard, @Info) then
          Result := (Int64(Info.nFileSizeHigh) shl 32) or Info.nFileSizeLow
        else
          RaiseLastOSError;
    end;
  except
    on E: Exception do
    begin
      Result := 0;
      L.Warn('Não foi possível estimar o tamanho de ' + AItem.SourcePath + ': '
        + E.Message);
    end;
  end;
end;

function FreeSpaceAt(const APath: string): Int64;
var
  P: string;
  FreeAvail, Total, TotalFree: Int64;
begin
  Result := -1;
  P := NormalizePath(APath);
  while (P <> '') and not DirectoryExists(P) do
  begin
    if SameText(ExtractFileDir(P), P) then
      Break;
    P := ExtractFileDir(P);
  end;
  if P = '' then
    Exit;
  if GetDiskFreeSpaceEx(PChar(IncludeTrailingPathDelimiter(P)), FreeAvail,
    Total, @TotalFree) then
    Result := FreeAvail;
end;

function FormatBytes(ABytes: Int64): string;
begin
  if ABytes >= Int64(1024) * 1024 * 1024 then
    Result := FormatFloat('0.0', ABytes / (1024.0 * 1024 * 1024)) + ' GB'
  else if ABytes >= 1024 * 1024 then
    Result := FormatFloat('0.0', ABytes / (1024.0 * 1024)) + ' MB'
  else
    Result := FormatFloat('0', ABytes / 1024.0) + ' KB';
end;

constructor TBackupEngine.Create(const ALogger: ILogger;
  const ARunner: IProcessRunner);
begin
  inherited Create;
  FLogger := ALogger;
  FRunner := ARunner;
  FLogger.Debug('Criando serviço de backup.');
end;

procedure TBackupEngine.DetectInstalledVersions(AInstalled: TDelphiVersionList);
begin
  CreateVersionDetector(FLogger).Detect(AInstalled);
end;

procedure TBackupEngine.RemoveFolderAfterZip(const AFolder, AZip,
  ADestination: string);
var
  Folder, Name, Prefix, Line, Entry: string;
  InFolder, InZip, Lines: TStringList;
  I: Integer;
  Matches: Boolean;
begin
  Folder := NormalizePath(AFolder);
  Name := ExtractFileName(Folder);
  if not IsAbsoluteFileSystemPath(Folder) or
    not SameText(NormalizePath(ExtractFileDir(Folder)),
    NormalizePath(ADestination)) or not StartsText(BACKUP_FOLDER_PREFIX, Name)
    or PathHasReparsePoint(Folder) then
  begin
    FLogger.Warn('Pasta de backup mantida por segurança: ' + AFolder);
    Exit;
  end;
  FLogger.Info('Conferindo nomes dos arquivos do ZIP: ' + AZip);
  InFolder := TStringList.Create;
  InZip := TStringList.Create;
  Lines := TStringList.Create;
  try
    { tar lists names through the ANSI code page, so non-ASCII characters are
      lossy and distinct names may collapse into one; compare with every
      non-ASCII char masked and keep duplicates }
    InFolder.CaseSensitive := False;
    InZip.CaseSensitive := False;
    InZip.Duplicates := dupAccept;
    InZip.Sorted := True;
    Matches := ListFilesInTree(Folder, InFolder) and
      ListBackupZip(AZip, FRunner, FLogger, Lines);
    if Matches then
    begin
      for I := 0 to InFolder.Count - 1 do
        InFolder[I] := MaskNonAscii(InFolder[I]);
      InFolder.Sort;
      Prefix := Name + '\';
      for Line in Lines do
      begin
        if (Line = '') or StartsText('tar:', Line) then
          Continue;
        Entry := StringReplace(Line, '/', '\', [rfReplaceAll]);
        if not StartsText(Prefix, Entry) then
        begin
          Matches := False;
          Break;
        end;
        if not EndsText('\', Entry) then
          InZip.Add(MaskNonAscii(Copy(Entry, Length(Prefix) + 1, MaxInt)));
      end;
      Matches := Matches and (InZip.Count = InFolder.Count);
      if Matches then
        for I := 0 to InFolder.Count - 1 do
          if not SameText(InFolder[I], InZip[I]) then
          begin
            Matches := False;
            Break;
          end;
    end;
  finally
    Lines.Free;
    InZip.Free;
    InFolder.Free;
  end;
  if not Matches then
  begin
    FLogger.Warn('O zip não confere com a pasta; a pasta foi mantida: '
      + AFolder);
    Exit;
  end;
  if DeleteTree(Folder) then
    FLogger.Info('Pasta removida (o backup está no zip): ' + Folder)
  else
    FLogger.Warn('Não foi possível remover a pasta do backup: ' + Folder);
end;

function TBackupEngine.Execute(const AOptions: TBackupOptions;
  AVersions: TDelphiVersionList; AItems: TBackupItemList; AConfig: TToolConfig;
  const AProgress, AZipProgress: TProgressProc): string;
var
  Root, Dest, Zip, S: string;
  It: TBackupItem;
  V: TDelphiVersion;
  SelectedVersions, Installed, ProtectedVersions: TDelphiVersionList;
  Done: TBackupItemList;
  M: TManifest;
  OK, Used: Boolean;
  I, Failures, ManifestFailures: Integer;
  Exclusions: TToolConfig;
  Safety: TPathSafety;
  Estimated, Needed, FreeBytes: Int64;
begin
  FFailureCount := 0;
  FLogger.Info('Iniciando backup.');
  SelectedVersions := TDelphiVersionList.Create(False);
  Done := TBackupItemList.Create(False);
  Exclusions := TToolConfig.Create;
  try
    Exclusions.ExcludeDirs.Clear;
    Exclusions.ExcludeFiles.Clear;
    if AConfig <> nil then
    begin
      Exclusions.ExcludeDirs.Assign(AConfig.ExcludeDirs);
      Exclusions.ExcludeFiles.Assign(AConfig.ExcludeFiles);
    end;
    try
      for V in AVersions do
        if (Length(AOptions.Versions) = 0) or
          Core.Types.ContainsText(AOptions.Versions, V.BdsVersion) then
          SelectedVersions.Add(V);

      { Safety (second layer after Core.PathDiscovery): abort before copying a
        single byte if a folder is a system container / contains a Delphi install,
        or if the destination lies inside a folder that would be copied. }
      Installed := TDelphiVersionList.Create(True);
      try
        DetectInstalledVersions(Installed);
        ProtectedVersions := TDelphiVersionList.Create(False);
        try
          for V in Installed do
            ProtectedVersions.Add(V);
          for V in AVersions do
            ProtectedVersions.Add(V);
          Safety := TPathSafety.Create(ProtectedVersions);
        finally
          ProtectedVersions.Free;
        end;
      finally
        Installed.Free;
      end;
      try
        for It in AItems do
          if (It.Kind = ikFolder) and ItemInScope(It, AOptions, AVersions) then
          begin
            if Safety.IsContainer(It.SourcePath) or
              Safety.IsForbidden(It.SourcePath) or
              ((It.Category <> icIdeConfig) and
              Safety.ContainsProtected(It.SourcePath)) then
              raise EDelphiBackupError.Create
                ('Backup abortado: pasta de sistema ou da instalação da IDE na lista: '
                + It.SourcePath);
            if IsPathInside(AOptions.Destination, It.SourcePath) then
              raise EDelphiBackupError.Create
                ('Backup abortado: o destino está dentro de uma pasta que será copiada ('
                + It.SourcePath + '). Escolha outro destino.');
          end;
      finally
        Safety.Free;
      end;

      { free space: estimate (metadata only) and refuse when it does not fit;
        the zip needs roughly the same space again }
      Estimated := 0;
      for It in AItems do
        if ItemInScope(It, AOptions, AVersions) then
          Inc(Estimated, EstimateItemSize(It, Exclusions, FLogger));
      Needed := Estimated + Estimated div 20;
      if AOptions.CreateZip then
        Inc(Needed, Estimated);
      FreeBytes := FreeSpaceAt(AOptions.Destination);
      FLogger.Info
        (Format('Tamanho estimado: %s; necessário no destino: %s; livre: %s.',
        [FormatBytes(Estimated), FormatBytes(Needed), FormatBytes(FreeBytes)]));
      if (FreeBytes >= 0) and (FreeBytes < Needed) then
        raise EDelphiBackupError.CreateFmt
          ('Espaço insuficiente no destino: necessário %s, disponível %s.',
          [FormatBytes(Needed), FormatBytes(FreeBytes)]);

      Root := TPath.Combine(AOptions.Destination, BACKUP_FOLDER_PREFIX +
        MachineName + '_' + FormatDateTime('yyyymmdd_hhnn', Now));
      if TDirectory.Exists(Root) then
        raise EDelphiBackupError.Create('A pasta de backup já existe: ' + Root);
      TDirectory.CreateDirectory(Root);
      FLogger.SetLogFile(TPath.Combine(Root, BACKUP_LOG_FILE));
      Failures := 0;
      I := 0;
      for It in AItems do
      begin
        if not It.Selected or not(It.Category in AOptions.Categories) then
          Continue;
        Used := It.Versions.Count = 0;
        for V in SelectedVersions do
          if It.UsedByVersion(V.BdsVersion) then
            Used := True;
        if not Used then
          Continue;
        Inc(I);
        if Assigned(AProgress) then
          AProgress(I, AItems.Count, It.Description);
        try
          OK := False;
          case It.Kind of
            ikFolder:
              begin
                Dest := TPath.Combine(TPath.Combine(Root,
                  BACKUP_FILES_DIR), It.Id);
                TDirectory.CreateDirectory(Dest);
                OK := FRunner.CopyTree(It.SourcePath, Dest, False,
                  Exclusions.ExcludeDirs, Exclusions.ExcludeFiles);
              end;
            ikFile, ikDll:
              begin
                if It.Kind = ikDll then
                  S := BACKUP_DLLS_DIR
                else
                  S := BACKUP_FILES_DIR;
                Dest := TPath.Combine(TPath.Combine(Root, S), It.Id);
                TDirectory.CreateDirectory(Dest);
                OK := FRunner.CopyFile(RealFileSystemPath(It.SourcePath), Dest);
              end;
            ikRegistry:
              begin
                Dest := TPath.Combine(Root, BACKUP_REGISTRY_DIR);
                TDirectory.CreateDirectory(Dest);
                OK := FRunner.RegExport(It.SourcePath,
                  TPath.Combine(Dest, It.Id + '.reg'));
              end;
          end;
          if OK then
            Done.Add(It)
          else
          begin
            Inc(Failures);
            FLogger.Warn('Falha ao copiar item: ' + It.SourcePath);
          end;
        except
          on E: Exception do
          begin
            Inc(Failures);
            FLogger.Warn('Falha ao copiar item ' + It.SourcePath + ': ' +
              E.Message);
          end;
        end;
      end;
      M := BuildEnvironmentManifest(SelectedVersions, Done,
        function(AItem: TBackupItem): string
        begin
          case AItem.Kind of
            ikRegistry:
              Result := TPath.Combine(TPath.Combine(Root, BACKUP_REGISTRY_DIR),
                AItem.Id + '.reg');
            ikDll:
              Result := TPath.Combine(TPath.Combine(Root, BACKUP_DLLS_DIR),
                AItem.Id);
          else
            Result := TPath.Combine(TPath.Combine(Root, BACKUP_FILES_DIR),
              AItem.Id);
          end;
        end, Exclusions, FLogger, ManifestFailures);
      Inc(Failures, ManifestFailures);
      try
        SaveManifest(M, TPath.Combine(Root, BACKUP_MANIFEST_FILE));
      finally
        M.Free;
      end;
      Result := Root;
      if AOptions.CreateZip then
      begin
        FLogger.Info(Format('Cópia concluída com %d falha(s). Compactando...',
          [Failures]));
        { close backup.log so the zip gets the complete file and the folder can
          be deleted; later messages still reach the console/GUI sinks }
        FLogger.SetLogFile('');
        Zip := Root + '.zip';
        if not CreateBackupZip(Root, Zip, AOptions.ZipStore, FRunner, FLogger,
          AZipProgress) then
          raise EDelphiBackupError.Create('Falha ao compactar backup.');
        Result := Zip;
        if not AOptions.KeepFolder then
          RemoveFolderAfterZip(Root, Zip, AOptions.Destination);
      end;
      FFailureCount := Failures;
      FLogger.Info(Format('Backup concluído: %s; falhas: %d.',
        [Result, Failures]));
    except
      on E: Exception do
      begin
        FLogger.Error('Erro no backup: ' + E.Message);
        raise;
      end;
    end;
  finally
    Exclusions.Free;
    Done.Free;
    SelectedVersions.Free;
  end;
end;

end.
