unit Cli.Runner;

{ Command line interface: list | backup | restore | compare | --version | --help.
  Output goes straight to the console as UTF-16 (WriteConsoleW) or UTF-8 when redirected,
  so accented pt-BR text survives regardless of the console code page. }

interface

function RunCli: Integer;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Generics.Collections,
  Core.Types, Core.Logger, Core.ProcessRunner, Core.SystemUtils,
  Core.VersionDetector,
  Core.PathDiscovery, Core.BackupEngine, Core.CompareEngine, Core.RestoreEngine,
  Core.DllScanner;

type
  TCliOptions = record
    Command: string;
    Versions: TArray<string>;
    Dest: string;
    Source: string;
    NoZip: Boolean;
    ScanDlls: Boolean;
    Categories: TItemCategories;
    CategoriesGiven: Boolean;
    ConfigFile: string;
  end;

var
  GOut: THandle = 0;

procedure ConsoleInit;
var
  H: THandle;
begin
  H := GetStdHandle(STD_OUTPUT_HANDLE);
  if (H = 0) or (H = INVALID_HANDLE_VALUE) then
  begin
    { GUI-subsystem exe attached to a console: standard handles are not set up }
    H := CreateFile('CONOUT$', GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or
      FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
    if H <> INVALID_HANDLE_VALUE then
    begin
      SetStdHandle(STD_OUTPUT_HANDLE, H);
      SetStdHandle(STD_ERROR_HANDLE, H);
    end
    else
      H := 0;
  end;
  GOut := H;
end;

procedure Say(const AText: string);
var
  Line: string;
  Written: DWORD;
  Mode: DWORD;
  U8: UTF8String;
begin
  if GOut = 0 then
    Exit;
  Line := AText + #13#10;
  if GetConsoleMode(GOut, Mode) then
    WriteConsole(GOut, PChar(Line), Length(Line), Written, nil)
  else
  begin
    U8 := UTF8String(Line);
    WriteFile(GOut, PAnsiChar(U8)^, Length(U8), Written, nil);
  end;
end;

procedure ShowHelp;
begin
  Say('Delphi Backup & Restore ' + ToolVersion);
  Say('');
  Say('Uso: DelphiBackupRestore.exe <comando> [opções]');
  Say('     (sem argumentos abre a interface gráfica)');
  Say('');
  Say('Comandos:');
  Say('  list       Lista as versões do Delphi instaladas');
  Say('  backup     Cria um backup (requer --dest)');
  Say('  restore    Restaura um backup (requer --source)');
  Say('  compare    Compara um backup com o ambiente atual (requer --source)');
  Say('  --version  Mostra a versão da ferramenta');
  Say('  --help     Mostra esta ajuda');
  Say('');
  Say('Opções:');
  Say('  --versions <lista>    Versões BDS separadas por vírgula, ex.: 22.0,5.0 (padrão: todas)');
  Say('  --dest <pasta>        Pasta onde o backup será criado');
  Say('  --source <pasta|zip>  Pasta ou .zip do backup');
  Say('  --no-zip              Não compactar o backup em .zip');
  Say('  --scan-dlls           Incluir DLLs de terceiros encontradas no sistema');
  Say('  --categories <lista>  components,ide-config,experts,boss,extra,system-dll');
  Say('  --config <arquivo>    Arquivo de configuração (padrão: ' +
    CONFIG_FILE_NAME + ' ao lado do exe)');
  Say('');
  Say('Códigos de saída: 0 ok, 1 diferenças (compare), 2 erro, 3 pré-requisito, 4 uso inválido');
end;

function ParseCategories(const AText: string): TItemCategories;
var
  Parts: TArray<string>;
  S: string;
begin
  Result := [];
  Parts := TextToVersions(AText); // same comma/semicolon splitting
  for S in Parts do
    Include(Result, TextToItemCategory(S));
end;

{ Returns False (and prints the reason) when the command line is invalid. }
function ParseArgs(out AOpts: TCliOptions): Boolean;
var
  I: Integer;
  Arg, Name, Value: string;
  P: Integer;

  function NeedValue: Boolean;
  begin
    if P > 0 then
      Exit(True); // value came as --name=value
    if I < ParamCount then
    begin
      Inc(I);
      Value := ParamStr(I);
      Result := True;
    end
    else
    begin
      Say('Erro: a opção ' + Name + ' exige um valor.');
      Result := False;
    end;
  end;

begin
  Result := False;
  AOpts.Command := LowerCase(ParamStr(1));
  SetLength(AOpts.Versions, 0);
  AOpts.Dest := '';
  AOpts.Source := '';
  AOpts.NoZip := False;
  AOpts.ScanDlls := False;
  AOpts.Categories := [];
  AOpts.CategoriesGiven := False;
  AOpts.ConfigFile := '';
  I := 2;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    P := Pos('=', Arg);
    if (P > 0) and (Copy(Arg, 1, 2) = '--') then
    begin
      Name := LowerCase(Copy(Arg, 1, P - 1));
      Value := Copy(Arg, P + 1, MaxInt);
    end
    else
    begin
      Name := LowerCase(Arg);
      Value := '';
      P := 0;
    end;
    if Name = '--versions' then
    begin
      if not NeedValue then
        Exit;
      AOpts.Versions := TextToVersions(Value);
    end
    else if Name = '--dest' then
    begin
      if not NeedValue then
        Exit;
      AOpts.Dest := Value;
    end
    else if Name = '--source' then
    begin
      if not NeedValue then
        Exit;
      AOpts.Source := Value;
    end
    else if Name = '--config' then
    begin
      if not NeedValue then
        Exit;
      AOpts.ConfigFile := Value;
    end
    else if Name = '--categories' then
    begin
      if not NeedValue then
        Exit;
      try
        AOpts.Categories := ParseCategories(Value);
      except
        on E: Exception do
        begin
          Say('Erro: ' + E.Message +
            ' (valores válidos: components, ide-config, experts, boss, extra, system-dll)');
          Exit;
        end;
      end;
      AOpts.CategoriesGiven := True;
    end
    else if Name = '--no-zip' then
      AOpts.NoZip := True
    else if Name = '--scan-dlls' then
      AOpts.ScanDlls := True
    else
    begin
      Say('Erro: opção desconhecida "' + Arg + '".');
      Exit;
    end;
    Inc(I);
  end;
  Result := True;
end;

function LevelPrefix(ALevel: TLogLevel): string;
begin
  case ALevel of
    llWarn:
      Result := 'AVISO: ';
    llError:
      Result := 'ERRO: ';
  else
    Result := '';
  end;
end;

function CreateConsoleLogger: ILogger;
begin
  Result := CreateLogger;
  Result.AddSink(procedure(ALevel: TLogLevel; const AMessage: string)
    begin
      if ALevel <> llDebug then
        Say(LevelPrefix(ALevel) + AMessage);
    end);
end;

function LoadConfig(const AOpts: TCliOptions; const ALogger: ILogger)
  : TToolConfig;
var
  FileName: string;
begin
  Result := TToolConfig.Create;
  FileName := AOpts.ConfigFile;
  if FileName = '' then
    FileName := ExtractFilePath(ParamStr(0)) + CONFIG_FILE_NAME
  else if not FileExists(FileName) then
    ALogger.Warn('Arquivo de configuração não encontrado: ' + FileName);
  if FileExists(FileName) then
  begin
    ALogger.Info('Usando configuração: ' + FileName);
    LoadToolConfig(FileName, Result, ALogger);
  end;
end;

{ Builds a non-owning list with the requested versions. Prints an error and returns
  False when one of them is not installed. }
function SelectVersions(const AOpts: TCliOptions;
AInstalled: TDelphiVersionList; ASelected: TDelphiVersionList;
out ABds: TArray<string>): Boolean;
var
  V: TDelphiVersion;
  S: string;
begin
  Result := True;
  SetLength(ABds, 0);
  if Length(AOpts.Versions) = 0 then
  begin
    for V in AInstalled do
      ASelected.Add(V);
  end
  else
    for S in AOpts.Versions do
    begin
      V := AInstalled.FindByBds(S);
      if V = nil then
      begin
        Say('Erro: a versão ' + S +
          ' não está instalada. Use o comando list para ver as versões.');
        Exit(False);
      end;
      ASelected.Add(V);
    end;
  for V in ASelected do
  begin
    SetLength(ABds, Length(ABds) + 1);
    ABds[High(ABds)] := V.BdsVersion;
  end;
end;

function CmdList(const ALogger: ILogger): Integer;
var
  Installed: TDelphiVersionList;
  V: TDelphiVersion;
begin
  Installed := TDelphiVersionList.Create(True);
  try
    CreateVersionDetector(ALogger).Detect(Installed);
    if Installed.Count = 0 then
    begin
      Say('Nenhuma versão do Delphi encontrada.');
      Exit(EXIT_OK);
    end;
    for V in Installed do
      Say(Format('%-8s %s  [%s]', [V.BdsVersion, V.DisplayName, V.RootDir]));
    Result := EXIT_OK;
  finally
    Installed.Free;
  end;
end;

function CmdBackup(const AOpts: TCliOptions; const ALogger: ILogger): Integer;
var
  Installed, Selected: TDelphiVersionList;
  Items, Dlls: TBackupItemList;
  Config: TToolConfig;
  Runner: IProcessRunner;
  Engine: TBackupEngine;
  Options: TBackupOptions;
  Bds: TArray<string>;
  It: TBackupItem;
  Added, I, Failures: Integer;
  OutPath: string;
begin
  Failures := 0;
  if AOpts.Dest = '' then
  begin
    Say('Erro: o comando backup exige --dest <pasta>.');
    Exit(EXIT_USAGE);
  end;
  Installed := TDelphiVersionList.Create(True);
  Selected := TDelphiVersionList.Create(False);
  Items := TBackupItemList.Create(True);
  Config := LoadConfig(AOpts, ALogger);
  try
    CreateVersionDetector(ALogger).Detect(Installed);
    if Installed.Count = 0 then
    begin
      Say('Erro: nenhuma versão do Delphi instalada.');
      Exit(EXIT_PRECHECK);
    end;
    if not SelectVersions(AOpts, Installed, Selected, Bds) then
      Exit(EXIT_PRECHECK);

    ALogger.Info('Descobrindo itens para backup...');
    CreatePathDiscovery(ALogger).Discover(Selected, Config, Items);

    Options.Versions := Bds;
    Options.Destination := AOpts.Dest;
    Options.CreateZip := not AOpts.NoZip;
    Options.ScanDlls := AOpts.ScanDlls;
    if AOpts.CategoriesGiven then
      Options.Categories := AOpts.Categories
    else
      Options.Categories := DefaultBackupCategories;

    if AOpts.ScanDlls then
    begin
      Include(Options.Categories, icSystemDll);
      ALogger.Info('Procurando DLLs de terceiros (pode demorar)...');
      Dlls := TBackupItemList.Create(True);
      try
        CreateDllScanner(ALogger).Scan(Selected, Items, Dlls);
        Added := 0;
        for I := Dlls.Count - 1 downto 0 do
        begin
          It := Dlls[I];
          if It.ReinstalledByIde then
            Continue;
          Dlls.Extract(It);
          It.Selected := True;
          Items.Add(It);
          Inc(Added);
          Say(Format('  DLL: %s  %s  %s', [It.SourcePath, It.Company,
            It.FileVersion]));
        end;
        ALogger.Info(Format('%d DLL(s) de terceiros incluída(s) no backup.',
          [Added]));
      finally
        Dlls.Free;
      end;
    end;

    { Items of categories not requested are ignored by the engine; mark the rest selected }
    for It in Items do
      if It.Kind <> ikDll then
        It.Selected := It.Category in Options.Categories;

    Runner := CreateProcessRunner(ALogger);
    Engine := TBackupEngine.Create(ALogger, Runner);
    try
      OutPath := Engine.Execute(Options, Selected, Items, Config,
        procedure(ACurrent, ATotal: Integer; const AStep: string)
        begin
          Say(Format('[%d/%d] %s', [ACurrent, ATotal, AStep]));
        end);
      Failures := Engine.FailureCount;
    finally
      Engine.Free;
    end;
    if Failures > 0 then
    begin
      Say(Format('Backup concluído com %d falha(s): %s (veja o backup.log)',
        [Failures, OutPath]));
      Result := EXIT_ERROR;
    end
    else
    begin
      Say('Backup concluído: ' + OutPath);
      Result := EXIT_OK;
    end;
  finally
    Config.Free;
    Items.Free;
    Selected.Free;
    Installed.Free;
  end;
end;

function CmdRestore(const AOpts: TCliOptions; const ALogger: ILogger): Integer;
var
  Installed: TDelphiVersionList;
  Engine: TRestoreEngine;
  Options: TRestoreOptions;
begin
  if AOpts.Source = '' then
  begin
    Say('Erro: o comando restore exige --source <pasta|zip>.');
    Exit(EXIT_USAGE);
  end;
  Installed := TDelphiVersionList.Create(True);
  Engine := TRestoreEngine.Create(ALogger, CreateProcessRunner(ALogger));
  try
    CreateVersionDetector(ALogger).Detect(Installed);
    Engine.Open(AOpts.Source);
    Options.Source := AOpts.Source;
    Options.Versions := AOpts.Versions;
    if AOpts.CategoriesGiven then
      Options.Categories := AOpts.Categories
    else
      Options.Categories := AllCategories;
    Engine.Precheck(Options, Installed);
    Engine.Execute(Options, Installed,
      procedure(ACurrent, ATotal: Integer; const AStep: string)
      begin
        Say(Format('[%d/%d] %s', [ACurrent, ATotal, AStep]));
      end);
    Say('Restauração concluída.');
    Result := EXIT_OK;
  finally
    Engine.Free;
    Installed.Free;
  end;
end;

function DiffMark(AKind: TDiffKind): string;
begin
  case AKind of
    dkAdded:
      Result := '+';
    dkRemoved:
      Result := '-';
    dkChanged:
      Result := '~';
  else
    Result := 'i';
  end;
end;

function CmdCompare(const AOpts: TCliOptions; const ALogger: ILogger): Integer;
var
  Installed: TDelphiVersionList;
  Config: TToolConfig;
  Engine: TCompareEngine;
  Options: TCompareOptions;
  Res: TCompareResult;
  E: TDiffEntry;
  Line: string;
begin
  if AOpts.Source = '' then
  begin
    Say('Erro: o comando compare exige --source <pasta|zip>.');
    Exit(EXIT_USAGE);
  end;
  Installed := TDelphiVersionList.Create(True);
  Config := LoadConfig(AOpts, ALogger);
  Engine := TCompareEngine.Create(ALogger, CreateProcessRunner(ALogger));
  try
    CreateVersionDetector(ALogger).Detect(Installed);
    Options.Source := AOpts.Source;
    Options.Versions := AOpts.Versions;
    Res := Engine.Execute(Options, Installed, Config);
    try
      for E in Res.Entries do
      begin
        Line := Format('%s %s', [DiffMark(E.Kind), E.Path]);
        if E.Detail <> '' then
          Line := Line + '  (' + E.Detail + ')';
        Say(Line);
      end;
      if Res.HasDifferences then
      begin
        Say('Existem diferenças entre o backup e o ambiente atual.');
        Result := EXIT_DIFFERENCES;
      end
      else
      begin
        Say('Nenhuma diferença encontrada.');
        Result := EXIT_OK;
      end;
    finally
      Res.Free;
    end;
  finally
    Engine.Free;
    Config.Free;
    Installed.Free;
  end;
end;

function RunCli: Integer;
var
  Opts: TCliOptions;
  Cmd: string;
  Logger: ILogger;
begin
  ConsoleInit;
  Cmd := LowerCase(ParamStr(1));
  if (Cmd = '--help') or (Cmd = '-h') or (Cmd = '/?') or (Cmd = 'help') then
  begin
    ShowHelp;
    Exit(EXIT_OK);
  end;
  if (Cmd = '--version') or (Cmd = '-v') then
  begin
    Say(TOOL_NAME + ' ' + ToolVersion);
    Exit(EXIT_OK);
  end;
  if (Cmd <> 'list') and (Cmd <> 'backup') and (Cmd <> 'restore') and
    (Cmd <> 'compare') then
  begin
    Say('Erro: comando desconhecido "' + ParamStr(1) + '". Use --help.');
    Exit(EXIT_USAGE);
  end;
  if not ParseArgs(Opts) then
    Exit(EXIT_USAGE);

  Logger := CreateConsoleLogger;
  try
    if Cmd = 'list' then
      Result := CmdList(Logger)
    else if Cmd = 'backup' then
      Result := CmdBackup(Opts, Logger)
    else if Cmd = 'restore' then
      Result := CmdRestore(Opts, Logger)
    else
      Result := CmdCompare(Opts, Logger);
  except
    on E: EPrecheckError do
    begin
      Say('Pré-requisito não atendido: ' + E.Message);
      Result := EXIT_PRECHECK;
    end;
    on E: Exception do
    begin
      Say('Erro: ' + E.Message);
      Result := EXIT_ERROR;
    end;
  end;
end;

end.
