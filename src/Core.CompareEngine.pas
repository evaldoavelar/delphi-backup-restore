unit Core.CompareEngine;
interface
uses Core.Types;
type TCompareEngine = class
private FLogger: ILogger; FRunner: IProcessRunner;
public constructor Create(const ALogger: ILogger; const ARunner: IProcessRunner);
function Execute(const AOptions: Core.Types.TCompareOptions; AInstalled: TDelphiVersionList; AConfig: TToolConfig): TCompareResult;
end;
function DiffManifests(ABackup, ACurrent: TManifest; const AVersions: TArray<string>): TCompareResult;
implementation
uses System.SysUtils, System.IOUtils, System.Classes, Winapi.Windows, Core.Manifest, Core.SystemUtils;
function Remap(const P, OldProfile, NewProfile: string): string;
var N: Integer;
begin Result:=P; N:=Length(ExcludeTrailingPathDelimiter(OldProfile)); if (N>0) and SameText(Copy(P,1,N),Copy(OldProfile,1,N)) and ((Length(P)=N) or (P[N+1]='\')) then Result:=ExcludeTrailingPathDelimiter(NewProfile)+Copy(P,N+1,MaxInt); end;
function Applicable(It: TBackupItem; const Versions: TArray<string>): Boolean;
var S: string;
begin Result:=(Length(Versions)=0) or (It.Versions.Count=0); if Result then Exit; for S in Versions do if It.UsedByVersion(S) then Exit(True); end;
function FindItem(M: TManifest; It: TManifestItem; const Source: string): TManifestItem;
var X: TManifestItem;
begin Result:=nil; for X in M.Items do if (X.Item.Kind=It.Item.Kind) and SameText(ExcludeTrailingPathDelimiter(X.Item.SourcePath),ExcludeTrailingPathDelimiter(Source)) then Exit(X); end;
function FindFile(M: TManifestItem; const P: string): TManifestFile;
var F: TManifestFile;
begin Result:=nil; for F in M.Files do if SameText(F.RelPath,P) then Exit(F); end;
function DiffManifests(ABackup, ACurrent: TManifest; const AVersions: TArray<string>): TCompareResult;
var V,C: TManifestVersion; B,M: TManifestItem; F,G: TManifestFile; P: string;
begin Result:=TCompareResult.Create; try
 for V in ABackup.Versions do begin if (Length(AVersions)>0) and not ContainsText(AVersions,V.BdsVersion) then Continue; C:=ACurrent.FindVersion(V.BdsVersion); if C=nil then Result.Add(dkRemoved,'',V.BdsVersion,'Versão não instalada') else begin if V.ProductVersion<>C.ProductVersion then Result.Add(dkChanged,'',V.BdsVersion,'Versão do produto diferente'); if V.InstalledUpdates<>C.InstalledUpdates then Result.Add(dkChanged,'',V.BdsVersion,'Atualizações instaladas diferentes'); end; end;
 for B in ABackup.Items do begin if not Applicable(B.Item,AVersions) then Continue; P:=Remap(B.Item.SourcePath,ABackup.SourceUserProfile,ACurrent.SourceUserProfile); M:=FindItem(ACurrent,B,P); if M=nil then begin Result.Add(dkRemoved,B.Item.Id,P,'Item ausente'); Continue; end; if B.Item.Kind=ikRegistry then begin if B.Hash<>M.Hash then Result.Add(dkChanged,B.Item.Id,P,'Registro diferente'); Continue; end;
 for F in B.Files do begin G:=FindFile(M,F.RelPath); if G=nil then Result.Add(dkRemoved,B.Item.Id,F.RelPath,'Arquivo ausente') else if (F.Size<>G.Size) or (F.ModifiedUtc<>G.ModifiedUtc) then Result.Add(dkChanged,B.Item.Id,F.RelPath,'Arquivo alterado'); end;
 for F in M.Files do if FindFile(B,F.RelPath)=nil then Result.Add(dkAdded,B.Item.Id,F.RelPath,'Arquivo adicionado'); end;
 except Result.Free; raise; end; end;
constructor TCompareEngine.Create(const ALogger: ILogger; const ARunner: IProcessRunner);
begin inherited Create; FLogger:=ALogger; FRunner:=ARunner; FLogger.Debug('Criando serviço de comparação.'); end;
function TCompareEngine.Execute(const AOptions: Core.Types.TCompareOptions; AInstalled: TDelphiVersionList; AConfig: TToolConfig): TCompareResult;
var Root, Temp, P: string; B,C: TManifest; Items: TBackupItemList; It: TBackupItem; M: TManifestItem; Dirs: TArray<string>; Index: Integer;
begin
 FLogger.Info('Iniciando comparação.'); Result:=nil; B:=nil; C:=nil; Items:=TBackupItemList.Create(True); Temp:='';
 try try
  Root:=AOptions.Source;
  Temp:=TPath.Combine(TPath.GetTempPath,Format('DelphiBackupRestore_compare_%d_%d',[GetCurrentProcessId,GetTickCount])); TDirectory.CreateDirectory(Temp);
  if SameText(ExtractFileExt(Root),'.zip') then begin if not FRunner.UnzipTo(Root,Temp) then raise EDelphiBackupError.Create('Falha ao extrair backup.'); Dirs:=TDirectory.GetDirectories(Temp); if Length(Dirs)<>1 then raise EDelphiBackupError.Create('Arquivo ZIP não contém uma única pasta de backup.'); Root:=Dirs[0]; end;
  B:=LoadManifest(TPath.Combine(Root,BACKUP_MANIFEST_FILE));
  for M in B.Items do begin if not Applicable(M.Item,AOptions.Versions) then Continue; It:=TBackupItem.Create; Items.Add(It); It.Id:=M.Item.Id; It.Kind:=M.Item.Kind; It.Category:=M.Item.Category; It.SourcePath:=Remap(M.Item.SourcePath,B.SourceUserProfile,GetUserProfileDir); if ((It.Kind=ikFolder) and not DirectoryExists(It.SourcePath)) or ((It.Kind in [ikFile,ikDll]) and not FileExists(It.SourcePath)) or ((It.Kind=ikRegistry) and not FRunner.RegKeyExists(It.SourcePath)) then begin Items.Delete(Items.Count-1); Continue; end; It.Description:=M.Item.Description; It.Versions.Assign(M.Item.Versions); It.Company:=M.Item.Company; It.FileVersion:=M.Item.FileVersion; It.DllOrigin:=M.Item.DllOrigin; It.ReinstalledByIde:=M.Item.ReinstalledByIde; end;
  Index:=0; for It in Items do if It.Kind=ikRegistry then begin Inc(Index); P:=TPath.Combine(Temp,Format('registro_%d.reg',[Index])); if FRunner.RegKeyExists(It.SourcePath) and not FRunner.RegExport(It.SourcePath,P) then raise EDelphiBackupError.Create('Falha ao exportar registro: '+It.SourcePath); end;
  Index:=0; C:=BuildEnvironmentManifest(AInstalled,Items,
   function(AItem: TBackupItem): string
   begin if AItem.Kind=ikRegistry then begin Inc(Index); Result:=TPath.Combine(Temp,Format('registro_%d.reg',[Index])); end else Result:=AItem.SourcePath; end,AConfig,FLogger);
  Result:=DiffManifests(B,C,AOptions.Versions); FLogger.Info(Format('Comparação concluída: %d diferenças.',[Result.Entries.Count]));
 except on E: Exception do begin FLogger.Error('Erro na comparação: '+E.Message); raise; end; end;
 finally C.Free; B.Free; Items.Free; if (Temp<>'') and TDirectory.Exists(Temp) then try TDirectory.Delete(Temp,True); except on E: Exception do FLogger.Warn('Falha ao remover arquivos temporários: '+E.Message); end; end;
end;
end.


