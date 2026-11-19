unit Core.PathDiscovery;

interface

uses System.Classes, Core.Types;

function CreatePathDiscovery(const ALogger: ILogger): IPathDiscovery;
function ResolveBdsMacros(const AText: string; AVersion: TDelphiVersion;
  const APlatform: string): string;
procedure ReduceToRootFolders(APaths: TStrings);
function LoadToolConfig(const AFileName: string; AConfig: TToolConfig;
  const ALogger: ILogger): Boolean;

implementation

uses System.SysUtils, System.IOUtils, System.JSON, System.Win.Registry,
  System.Generics.Collections,
  Winapi.Windows, Core.SystemUtils;

type
  TPathDiscovery = class(TInterfacedObject, IPathDiscovery)
  private
    FLogger: ILogger;
    procedure AddItem(AItems: TBackupItemList; AKind: TItemKind;
      ACategory: TItemCategory; const APath, AVersion: string);
    procedure ReadPaths(AVersion: TDelphiVersion; AItems: TBackupItemList);
  public
    constructor Create(const ALogger: ILogger);
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

function ComponentRoot(const APath: string): string;
var
  P, Parent, Profile, Documents, PublicDir, PF, PF86: string;
begin
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(APath));
  Profile := ExcludeTrailingPathDelimiter(GetUserProfileDir);
  Documents := ExcludeTrailingPathDelimiter(GetDocumentsDir);
  PublicDir := ExcludeTrailingPathDelimiter(GetPublicDir);
  PF := ExcludeTrailingPathDelimiter(GetEnvironmentVariable('ProgramFiles'));
  PF86 := ExcludeTrailingPathDelimiter
    (GetEnvironmentVariable('ProgramFiles(x86)'));
  repeat
    P := Result;
    Parent := ExcludeTrailingPathDelimiter(ExtractFileDir(P));
    if (Parent = '') or SameText(Parent, P) or SameText(Parent, Profile) or
      SameText(Parent, Documents) or SameText(Parent, PublicDir) or
      SameText(Parent, PF) or SameText(Parent, PF86) or (Length(Parent) <= 3)
    then
      Break;
    Result := Parent;
  until False;
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
    Root := ComponentRoot(P);
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
    for L := 0 to 4 do
    begin
      case L of
        0:
          Key := 'Known Packages';
        1:
          Key := 'Known IDE Packages';
        2:
          Key := 'Disabled Packages';
        3:
          Key := 'Experts';
      else
        Key := 'Environment Variables';
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
          if L < 4 then
          begin
            AddPath(Name, L in [1, 3]);
            if L = 3 then
              AddPath(Value, True);
          end
          else if SameText(Name, 'PATH') then
          begin
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
  Child, Parent: TBackupItem;
begin
  FLogger.Info('Iniciando descoberta de caminhos.');
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
