unit Core.BackupEngine;

interface

uses System.SysUtils, Core.Types;

type
  TBackupEngine = class
  private
    FLogger: ILogger;
    FRunner: IProcessRunner;
  public
    constructor Create(const ALogger: ILogger; const ARunner: IProcessRunner);
    function Execute(const AOptions: TBackupOptions;
      AVersions: TDelphiVersionList; AItems: TBackupItemList;
      AConfig: TToolConfig; const AProgress: TProgressProc): string;
  end;

implementation

uses System.Classes, System.IOUtils, Core.SystemUtils, Core.Manifest;

constructor TBackupEngine.Create(const ALogger: ILogger;
  const ARunner: IProcessRunner);
begin
  inherited Create;
  FLogger := ALogger;
  FRunner := ARunner;
  FLogger.Debug('Criando serviço de backup.');
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
  I, Failures: Integer;
  D, F: TStrings;
begin
  FLogger.Info('Iniciando backup.');
  SelectedVersions := TDelphiVersionList.Create(False);
  Done := TBackupItemList.Create(False);
  try
    try
      for V in AVersions do
        if (Length(AOptions.Versions) = 0) or ContainsText(AOptions.Versions,
          V.BdsVersion) then
          SelectedVersions.Add(V);
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
        end, AConfig, FLogger);
      try
        SaveManifest(M, TPath.Combine(Root, BACKUP_MANIFEST_FILE));
      finally
        M.Free;
      end;
      Result := Root;
      if AOptions.CreateZip then
      begin
        Zip := Root + '.zip';
        if not FRunner.ZipFolder(Root, Zip) then
          raise EDelphiBackupError.Create('Falha ao compactar backup.');
        Result := Zip;
      end;
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
