unit Core.BackupEngine;

interface

uses System.SysUtils, Core.Types;

type
  TBackupEngine = class
  private
    FLogger: ILogger;
    FRunner: IProcessRunner;
    FFailureCount: Integer;
    function ZipFileCount(const AZip: string): Integer;
    procedure RemoveFolderAfterZip(const AFolder, AZip: string);
  public
    constructor Create(const ALogger: ILogger; const ARunner: IProcessRunner);
    function Execute(const AOptions: TBackupOptions;
      AVersions: TDelphiVersionList; AItems: TBackupItemList;
      AConfig: TToolConfig; const AProgress: TProgressProc): string;
    { Items that could not be copied/exported in the last Execute (0 = complete backup). }
    property FailureCount: Integer read FFailureCount;
  end;

  { True when the item would be processed by a backup with these options. }
function ItemInScope(AItem: TBackupItem; const AOptions: TBackupOptions;
  AVersions: TDelphiVersionList): Boolean;
{ Bytes the item occupies on disk (metadata only, files are never opened).
  Registry keys count as 0. }
function EstimateItemSize(AItem: TBackupItem; AConfig: TToolConfig): Int64;
{ Free bytes on the volume of APath (walks up to the first existing folder). }
function FreeSpaceAt(const APath: string): Int64;
function FormatBytes(ABytes: Int64): string;

implementation

uses System.Classes, System.IOUtils, Winapi.Windows, Core.SystemUtils,
  Core.Manifest, Core.PathDiscovery;

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
    if ((Length(AOptions.Versions) = 0) or ContainsText(AOptions.Versions,
      V.BdsVersion)) and AItem.UsedByVersion(V.BdsVersion) then
      Exit(True);
end;

function EstimateItemSize(AItem: TBackupItem; AConfig: TToolConfig): Int64;
var
  M: TManifestItem;
  F: TManifestFile;
  D, X: TStrings;
  Info: TWin32FileAttributeData;
begin
  Result := 0;
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
      if GetFileAttributesEx(PChar(AItem.SourcePath), GetFileExInfoStandard,
        @Info) then
        Result := (Int64(Info.nFileSizeHigh) shl 32) or Info.nFileSizeLow;
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

function TBackupEngine.ZipFileCount(const AZip: string): Integer;
var
  Output: string;
  Lines: TStringList;
  I: Integer;
  Line: string;
begin
  { tar -t lists one entry per line; folders end with '/' }
  Result := -1;
  if FRunner.Run('tar.exe', '-t -f "' + AZip + '"', '', Output) <> 0 then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    Result := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Line <> '') and (Line[Length(Line)] <> '/') then
        Inc(Result);
    end;
  finally
    Lines.Free;
  end;
end;

procedure TBackupEngine.RemoveFolderAfterZip(const AFolder, AZip: string);
var
  InFolder, InZip: Integer;
begin
  InFolder := CountFilesInTree(AFolder);
  InZip := ZipFileCount(AZip);
  FLogger.Info(Format('Conferindo o zip: %d arquivo(s) na pasta, %d no zip.',
    [InFolder, InZip]));
  if (InFolder < 0) or (InZip <> InFolder) then
  begin
    FLogger.Warn('O zip não confere com a pasta; a pasta foi mantida: '
      + AFolder);
    Exit;
  end;
  if DeleteTree(AFolder) then
    FLogger.Info('Pasta removida (o backup está no zip): ' + AFolder)
  else
    FLogger.Warn('Não foi possível remover a pasta do backup: ' + AFolder);
end;

function TBackupEngine.Execute(const AOptions: TBackupOptions;
  AVersions: TDelphiVersionList; AItems: TBackupItemList; AConfig: TToolConfig;
  const AProgress: TProgressProc): string;
var
  Root, Dest, Zip, S: string;
  It: TBackupItem;
  V: TDelphiVersion;
  SelectedVersions: TDelphiVersionList;
  Done: TBackupItemList;
  M: TManifest;
  OK, Used: Boolean;
  I, Failures, ManifestFailures: Integer;
  D, F: TStrings;
  Safety: TPathSafety;
  Estimated, Needed, FreeBytes: Int64;
begin
  FFailureCount := 0;
  FLogger.Info('Iniciando backup.');
  SelectedVersions := TDelphiVersionList.Create(False);
  Done := TBackupItemList.Create(False);
  try
    try
      for V in AVersions do
        if (Length(AOptions.Versions) = 0) or ContainsText(AOptions.Versions,
          V.BdsVersion) then
          SelectedVersions.Add(V);

      { Safety (second layer after Core.PathDiscovery): abort before copying a
        single byte if a folder is a system container / contains a Delphi install,
        or if the destination lies inside a folder that would be copied. }
      Safety := TPathSafety.Create(AVersions);
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
          Inc(Estimated, EstimateItemSize(It, AConfig));
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
      D := nil;
      F := nil;
      if AConfig <> nil then
      begin
        D := AConfig.ExcludeDirs;
        F := AConfig.ExcludeFiles;
      end;
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
                OK := FRunner.CopyTree(It.SourcePath, Dest, False, D, F);
              end;
            ikFile, ikDll:
              begin
                if It.Kind = ikDll then
                  S := BACKUP_DLLS_DIR
                else
                  S := BACKUP_FILES_DIR;
                Dest := TPath.Combine(TPath.Combine(Root, S), It.Id);
                TDirectory.CreateDirectory(Dest);
                OK := FRunner.CopyFile(It.SourcePath, Dest);
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
        end, AConfig, FLogger, ManifestFailures);
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
        if not FRunner.ZipFolder(Root, Zip) then
          raise EDelphiBackupError.Create('Falha ao compactar backup.');
        Result := Zip;
        if not AOptions.KeepFolder then
          RemoveFolderAfterZip(Root, Zip);
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
    Done.Free;
    SelectedVersions.Free;
  end;
end;

end.
