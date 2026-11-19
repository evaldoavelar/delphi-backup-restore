unit Core.VersionDetector;

interface

uses Core.Types;

function CreateVersionDetector(const ALogger: ILogger): IVersionDetector;

implementation

uses
  System.SysUtils, System.Classes, System.Win.Registry, Winapi.Windows,
  Core.VersionCatalog, Core.SystemUtils;

type
  TVersionDetector = class(TInterfacedObject, IVersionDetector)
  private
    FLogger: ILogger;
    procedure ScanRoot(AList: TDelphiVersionList; AEra: TDelphiEra; const ARegistryRoot: string;
      ARootKey: HKEY; AAccess: LongInt; AWowNode: Boolean);
    procedure AddVersion(AList: TDelphiVersionList; AEra: TDelphiEra; const ARegistryRoot,
      ABdsVersion: string; ARootKey: HKEY; AAccess: LongInt; AWowNode: Boolean);
    function ReadUpdates(ARegistry: TRegistry; const AKey: string): string;
  public
    constructor Create(const ALogger: ILogger);
    procedure Detect(AList: TDelphiVersionList);
  end;

function CreateVersionDetector(const ALogger: ILogger): IVersionDetector;
begin Result := TVersionDetector.Create(ALogger); end;

constructor TVersionDetector.Create(const ALogger: ILogger);
begin inherited Create; FLogger := ALogger; end;

function TVersionDetector.ReadUpdates(ARegistry: TRegistry; const AKey: string): string;
var Names: TStringList; I: Integer;
begin
  Result := '';
  if not ARegistry.OpenKeyReadOnly(AKey + '\InstalledUpdates') then Exit;
  Names := TStringList.Create;
  try
    ARegistry.GetValueNames(Names);
    for I := 0 to Names.Count - 1 do
    begin
      if Result <> '' then Result := Result + ';';
      Result := Result + Names[I] + '=' + ARegistry.ReadString(Names[I]);
    end;
  finally Names.Free; ARegistry.CloseKey; end;
end;

procedure TVersionDetector.AddVersion(AList: TDelphiVersionList; AEra: TDelphiEra;
  const ARegistryRoot, ABdsVersion: string; ARootKey: HKEY; AAccess: LongInt; AWowNode: Boolean);
var Reg: TRegistry; Key, Root, BinExe, Common, Base, AppBase: string; V: TDelphiVersion;
begin
  Reg := TRegistry.Create(AAccess);
  try
    Reg.RootKey := ARootKey;
    Key := ARegistryRoot;
      if AWowNode then Key := StringReplace(Key, 'Software\', 'Software\WOW6432Node\', []);
    Key := Key + '\' + ABdsVersion;
    if not Reg.OpenKeyReadOnly(Key) then Exit;
    try
      if Reg.ValueExists('RootDir') then Root := Reg.ReadString('RootDir') else Root := '';
      if Root = '' then Exit;
      Root := IncludeTrailingPathDelimiter(ExpandEnvVars(Root));
      BinExe := IncludeTrailingPathDelimiter(Root) + 'bin\bds.exe';
      if not FileExists(BinExe) then
      begin
        BinExe := IncludeTrailingPathDelimiter(Root) + 'bin\delphi32.exe';
        if not FileExists(BinExe) then Exit;
      end;
      if AList.FindByBds(ABdsVersion) <> nil then Exit;
      V := TDelphiVersion.Create;
      V.BdsVersion := ABdsVersion;
      V.Major := StrToIntDef(Copy(ABdsVersion, 1, Pos('.', ABdsVersion) - 1), 0);
      V.Minor := StrToIntDef(Copy(ABdsVersion, Pos('.', ABdsVersion) + 1, MaxInt), 0);
      V.Era := AEra;
      V.ProductName := ProductNameForVersion(AEra, ABdsVersion);
      V.RegistryKey := ARegistryRoot + '\' + ABdsVersion;
      V.RootDir := Root;
      V.ProductVersion := '';
      if Reg.ValueExists('ProductVersion') then V.ProductVersion := Reg.ReadString('ProductVersion');
      V.InstalledUpdates := ReadUpdates(Reg, Key);
      Common := '';
      if Reg.OpenKeyReadOnly('Environment Variables') then
      try
        if Reg.ValueExists('BDSCOMMONDIR') then Common := Reg.ReadString('BDSCOMMONDIR');
      finally Reg.CloseKey; end;
      if Common = '' then
      begin
        Base := GetPublicDir;
        if AEra = deBorlandDelphi then Common := IncludeTrailingPathDelimiter(Base) + 'Documents\Borland\Studio'
        else Common := IncludeTrailingPathDelimiter(Base) + 'Documents\' + StudioFolderName(AEra);
        Common := IncludeTrailingPathDelimiter(Common) + ABdsVersion;
      end;
      V.CommonDir := ExcludeTrailingPathDelimiter(ExpandEnvVars(Common));
      Base := GetDocumentsDir;
      V.UserDir := ExcludeTrailingPathDelimiter(IncludeTrailingPathDelimiter(Base) + StudioFolderName(AEra) + '\' + ABdsVersion);
      AppBase := GetAppDataDir;
      if AEra = deBorlandDelphi then
        V.AppDataDir := ExcludeTrailingPathDelimiter(IncludeTrailingPathDelimiter(AppBase) + 'Borland\Delphi\' + ABdsVersion)
      else if AEra = deBorlandBDS then
        V.AppDataDir := ExcludeTrailingPathDelimiter(IncludeTrailingPathDelimiter(AppBase) + 'Borland\BDS\' + ABdsVersion)
      else if AEra = deCodeGear then
        V.AppDataDir := ExcludeTrailingPathDelimiter(IncludeTrailingPathDelimiter(AppBase) + 'CodeGear\BDS\' + ABdsVersion)
      else
        V.AppDataDir := ExcludeTrailingPathDelimiter(IncludeTrailingPathDelimiter(AppBase) + 'Embarcadero\BDS\' + ABdsVersion);
      AList.Add(V);
      if Assigned(FLogger) then FLogger.Info('Delphi instalado detectado: ' + V.DisplayName);
    finally Reg.CloseKey; end;
  finally Reg.Free; end;
end;

procedure TVersionDetector.ScanRoot(AList: TDelphiVersionList; AEra: TDelphiEra;
  const ARegistryRoot: string; ARootKey: HKEY; AAccess: LongInt; AWowNode: Boolean);
var Reg: TRegistry; Key: string; Names: TStringList; I: Integer;
begin
  Key := ARegistryRoot;
  if AWowNode then Key := StringReplace(Key, 'Software\', 'Software\WOW6432Node\', []);
  Reg := TRegistry.Create(AAccess);
  try
    Reg.RootKey := ARootKey;
    if not Reg.OpenKeyReadOnly(Key) then Exit;
    Names := TStringList.Create;
    try
      Reg.GetKeyNames(Names);
    finally Reg.CloseKey; end;
  finally Reg.Free; end;
  for I := 0 to Names.Count - 1 do
    AddVersion(AList, AEra, ARegistryRoot, Names[I], ARootKey, AAccess, AWowNode);
  Names.Free;
end;

procedure TVersionDetector.Detect(AList: TDelphiVersionList);
var Era: TDelphiEra; Root: string;
begin
  if not Assigned(AList) then raise EDelphiBackupError.Create('A lista de versões não foi informada.');
  if Assigned(FLogger) then FLogger.Info('Procurando instalações do Delphi no Registro do Windows.');
  for Era := Low(TDelphiEra) to High(TDelphiEra) do
  begin
    Root := RegistryRootForEra(Era);
    ScanRoot(AList, Era, Root, HKEY_LOCAL_MACHINE, KEY_READ or KEY_WOW64_32KEY, False);
    ScanRoot(AList, Era, Root, HKEY_LOCAL_MACHINE, KEY_READ or KEY_WOW64_64KEY, False);
    ScanRoot(AList, Era, Root, HKEY_LOCAL_MACHINE, KEY_READ or KEY_WOW64_64KEY, True);
    ScanRoot(AList, Era, Root, HKEY_CURRENT_USER, KEY_READ, False);
  end;
  AList.SortOldestFirst;
  if Assigned(FLogger) then FLogger.Info(Format('Busca concluída: %d versão(ões) encontrada(s).', [AList.Count]));
end;

end.
