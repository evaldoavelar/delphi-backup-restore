unit Core.PathDiscovery;

interface

uses System.Classes, Core.Types;

function CreatePathDiscovery(const ALogger: ILogger): IPathDiscovery;
function ResolveBdsMacros(const AText: string; AVersion: TDelphiVersion;
  const APlatform: string): string;
procedure ReduceToRootFolders(APaths: TStrings);
function LoadToolConfig(const AFileName: string; AConfig: TToolConfig;
  const ALogger: ILogger): Boolean;

type
  { Safety rules for backup roots (docs/ARCHITECTURE.md, "Regras de seguranca").
    A backup root must never be a system container (drive root, Windows, Program
    Files, ProgramData, Users, profile, Documents, AppData, Public) and must never
    contain the install or config folders of an installed Delphi. }
  TPathSafety = class
  private
    FContainers: TStringList; // never a backup root
    FForbidden: TStringList; // nothing inside these is ever backed up
    FProtected: TStringList; // install + IDE config dirs of every known version
    procedure AddTo(AList: TStringList; const APath: string);
  public
    constructor Create(AVersions: TDelphiVersionList);
    destructor Destroy; override;
    function IsContainer(const APath: string): Boolean;
    function IsForbidden(const APath: string): Boolean;
    function ContainsProtected(const APath: string): Boolean;
    function IsInsideProtected(const APath: string): Boolean;
    { True for folders that must never be copied as a whole. }
    function IsUnsafeRoot(const APath: string): Boolean;
    { Highest safe ancestor of a library folder, stopping before containers,
      before folders holding a Delphi install/config and at VCS roots.
      Returns '' when the folder itself is unsafe. }
    function ComponentRoot(const APath: string): string;
  end;

function IsVcsRoot(const APath: string): Boolean;

implementation

uses System.SysUtils, System.IOUtils, System.JSON, System.Win.Registry,
  System.Generics.Collections,
  Winapi.Windows, Winapi.ShlObj, Core.SystemUtils, Core.VersionDetector;

type
  TPathDiscovery = class(TInterfacedObject, IPathDiscovery)
  private
    FLogger: ILogger;
    FSafety: TPathSafety;
    procedure AddItem(AItems: TBackupItemList; AKind: TItemKind;
      ACategory: TItemCategory; const APath, AVersion: string);
    procedure ReadPaths(AVersion: TDelphiVersion; AItems: TBackupItemList);
  public
    constructor Create(const ALogger: ILogger);
    destructor Destroy; override;
    procedure Discover(AVersions: TDelphiVersionList; AConfig: TToolConfig;
      AItems: TBackupItemList);
  end;

function ResolveBdsMacros(const AText: string; AVersion: TDelphiVersion;
  const APlatform: string): string;
  procedure ReplaceMacro(const AName, AValue: string);
  begin
    Result := StringReplace(Result, '$(' + AName + ')', AValue,
      [rfReplaceAll, rfIgnoreCase]);
  end;

begin
  Result := AText;
  ReplaceMacro('BDSCOMMONDIR', AVersion.CommonDir);
  ReplaceMacro('BDSUSERDIR', AVersion.UserDir);
  ReplaceMacro('BDSLIB', IncludeTrailingPathDelimiter(AVersion.RootDir)
    + 'lib');
  ReplaceMacro('BDSINCLUDE', IncludeTrailingPathDelimiter(AVersion.RootDir) +
    'include');
  ReplaceMacro('BDSBIN', IncludeTrailingPathDelimiter(AVersion.RootDir)
    + 'bin');
  ReplaceMacro('BDS', AVersion.RootDir);
  ReplaceMacro('Platform', APlatform);
  ReplaceMacro('Config', 'Release');
  Result := ExpandEnvVars(Result);
  if (Pos('$(', Result) > 0) or (Pos('%', Result) > 0) then
    Result := '';
end;

procedure ReduceToRootFolders(APaths: TStrings);
var
  I, J: Integer;
  P, Q: string;
begin
  I := APaths.Count - 1;
  while I >= 0 do
  begin
    P := ExcludeTrailingPathDelimiter(APaths[I]);
    for J := 0 to APaths.Count - 1 do
      if I <> J then
      begin
        Q := ExcludeTrailingPathDelimiter(APaths[J]);
        if (SameText(P, Q) and (J < I)) or
          ((Length(P) > Length(Q)) and SameText(Copy(P, 1, Length(Q) + 1),
          Q + '\')) then
        begin
          APaths.Delete(I);
          Break;
        end;
      end;
    Dec(I);
  end;
end;

function LoadToolConfig(const AFileName: string; AConfig: TToolConfig;
  const ALogger: ILogger): Boolean;
var
  V: TJSONValue;
  O: TJSONObject;
  procedure ReadList(const AName: string; AList: TStrings);
  var
    A: TJSONArray;
    X: TJSONValue;
    I: Integer;
  begin
    X := O.Values[AName];
    if X = nil then
      Exit;
    if not(X is TJSONArray) then
      raise EDelphiBackupError.Create('Lista inválida: ' + AName);
    A := TJSONArray(X);
    for I := 0 to A.Count - 1 do
      AList.Add(A.Items[I].Value);
  end;

begin
  ALogger.Debug('Carregando configuração: ' + AFileName);
  Result := False;
  if not TFile.Exists(AFileName) then
  begin
    ALogger.Info('Arquivo de configuração não encontrado.');
    Exit;
  end;
  V := nil;
  try
    V := TJSONObject.ParseJSONValue(TFile.ReadAllText(AFileName,
      TEncoding.UTF8));
    if not(V is TJSONObject) then
      raise EDelphiBackupError.Create('Configuração JSON inválida.');
    O := TJSONObject(V);
    ReadList('extraFolders', AConfig.ExtraFolders);
    ReadList('extraRegistryKeys', AConfig.ExtraRegistryKeys);
    ReadList('excludeDirs', AConfig.ExcludeDirs);
    ReadList('excludeFiles', AConfig.ExcludeFiles);
    Result := True;
    ALogger.Info('Configuração carregada.');
  except
    on E: Exception do
    begin
      ALogger.Error('Erro ao carregar configuração: ' + E.Message);
      V.Free;
      raise;
    end;
  end;
  V.Free;
end;

constructor TPathDiscovery.Create(const ALogger: ILogger);
begin
  inherited Create;
  FLogger := ALogger;
  FLogger.Debug('Criando descoberta de caminhos.');
end;

procedure TPathDiscovery.AddItem(AItems: TBackupItemList; AKind: TItemKind;
  ACategory: TItemCategory; const APath, AVersion: string);
var
  It: TBackupItem;
  P: string;
begin
  P := Trim(APath);
  if P = '' then
    Exit;
  if (AKind = ikFolder) and not DirectoryExists(P) then
    Exit;
  if (AKind = ikFile) and not FileExists(P) then
    Exit;
  It := AItems.FindBySource(AKind, P);
  if It = nil then
  begin
    It := TBackupItem.Create;
    It.Id := AItems.NextId(AKind);
    It.Kind := AKind;
    It.Category := ACategory;
    It.SourcePath := P;
    It.Description := P;
    AItems.Add(It);
  end;
  if AVersion <> '' then
    It.Versions.Add(AVersion);
end;

function IsVcsRoot(const APath: string): Boolean;
var
  Base: string;
begin
  Base := IncludeTrailingPathDelimiter(APath);
  Result := DirectoryExists(Base + '.git') or FileExists(Base + '.git') or
    DirectoryExists(Base + '.svn') or DirectoryExists(Base + '.hg');
end;

function CommonDocumentsDir: string;
var
  Buffer: array [0 .. MAX_PATH] of Char;
begin
  Result := '';
  if SHGetFolderPath(0, CSIDL_COMMON_DOCUMENTS, 0, 0, Buffer) = S_OK then
    Result := Buffer;
end;

{ TPathSafety }

constructor TPathSafety.Create(AVersions: TDelphiVersionList);
var
  V: TDelphiVersion;
  Profile: string;
begin
  inherited Create;
  FContainers := TStringList.Create;
  FForbidden := TStringList.Create;
  FProtected := TStringList.Create;
  Profile := GetUserProfileDir;
  { 32-bit process: ProgramFiles = "Program Files (x86)"; ProgramW6432 = the 64-bit one }
  AddTo(FContainers, GetEnvironmentVariable('SystemRoot'));
  AddTo(FContainers, GetEnvironmentVariable('ProgramW6432'));
  AddTo(FContainers, GetEnvironmentVariable('ProgramFiles'));
  AddTo(FContainers, GetEnvironmentVariable('ProgramFiles(x86)'));
  AddTo(FContainers, GetEnvironmentVariable('ProgramData'));
  AddTo(FContainers, GetEnvironmentVariable('LOCALAPPDATA'));
  AddTo(FContainers, GetAppDataDir);
  AddTo(FContainers, GetDocumentsDir);
  AddTo(FContainers, GetPublicDir);
  AddTo(FContainers, CommonDocumentsDir);
  AddTo(FContainers, Profile);
  if Profile <> '' then
    AddTo(FContainers, ExtractFileDir(ExcludeTrailingPathDelimiter(Profile)));
  AddTo(FForbidden, GetEnvironmentVariable('SystemRoot'));
  if AVersions <> nil then
    for V in AVersions do
    begin
      AddTo(FProtected, V.RootDir);
      AddTo(FProtected, V.CommonDir);
      AddTo(FProtected, V.UserDir);
      AddTo(FProtected, V.AppDataDir);
    end;
end;

destructor TPathSafety.Destroy;
begin
  FProtected.Free;
  FForbidden.Free;
  FContainers.Free;
  inherited;
end;

procedure TPathSafety.AddTo(AList: TStringList; const APath: string);
var
  P: string;
begin
  P := NormalizePath(APath);
  if (P <> '') and (AList.IndexOf(P) < 0) then
    AList.Add(P);
end;

function TPathSafety.IsContainer(const APath: string): Boolean;
var
  P: string;
  I: Integer;
begin
  P := NormalizePath(APath);
  { drive roots ("C:", "C:\") and UNC share roots ("\\server\share") }
  Result := (P = '') or (Length(P) <= 3) or
    ((Copy(P, 1, 2) = '\\') and (Length(ExtractFileDir(P)) <= 2));
  if Result then
    Exit;
  for I := 0 to FContainers.Count - 1 do
    if SameText(P, FContainers[I]) then
      Exit(True);
end;

function TPathSafety.IsForbidden(const APath: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FForbidden.Count - 1 do
    if IsPathInside(APath, FForbidden[I]) then
      Exit(True);
end;

function TPathSafety.ContainsProtected(const APath: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FProtected.Count - 1 do
    if IsPathInside(FProtected[I], APath) then
      Exit(True);
end;

function TPathSafety.IsInsideProtected(const APath: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FProtected.Count - 1 do
    if IsPathInside(APath, FProtected[I]) then
      Exit(True);
end;

function TPathSafety.IsUnsafeRoot(const APath: string): Boolean;
begin
  Result := IsContainer(APath) or IsForbidden(APath) or ContainsProtected(APath);
end;

function TPathSafety.ComponentRoot(const APath: string): string;
var
  Current, Parent: string;
begin
  Result := '';
  Current := NormalizePath(APath);
  if (Current = '') or IsUnsafeRoot(Current) or IsInsideProtected(Current) then
    Exit;
  Result := Current;
  while not IsVcsRoot(Result) do
  begin
    Parent := ExcludeTrailingPathDelimiter(ExtractFileDir(Result));
    if (Parent = '') or SameText(Parent, Result) then
      Break;
    if IsUnsafeRoot(Parent) then
      Break;
    Result := Parent;
  end;
end;

{ TPathDiscovery }

destructor TPathDiscovery.Destroy;
begin
  FSafety.Free;
  inherited;
end;

procedure TPathDiscovery.ReadPaths(AVersion: TDelphiVersion;
  AItems: TBackupItemList);
var
  R: TRegistry;
  Platforms, Names, Parts: TStringList;
  I, J, K, L: Integer;
  Key, Platform, Name, Value, P, Root, Company: string;
  procedure AddPath(const AText: string; AExpert: Boolean);
  begin
    P := Trim(StringReplace(AText, '"', '', [rfReplaceAll]));
    P := ResolveBdsMacros(P, AVersion, Platform);
    if (P = '') or (Pos('..\', P) = 1) or (Pos(':', Copy(P, 3, MaxInt)) > 0)
    then
      Exit;
    if FileExists(P) then
    begin
      if AExpert then
      begin
        if IsPathInside(P, AVersion.RootDir) then
        begin
          if (L = 3) and SameText(ExtractFileDir(P),
            IncludeTrailingPathDelimiter(ExcludeTrailingPathDelimiter
            (AVersion.RootDir)) + 'bin') then
          begin
            Company := GetFileCompany(P);
            if (Company <> '') and (Pos('EMBARCADERO', UpperCase(Company)) = 0)
              and (Pos('BORLAND', UpperCase(Company)) = 0) and
              (Pos('CODEGEAR', UpperCase(Company)) = 0) then
              AddItem(AItems, ikFile, icExperts, P, AVersion.BdsVersion);
          end;
        end
        else
          AddItem(AItems, ikFolder, icExperts, ExtractFileDir(P),
            AVersion.BdsVersion);
      end
      else
        P := ExtractFileDir(P);
      if AExpert then
        Exit;
    end;
    if not DirectoryExists(P) or IsPathInside(P, AVersion.RootDir) then
      Exit;
    Root := FSafety.ComponentRoot(P);
    if Root = '' then
    begin
      FLogger.Debug('Caminho ignorado por segurança (pasta de sistema ou da IDE): '
        + P);
      Exit;
    end;
    AddItem(AItems, ikFolder, icComponents, Root, AVersion.BdsVersion);
  end;

begin
  R := TRegistry.Create(KEY_READ);
  Platforms := TStringList.Create;
  Names := TStringList.Create;
  Parts := TStringList.Create;
  try
    R.RootKey := HKEY_CURRENT_USER;
    Key := AVersion.RegistryKey + '\Library';
    if R.OpenKeyReadOnly(Key) then
    begin
      R.GetKeyNames(Platforms);
      R.CloseKey;
    end;
    for I := 0 to Platforms.Count - 1 do
    begin
      Platform := Platforms[I];
      if R.OpenKeyReadOnly(Key + '\' + Platform) then
      begin
        Names.Clear;
        R.GetValueNames(Names);
        for J := 0 to Names.Count - 1 do
        begin
          Name := Names[J];
          if SameText(Name, 'Search Path') or SameText(Name, 'Browsing Path') or
            SameText(Name, 'Package DPL Output') or
            SameText(Name, 'Package DCP Output') or
            SameText(Name, 'Debug DCU Path') then
          begin
            try
              Value := R.ReadString(Name);
            except
              on E: Exception do
              begin
                FLogger.Warn('Valor de registro inválido: ' + Name + ': ' +
                  E.Message);
                Continue;
              end;
            end;
            Parts.StrictDelimiter := True;
            Parts.Delimiter := ';';
            Parts.DelimitedText := Value;
            for K := 0 to Parts.Count - 1 do
              AddPath(Parts[K], False);
          end;
        end;
        R.CloseKey;
      end;
    end;
    Platform := 'Win32';
    { 'Environment Variables\PATH' is NOT a source: it snapshots the whole system
      PATH (Program Files, Windows). It is restored with the IDE registry key. }
    for L := 0 to 3 do
    begin
      case L of
        0:
          Key := 'Known Packages';
        1:
          Key := 'Known IDE Packages';
        2:
          Key := 'Disabled Packages';
      else
        Key := 'Experts';
      end;
      if R.OpenKeyReadOnly(AVersion.RegistryKey + '\' + Key) then
      begin
        Names.Clear;
        R.GetValueNames(Names);
        for J := 0 to Names.Count - 1 do
        begin
          Name := Names[J];
          try
            Value := R.ReadString(Name);
          except
            on E: Exception do
            begin
              FLogger.Warn('Valor de registro inválido: ' + Name + ': ' +
                E.Message);
              Continue;
            end;
          end;
          AddPath(Name, L in [1, 3]);
          if L = 3 then
            AddPath(Value, True);
        end;
        R.CloseKey;
      end;
    end;
  finally
    Parts.Free;
    Names.Free;
    Platforms.Free;
    R.Free;
  end;
end;

procedure TPathDiscovery.Discover(AVersions: TDelphiVersionList;
  AConfig: TToolConfig; AItems: TBackupItemList);
var
  V: TDelphiVersion;
  R: TRegistry;
  S: string;
  I, J, K: Integer;
  Child, Parent, It: TBackupItem;
  Installed: TDelphiVersionList;
begin
  FLogger.Info('Iniciando descoberta de caminhos.');
  { protect the install/config folders of EVERY installed version, not only the
    selected ones, so a component root never swallows another IDE }
  Installed := TDelphiVersionList.Create(True);
  try
    CreateVersionDetector(FLogger).Detect(Installed);
    FreeAndNil(FSafety);
    FSafety := TPathSafety.Create(Installed);
  finally
    Installed.Free;
  end;
  try
    for V in AVersions do
    begin
      AddItem(AItems, ikFolder, icIdeConfig, V.CommonDir, V.BdsVersion);
      AddItem(AItems, ikFolder, icIdeConfig, V.UserDir, V.BdsVersion);
      AddItem(AItems, ikFolder, icIdeConfig, V.AppDataDir, V.BdsVersion);
      AddItem(AItems, ikRegistry, icIdeConfig, 'HKCU\' + V.RegistryKey,
        V.BdsVersion);
      S := V.RegistryKey;
      if SameText(Copy(S, 1, 9), 'Software\') then
        Delete(S, 1, 9);
      AddItem(AItems, ikRegistry, icIdeConfig, 'HKLM\SOFTWARE\' + S,
        V.BdsVersion);
      ReadPaths(V, AItems);
    end;
    R := TRegistry.Create(KEY_READ);
    try
      R.RootKey := HKEY_CURRENT_USER;
      for I := 0 to 2 do
      begin
        case I of
          0:
            S := 'Software\GExperts';
          1:
            S := 'Software\CnPack';
        else
          S := 'Software\Scooter Software';
        end;
        if R.KeyExists(S) then
          AddItem(AItems, ikRegistry, icExperts, 'HKCU\' + S, '');
      end;
    finally
      R.Free;
    end;
    AddItem(AItems, ikFolder, icBoss,
      IncludeTrailingPathDelimiter(GetUserProfileDir) + '.boss', '');
    if AConfig <> nil then
    begin
      for I := 0 to AConfig.ExtraFolders.Count - 1 do
        AddItem(AItems, ikFolder, icExtra,
          ExpandEnvVars(AConfig.ExtraFolders[I]), '');
      for I := 0 to AConfig.ExtraRegistryKeys.Count - 1 do
        AddItem(AItems, ikRegistry, icExtra, AConfig.ExtraRegistryKeys[I], '');
    end;
    I := AItems.Count - 1;
    while I >= 0 do
    begin
      Child := AItems[I];
      if (Child.Kind = ikFolder) and (Child.Category = icComponents) then
        for J := 0 to AItems.Count - 1 do
        begin
          Parent := AItems[J];
          if (I <> J) and (Parent.Kind = ikFolder) and
            (Parent.Category = icComponents) and IsPathInside(Child.SourcePath,
            Parent.SourcePath) then
          begin
            for K := 0 to Child.Versions.Count - 1 do
              Parent.Versions.Add(Child.Versions[K]);
            AItems.Delete(I);
            Break;
          end;
        end;
      Dec(I);
    end;
    { last line of defense: drop any folder that is a system container, lies in a
      forbidden area or would include a Delphi install }
    for I := AItems.Count - 1 downto 0 do
    begin
      It := AItems[I];
      if It.Kind <> ikFolder then
        Continue;
      if FSafety.IsContainer(It.SourcePath) or FSafety.IsForbidden(It.SourcePath)
        or ((It.Category <> icIdeConfig) and
        FSafety.ContainsProtected(It.SourcePath)) then
      begin
        FLogger.Warn('Pasta descartada por segurança (sistema ou instalação da IDE): '
          + It.SourcePath);
        AItems.Delete(I);
      end;
    end;
    FLogger.Info(Format('Descoberta concluída: %d itens.', [AItems.Count]));
  except
    on E: Exception do
    begin
      FLogger.Error('Erro na descoberta: ' + E.Message);
      raise;
    end;
  end;
end;

function CreatePathDiscovery(const ALogger: ILogger): IPathDiscovery;
begin
  ALogger.Debug('Criando serviço de descoberta.');
  Result := TPathDiscovery.Create(ALogger);
end;

end.
