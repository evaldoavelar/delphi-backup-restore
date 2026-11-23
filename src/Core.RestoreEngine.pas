unit Core.RestoreEngine;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Core.Types;

type
  TRestorePlanStep = class
  public
    BdsVersion: string;
    Description: string;
  end;

  TRestoreEngine = class
  private
    FLogger: ILogger;
    FRunner: IProcessRunner;
    FManifest: TManifest;
    FBackupRoot: string;
    FExtractedRoot: string;
    function SelectedVersions(const AOptions: TRestoreOptions): TArray<string>;
    function ItemSelected(AItem: TBackupItem;
      const AOptions: TRestoreOptions): Boolean;
    function ItemSource(AItem: TBackupItem): string;
    function ItemDestination(AItem: TBackupItem): string;
    procedure ValidateDestinations(const AOptions: TRestoreOptions;
      const AVersions: TArray<string>; AInstalled: TDelphiVersionList);
    procedure ClearExtraction;
    procedure ApplyItem(AItem: TBackupItem; const ATempRoot, ASnapshot: string);
    procedure MergeUserPath;
  protected
    procedure CheckHostRequirements; virtual;
  public
    constructor Create(const ALogger: ILogger; const ARunner: IProcessRunner);
    destructor Destroy; override;
    procedure Open(const ASource: string);
    property Manifest: TManifest read FManifest;
    property BackupRoot: string read FBackupRoot;
    procedure Precheck(const AOptions: TRestoreOptions;
      AInstalled: TDelphiVersionList);
    function BuildPlan(const AOptions: TRestoreOptions)
      : TObjectList<TRestorePlanStep>;
    procedure Execute(const AOptions: TRestoreOptions;
      AInstalled: TDelphiVersionList; const AProgress: TProgressProc);
  end;

function SortVersionsOldestFirst(const AVersions: TArray<string>;
  AInstalled: TDelphiVersionList): TArray<string>;
function RemapProfilePath(const AText, AOldProfile,
  ANewProfile: string): string;
function RemapRegFileText(const ARegText, AOldProfile,
  ANewProfile: string): string;

implementation

uses
  Winapi.Windows, System.IOUtils, System.StrUtils, Core.Logger,
  Core.SystemUtils, Core.Manifest, Core.PathDiscovery, Core.DllScanner;

function SortVersionsOldestFirst(const AVersions: TArray<string>;
  AInstalled: TDelphiVersionList): TArray<string>;
var
  I, J, C: Integer;
  V1, V2: TDelphiVersion;
  S: string;
  L: ILogger;
begin
  L := CreateLogger;
  L.Debug('Ordenando versões da mais antiga para a mais nova.');
  Result := Copy(AVersions, 0, Length(AVersions));
  for I := 1 to High(Result) do
  begin
    J := I;
    while J > 0 do
    begin
      V1 := nil;
      V2 := nil;
      if AInstalled <> nil then
      begin
        V1 := AInstalled.FindByBds(Result[J - 1]);
        V2 := AInstalled.FindByBds(Result[J]);
      end;
      if (V1 <> nil) and (V2 <> nil) then
        C := V1.SortKey - V2.SortKey
      else if V1 <> nil then
        C := -1
      else if V2 <> nil then
        C := 1
      else
        C := CompareVersionText(Result[J - 1], Result[J]);
      if C <= 0 then
        Break;
      S := Result[J - 1];
      Result[J - 1] := Result[J];
      Result[J] := S;
      Dec(J);
    end;
  end;
  L.Debug('Ordem de restauração: ' + VersionsToText(Result));
end;

function RemapPath(const AText, AOldProfile, ANewProfile: string;
  AInRegistryKey: Boolean = False): string;
var
  OldPath, NewPath: string;
  I, N: Integer;
  LeftOK, RightOK: Boolean;
begin
  Result := '';
  OldPath := ExcludeTrailingPathDelimiter(AOldProfile);
  NewPath := ExcludeTrailingPathDelimiter(ANewProfile);
  if (OldPath = '') or (NewPath = '') or SameText(OldPath, NewPath) then
    Exit(AText);
  I := 1;
  N := Length(OldPath);
  while I <= Length(AText) do
  begin
    LeftOK := I = 1;
    if not LeftOK then
      LeftOK := CharInSet(AText[I - 1], [#0, #9, #10, #13, ' ', '"', '''', ';',
        '=', ',', '[', '(']) or (AInRegistryKey and (AText[I - 1] = '\'));
    RightOK := I + N > Length(AText);
    if not RightOK then
      RightOK := CharInSet(AText[I + N], [#0, #9, #10, #13, '\', '/', '"', '''',
        ';', ',', ']', ')']);
    if LeftOK and RightOK and SameText(Copy(AText, I, N), OldPath) then
    begin
      Result := Result + NewPath;
      Inc(I, N);
    end
    else
    begin
      Result := Result + AText[I];
      Inc(I);
    end;
  end;
end;

function RemapProfilePath(const AText, AOldProfile,
  ANewProfile: string): string;
var
  L: ILogger;
begin
  L := CreateLogger;
  L.Debug('Remapeando prefixos de perfil em caminho.');
  Result := RemapPath(AText, AOldProfile, ANewProfile);
  L.Debug('Remapeamento de caminho concluído.');
end;

function QuotedEnd(const S: string; AStart: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  I := AStart + 1;
  while I <= Length(S) do
  begin
    if S[I] = '\' then
      Inc(I)
    else if S[I] = '"' then
      Exit(I);
    Inc(I);
  end;
end;

function DecodeRegString(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '\') and (I < Length(S)) and CharInSet(S[I + 1], ['\', '"']) then
      Inc(I);
    Result := Result + S[I];
    Inc(I);
  end;
end;

function EncodeRegString(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

function RemapHex(const APrefix, AData, AOldProfile, ANewProfile, AEol,
  AIndent: string; AWrap: Integer): string;
var
  Tokens: TStringList;
  Bytes: TBytes;
  S, Text, NewText, Line, Token: string;
  I, N, B: Integer;
begin
  Tokens := TStringList.Create;
  try
    S := StringReplace(AData, '\', '', [rfReplaceAll]);
    S := StringReplace(S, #13, '', [rfReplaceAll]);
    S := StringReplace(S, #10, '', [rfReplaceAll]);
    Tokens.StrictDelimiter := True;
    Tokens.Delimiter := ',';
    Tokens.DelimitedText := S;
    N := Tokens.Count;
    if (N > 0) and (Trim(Tokens[N - 1]) = '') then
      Dec(N);
    if (N mod 2) <> 0 then
      raise EDelphiBackupError.Create
        ('Valor UTF-16 do registro tem quantidade ímpar de bytes.');
    SetLength(Bytes, N);
    for I := 0 to N - 1 do
    begin
      S := Trim(Tokens[I]);
      if (Length(S) <> 2) or not TryStrToInt('$' + S, B) or (B < 0) or (B > 255)
      then
        raise EDelphiBackupError.Create
          ('Byte hexadecimal inválido no arquivo de registro.');
      Bytes[I] := Byte(B);
    end;
    { Build code units directly: embedded and trailing NULs must survive unchanged. }
    SetLength(Text, N div 2);
    for I := 1 to Length(Text) do
      Text[I] := WideChar(Word(Bytes[(I - 1) * 2]) or
        (Word(Bytes[(I - 1) * 2 + 1]) shl 8));
    NewText := RemapPath(Text, AOldProfile, ANewProfile);
    if NewText = Text then
      Exit(APrefix + AData);
    Result := '';
    Line := APrefix;
    for I := 0 to Length(NewText) * 2 - 1 do
    begin
      B := Ord(NewText[I div 2 + 1]);
      if Odd(I) then
        B := B shr 8;
      Token := LowerCase(IntToHex(B and 255, 2));
      if I < Length(NewText) * 2 - 1 then
        Token := Token + ',';
      if (AWrap > 0) and (Length(Line) + Length(Token) + 1 > AWrap) and
        (Line <> APrefix) and (Line <> AIndent) then
      begin
        Result := Result + Line + '\' + AEol;
        Line := AIndent;
      end;
      Line := Line + Token;
    end;
    Result := Result + Line;
  finally
    Tokens.Free;
  end;
end;

function RemapRegFileText(const ARegText, AOldProfile,
  ANewProfile: string): string;
var
  Lines: TStringList;
  I, J, P, Q, StartValue, Colon, WrapAt, K, NameStart, NameEnd: Integer;
  S, Body, Data, Prefix, Eol, Indent, NewLine, NewName: string;
  HadFinalEol, HasBom: Boolean;
  L: ILogger;
begin
  L := CreateLogger;
  L.Debug('Remapeando valores e caminhos do arquivo de registro.');
  try
    if (AOldProfile = '') or (ANewProfile = '') or
      SameText(AOldProfile, ANewProfile) then
      Exit(ARegText);
    Eol := #13#10;
    if (Pos(#10, ARegText) > 0) and (Pos(#13#10, ARegText) = 0) then
      Eol := #10;
    HasBom := (Length(ARegText) > 0) and (ARegText[1] = #$FEFF);
    Body := ARegText;
    if HasBom then
      Delete(Body, 1, 1);
    HadFinalEol := (Length(Body) > 0) and CharInSet(Body[Length(Body)],
      [#10, #13]);
    Lines := TStringList.Create;
    try
      Lines.Text := Body;
      Result := '';
      if HasBom then
        Result := #$FEFF;
      I := 0;
      while I < Lines.Count do
      begin
        S := Lines[I];
        Body := TrimLeft(S);
        if (Body <> '') and (Body[1] = '[') then
          S := RemapPath(S, AOldProfile, ANewProfile, True)
        else if (Body <> '') and CharInSet(Body[1], ['"', '@']) then
        begin
          P := Length(S) - Length(Body) + 1;
          if S[P] = '"' then
          begin
            NameStart := P;
            NameEnd := QuotedEnd(S, NameStart);
            if NameEnd > NameStart then
            begin
              NewName := DecodeRegString(Copy(S, NameStart + 1,
                NameEnd - NameStart - 1));
              NewName := RemapPath(NewName, AOldProfile, ANewProfile);
              NewName := EncodeRegString(NewName);
              S := Copy(S, 1, NameStart) + NewName + Copy(S, NameEnd, MaxInt);
              P := NameStart + Length(NewName) + 2;
            end
            else
              P := 0;
          end
          else
            Inc(P);
          while (P > 0) and (P <= Length(S)) and CharInSet(S[P], [' ', #9]) do
            Inc(P);
          if (P > 0) and (P <= Length(S)) and (S[P] = '=') then
          begin
            Inc(P);
            while (P <= Length(S)) and CharInSet(S[P], [' ', #9]) do
              Inc(P);
            StartValue := P;
            if (P <= Length(S)) and (S[P] = '"') then
            begin
              Q := QuotedEnd(S, P);
              if Q > P then
                S := Copy(S, 1, P) + EncodeRegString
                  (RemapPath(DecodeRegString(Copy(S, P + 1, Q - P - 1)),
                  AOldProfile, ANewProfile)) + Copy(S, Q, MaxInt);
            end
            else if SameText(Copy(S, P, 7), 'hex(2):') or
              SameText(Copy(S, P, 7), 'hex(7):') then
            begin
              Colon := StartValue + 6;
              Prefix := Copy(S, 1, Colon);
              Data := Copy(S, Colon + 1, MaxInt);
              WrapAt := 0;
              Indent := '  ';
              J := I;
              NewLine := TrimRight(S);
              while (NewLine <> '') and (NewLine[Length(NewLine)] = '\') do
              begin
                if WrapAt = 0 then
                  WrapAt := Length(NewLine);
                Inc(J);
                if J >= Lines.Count then
                  raise EDelphiBackupError.Create
                    ('Continuação incompleta no arquivo de registro.');
                NewLine := Lines[J];
                if J = I + 1 then
                begin
                  K := 1;
                  while (K <= Length(NewLine)) and
                    CharInSet(NewLine[K], [' ', #9]) do
                    Inc(K);
                  Indent := Copy(NewLine, 1, K - 1);
                end;
                Data := Data + Eol + NewLine;
                NewLine := TrimRight(NewLine);
              end;
              S := RemapHex(Prefix, Data, AOldProfile, ANewProfile, Eol,
                Indent, WrapAt);
              I := J;
            end;
          end;
        end;
        Result := Result + S;
        if (I < Lines.Count - 1) or HadFinalEol then
          Result := Result + Eol;
        Inc(I);
      end;
    finally
      Lines.Free;
    end;
    L.Debug('Remapeamento do registro concluído.');
  except
    on E: Exception do
    begin
      L.Error('Falha ao remapear registro: ' + E.Message);
      raise;
    end;
  end;
end;

constructor TRestoreEngine.Create(const ALogger: ILogger;
  const ARunner: IProcessRunner);
begin
  inherited Create;
  FLogger := ALogger;
  if FLogger = nil then
    FLogger := CreateLogger;
  FLogger.Debug('Criando mecanismo de restauração.');
  FRunner := ARunner;
  if FRunner = nil then
  begin
    FLogger.Error('Executor de processos não informado.');
    raise EArgumentNilException.Create('ARunner');
  end;
end;

destructor TRestoreEngine.Destroy;
begin
  if FLogger <> nil then
    FLogger.Debug('Liberando mecanismo de restauração.');
  FManifest.Free;
  ClearExtraction;
  inherited;
end;

procedure TRestoreEngine.ClearExtraction;
begin
  if FExtractedRoot <> '' then
  begin
    if not DeleteTree(FExtractedRoot) then
      FLogger.Warn('Não foi possível remover a pasta temporária: ' +
        FExtractedRoot);
    FExtractedRoot := '';
  end;
end;

procedure TRestoreEngine.Open(const ASource: string);
var
  Root, Extracted, Candidate: string;
  Dirs: TArray<string>;
  M: TManifest;
begin
  FLogger.Info('Abrindo backup: ' + ASource);
  Extracted := '';
  try
    Root := ExpandFileName(ASource);
    if not DirectoryExists(Root) then
    begin
      if not FileExists(Root) or not SameText(ExtractFileExt(Root), '.zip') then
        raise EDelphiBackupError.Create('Fonte do backup não encontrada: '
          + ASource);
      Extracted := CreateTempDirectory('DelphiBackupRestore_');
      if not FRunner.UnzipTo(Root, Extracted) then
        raise EDelphiBackupError.Create('Falha ao extrair o backup.');
      Root := Extracted;
      if not FileExists(TPath.Combine(Root, BACKUP_MANIFEST_FILE)) then
      begin
        Candidate := '';
        Dirs := TDirectory.GetDirectories(Root);
        for Root in Dirs do
          if not PathHasReparsePoint(Root) and
            FileExists(TPath.Combine(Root, BACKUP_MANIFEST_FILE)) then
          begin
            if Candidate <> '' then
              raise EDelphiBackupError.Create
                ('O ZIP contém mais de um manifest.');
            Candidate := Root;
          end;
        if Candidate = '' then
          raise EDelphiBackupError.Create('Manifest não encontrado no ZIP.');
        Root := Candidate;
      end;
    end;
    if PathHasReparsePoint(TPath.Combine(Root, BACKUP_MANIFEST_FILE)) then
      raise EDelphiBackupError.Create
        ('Caminho inválido para o manifesto: ' + Root);
    M := LoadManifest(TPath.Combine(Root, BACKUP_MANIFEST_FILE));
    ClearExtraction;
    FManifest.Free;
    FManifest := M;
    FBackupRoot := Root;
    FExtractedRoot := Extracted;
    Extracted := '';
    FLogger.Info(Format('Backup aberto: %d versões, %d itens.',
      [M.Versions.Count, M.Items.Count]));
  except
    on E: Exception do
    begin
      if (Extracted <> '') and not DeleteTree(Extracted) then
        FLogger.Warn('Não foi possível remover a pasta temporária: ' +
          Extracted);
      FLogger.Error('Falha ao abrir backup: ' + E.Message);
      raise;
    end;
  end;
end;

function TRestoreEngine.SelectedVersions(const AOptions: TRestoreOptions)
  : TArray<string>;
var
  V: TManifestVersion;
begin
  if FManifest = nil then
    raise EPrecheckError.Create('Abra um backup antes de restaurar.');
  Result := Copy(AOptions.Versions, 0, Length(AOptions.Versions));
  if Length(Result) = 0 then
  begin
    SetLength(Result, FManifest.Versions.Count);
    for V in FManifest.Versions do
      Result[FManifest.Versions.IndexOf(V)] := V.BdsVersion;
  end;
end;

function TRestoreEngine.ItemSelected(AItem: TBackupItem;
  const AOptions: TRestoreOptions): Boolean;
begin
  Result := AItem.Selected and (AItem.Category in AOptions.Categories);
end;

function IsLegacyVersion(AVersion: TManifestVersion): Boolean;
begin
  Result := SameText(AVersion.ProductName, 'Delphi 5') or
    SameText(AVersion.ProductName, 'Delphi 6') or SameText(AVersion.ProductName,
    'Delphi 7') or StartsText('Delphi 5 ', AVersion.ProductName) or
    StartsText('Delphi 6 ', AVersion.ProductName) or
    StartsText('Delphi 7 ', AVersion.ProductName);
end;

function ManifestOrder(AManifest: TManifest; const AVersions: TArray<string>)
  : TArray<string>;
var
  List: TDelphiVersionList;
  M: TManifestVersion;
  V: TDelphiVersion;
  P: Integer;
  Number: string;
begin
  List := TDelphiVersionList.Create(True);
  try
    for M in AManifest.Versions do
    begin
      V := TDelphiVersion.Create;
      List.Add(V);
      V.BdsVersion := M.BdsVersion;
      Number := VersionIdNumber(M.BdsVersion);
      P := Pos('.', Number);
      if P = 0 then
        P := Length(Number) + 1;
      V.Major := StrToIntDef(Copy(Number, 1, P - 1), 0);
      V.Minor := StrToIntDef(Copy(Number, P + 1, MaxInt), 0);
      V.Era := deEmbarcadero;
      if IsLegacyDelphiId(M.BdsVersion) or IsLegacyVersion(M) then
        V.Era := deBorlandDelphi;
    end;
    Result := SortVersionsOldestFirst(AVersions, List);
  finally
    List.Free;
  end;
end;

function UsedBySelectedVersion(AItem: TBackupItem;
  const AVersions: TArray<string>): Boolean;
var
  V: string;
begin
  Result := False;
  for V in AVersions do
    if AItem.UsedByVersion(V) then
      Exit(True);
end;

function RegistryKeyInScope(const AKey, ARoot: string): Boolean;
begin
  Result := SameText(AKey, ARoot) or StartsText(ARoot + '\', AKey);
end;

function IsVersionNumber(const S: string): Boolean;
var
  P, I: Integer;
begin
  Result := False;
  P := Pos('.', S);
  if (P <= 1) or (P >= Length(S)) then
    Exit;
  for I := 1 to Length(S) do
    if (I <> P) and not CharInSet(S[I], ['0' .. '9']) then
      Exit;
  Result := True;
end;

function IsDelphiRegistryKey(const AKey: string): Boolean;
const
  Roots: array [0 .. 3] of string = ('Embarcadero\BDS\', 'CodeGear\BDS\',
    'Borland\BDS\', 'Borland\Delphi\');
var
  SubKey, Root, Version: string;
  P: Integer;
begin
  Result := False;
  if not(StartsText('HKCU\Software\', AKey) or StartsText('HKLM\Software\',
    AKey)) then
    Exit;
  SubKey := Copy(AKey, Length('HKCU\Software\') + 1, MaxInt);
  if StartsText('WOW6432Node\', SubKey) then
    Delete(SubKey, 1, Length('WOW6432Node\'));
  for Root in Roots do
    if StartsText(Root, SubKey) then
    begin
      Version := Copy(SubKey, Length(Root) + 1, MaxInt);
      P := Pos('\', Version);
      if P > 0 then
        SetLength(Version, P - 1);
      Exit(IsVersionNumber(Version));
    end;
end;

function IsInstallerKey(const AKey: string): Boolean;
begin
  Result := StartsText('HKLM\', AKey) and IsDelphiRegistryKey(AKey);
end;

function IsAllowedRegistryKey(const AKey: string;
  ACategory: TItemCategory): Boolean;
const
  ExpertKeys: array [0 .. 2] of string = ('GExperts', 'CnPack',
    'Scooter Software');
var
  C: Char;
  Key, Expert: string;
  Levels: Integer;
begin
  Result := False;
  if not(StartsText('HKCU\', AKey) or StartsText('HKLM\', AKey)) or
    (Trim(AKey) <> AKey) or EndsText('\', AKey) or (Pos('\\', AKey) > 0) then
    Exit;
  Levels := 0;
  for C in AKey do
  begin
    if CharInSet(C, [#0 .. #31, '"']) then
      Exit;
    if C = '\' then
      Inc(Levels);
  end;
  if IsDelphiRegistryKey(AKey) then
    Exit(True);
  for Expert in ExpertKeys do
    if RegistryKeyInScope(AKey, 'HKCU\Software\' + Expert) or
      RegistryKeyInScope(AKey, 'HKLM\Software\' + Expert) then
      Exit(True);
  Key := UpperCase(AKey);
  if StartsText('HKLM\Software\', Key) then
  begin
    { An extra key may not delete a parent of the installer-managed versions. }
    if StartsText('WOW6432Node\', Copy(Key, Length('HKLM\Software\') + 1,
      MaxInt)) then
      Delete(Key, Length('HKLM\Software\') + 1, Length('WOW6432Node\'));
    if RegistryKeyInScope('HKLM\Software\Embarcadero\BDS', Key) or
      RegistryKeyInScope('HKLM\Software\CodeGear\BDS', Key) or
      RegistryKeyInScope('HKLM\Software\Borland\BDS', Key) or
      RegistryKeyInScope('HKLM\Software\Borland\Delphi', Key) or
      SameText(Key, 'HKLM\Software\WOW6432Node') then
      Exit;
  end;
  Result := (ACategory = icExtra) and (Levels >= 3) and
    not SameText('HKCU\Software', AKey) and not SameText('HKLM\Software', AKey)
    and not RegistryKeyInScope(AKey, 'HKLM\SYSTEM') and
    (Pos('\MICROSOFT', Key) = 0) and (Pos('\POLICIES', Key) = 0) and
    (Pos('\CLASSES', Key) = 0);
end;

function IsIdeConfigFolder(const ADest: string; AItem: TBackupItem;
  AInstalled: TDelphiVersionList): Boolean;
var
  V: TDelphiVersion;
begin
  Result := False;
  for V in AInstalled do
    if (AItem.Versions.IndexOf(V.BdsVersion) >= 0) and
      (SameText(ADest, NormalizePath(V.CommonDir)) or SameText(ADest,
      NormalizePath(V.UserDir)) or SameText(ADest, NormalizePath(V.AppDataDir)))
    then
      Exit(True);
end;

function PathsOverlap(const APath, ARoot: string): Boolean;
begin
  Result := (ARoot <> '') and (IsPathInside(APath, ARoot) or
    IsPathInside(ARoot, APath));
end;

function IsSystemFileTarget(const ADest: string; AKind: TItemKind): Boolean;
var
  Parent, WowDir: string;
begin
  Result := False;
  if not(AKind in [ikFile, ikDll]) then
    Exit;
  Parent := ExtractFileDir(ADest);
  WowDir := GetSysWow64Dir;
  Result := SameText(Parent, GetSystem32Dir) or
    ((WowDir <> '') and SameText(Parent, WowDir));
end;

function TRestoreEngine.ItemDestination(AItem: TBackupItem): string;
begin
  Result := RemapPath(AItem.SourcePath, FManifest.SourceUserProfile,
    GetUserProfileDir, AItem.Kind = ikRegistry);
  if (AItem.Kind <> ikRegistry) and IsAbsoluteFileSystemPath(Result) then
    Result := NormalizePath(StringReplace(Result, '/', '\', [rfReplaceAll]));
end;

procedure TRestoreEngine.ValidateDestinations(const AOptions: TRestoreOptions;
  const AVersions: TArray<string>; AInstalled: TDelphiVersionList);
var
  Safety: TPathSafety;
  Violations: TStringList;
  M: TManifestItem;
  Item: TBackupItem;
  Dest, FilePath: string;

  procedure Reject(const AReason: string);
  begin
    Violations.Add('[' + Item.Id + '] ' + Dest + ': ' + AReason);
  end;

begin
  Safety := TPathSafety.Create(AInstalled);
  Violations := TStringList.Create;
  try
    for M in FManifest.Items do
    begin
      Item := M.Item;
      if not ItemSelected(Item, AOptions) or not UsedBySelectedVersion(Item,
        AVersions) then
        Continue;
      Dest := ItemDestination(Item);
      if Item.Kind = ikRegistry then
      begin
        if not IsAllowedRegistryKey(Dest, Item.Category) then
          Reject('chave de registro fora dos escopos permitidos');
        Continue;
      end;
      if not IsAbsoluteFileSystemPath(Dest) then
      begin
        Reject('caminho de destino inválido ou não absoluto');
        Continue;
      end;
      if Safety.IsContainer(Dest) then
        Reject('destino é uma pasta de sistema');
      { File items can address individual System32/SysWOW64 files. The
        Windows directory and its folders may never be copied as a tree. }
      if Safety.IsForbidden(Dest) and not IsSystemFileTarget(Dest, Item.Kind)
      then
        Reject('destino está em uma pasta proibida');
      if Item.Kind = ikFolder then
      begin
        if Item.Category = icIdeConfig then
        begin
          if not IsIdeConfigFolder(Dest, Item, AInstalled) then
            Reject('pasta de configuração não pertence a uma versão do item');
        end
        else if Safety.ContainsProtected(Dest) then
          Reject('destino contém uma pasta protegida da IDE');
        if FileExists(Dest) then
          Reject('destino de pasta é um arquivo');
      end;
      FilePath := Dest;
      if Item.Kind in [ikFile, ikDll] then
      begin
        FilePath := RealFileSystemPath(Dest);
        if DirectoryExists(FilePath) or EndsText('\', Item.SourcePath) or
          EndsText('/', Item.SourcePath) then
          Reject('destino de arquivo é uma pasta');
      end;
      if PathsOverlap(Dest, FBackupRoot) or PathsOverlap(Dest, FExtractedRoot)
      then
        Reject('destino se sobrepõe à pasta do backup ou da extração');
      if PathHasReparsePoint(FilePath) then
        Reject('destino contém ponto de nova análise ou está inacessível');
    end;
    if Violations.Count > 0 then
      raise EPrecheckError.Create('Destinos de restauração inválidos:' +
        sLineBreak + TrimRight(Violations.Text));
  finally
    Violations.Free;
    Safety.Free;
  end;
end;

procedure TRestoreEngine.CheckHostRequirements;
var
  Processes: string;
begin
  FLogger.Debug('Verificando privilégios e processos da IDE.');
  if not IsRunningAsAdmin then
    raise EPrecheckError.Create('Execute como administrador para restaurar.');
  if IsDelphiIdeRunning(Processes) then
    raise EPrecheckError.Create('Feche as IDEs Delphi antes de restaurar: ' +
      Processes);
end;

procedure TRestoreEngine.Precheck(const AOptions: TRestoreOptions;
  AInstalled: TDelphiVersionList);
var
  Versions, Order: TArray<string>;
  S, InstallOrder: string;
  V: TDelphiVersion;
  M: TManifestVersion;
begin
  FLogger.Info('Verificando requisitos de restauração (somente leitura).');
  try
    Versions := SelectedVersions(AOptions);
    if AInstalled = nil then
      raise EPrecheckError.Create
        ('A lista de versões instaladas não foi informada.');
    if Length(Versions) = 0 then
      raise EPrecheckError.Create
        ('O backup não contém versões para restaurar.');
    ValidateDestinations(AOptions, Versions, AInstalled);
    CheckHostRequirements;
    Order := ManifestOrder(FManifest, Versions);
    InstallOrder := '';
    for S in Order do
    begin
      M := FManifest.FindVersion(S);
      if M = nil then
        raise EPrecheckError.Create('Versão ausente no backup: ' + S);
      if InstallOrder <> '' then
        InstallOrder := InstallOrder + ' -> ';
      InstallOrder := InstallOrder + M.ProductName + ' (BDS ' + S + ')';
    end;
    for S in Versions do
    begin
      M := FManifest.FindVersion(S);
      V := AInstalled.FindByBds(S);
      if (V = nil) or not DirectoryExists(V.RootDir) or
        ((V.Era = deBorlandDelphi) <> IsLegacyVersion(M)) or
        not(FileExists(TPath.Combine(V.RootDir, 'bin\bds.exe')) or
        FileExists(TPath.Combine(V.RootDir, 'bin\delphi32.exe'))) then
        raise EPrecheckError.Create('Versão não instalada: ' + S +
          '. Instale da mais antiga para a mais nova nesta ordem: ' +
          InstallOrder);
      if not SameText(V.InstalledUpdates, M.InstalledUpdates) then
        FLogger.Warn('Atualizações instaladas diferentes do backup para BDS '
          + S + '.');
    end;
    FLogger.Info('Requisitos de restauração atendidos.');
  except
    on E: Exception do
    begin
      FLogger.Error('Restauração impedida: ' + E.Message);
      raise;
    end;
  end;
end;

function TRestoreEngine.BuildPlan(const AOptions: TRestoreOptions)
  : TObjectList<TRestorePlanStep>;
var
  Versions: TArray<string>;
  S, VersionName: string;
  M: TManifestItem;
  Done: TStringList;
  Step: TRestorePlanStep;
  Pass, KindPass: Integer;
  Applicable: Boolean;
begin
  FLogger.Debug('Montando plano de restauração.');
  Result := TObjectList<TRestorePlanStep>.Create(True);
  Done := TStringList.Create;
  try
    try
      Versions := ManifestOrder(FManifest, SelectedVersions(AOptions));
      Step := TRestorePlanStep.Create;
      Step.Description :=
        'Exportar o registro atual das versões selecionadas para segurança.';
      Result.Add(Step);
      { The final two passes are globals and DLLs, in that order. }
      for Pass := 0 to Length(Versions) + 1 do
      begin
        S := '';
        if Pass < Length(Versions) then
          S := Versions[Pass];
        for KindPass := Ord(ikFolder) to Ord(ikDll) do
          for M in FManifest.Items do
          begin
            if Ord(M.Item.Kind) <> KindPass then
              Continue;
            Applicable := False;
            if Pass < Length(Versions) then
              Applicable := (M.Item.Kind <> ikDll) and
                (M.Item.Versions.Count > 0) and M.Item.UsedByVersion(S)
            else if Pass = Length(Versions) then
              Applicable := (M.Item.Kind <> ikDll) and
                (M.Item.Versions.Count = 0)
            else if M.Item.Kind = ikDll then
              for VersionName in Versions do
                if M.Item.UsedByVersion(VersionName) then
                  Applicable := True;
            if ItemSelected(M.Item, AOptions) and (Done.IndexOf(M.Item.Id) < 0)
              and Applicable then
            begin
              Step := TRestorePlanStep.Create;
              Step.BdsVersion := S;
              if (M.Item.Kind = ikRegistry) and
                IsInstallerKey(ItemDestination(M.Item)) then
                Step.Description := 'Ignorar chave do instalador: ' +
                  ItemDestination(M.Item)
              else
                Step.Description := 'Restaurar ' + M.Item.Description + ': ' +
                  ItemDestination(M.Item);
              Result.Add(Step);
              Done.Add(M.Item.Id);
            end;
          end;
      end;
      Step := TRestorePlanStep.Create;
      Step.Description := 'Mesclar entradas ausentes do PATH do usuário.';
      Result.Add(Step);
      FLogger.Debug(Format('Plano criado com %d passos.', [Result.Count]));
    except
      on E: Exception do
      begin
        Result.Free;
        FLogger.Error('Falha ao montar plano: ' + E.Message);
        raise;
      end;
    end;
  finally
    Done.Free;
  end;
end;

function TRestoreEngine.ItemSource(AItem: TBackupItem): string;
var
  Base: string;
begin
  if (AItem.Id = '') or (AItem.Id = '.') or (AItem.Id = '..') or
    (Pos('\', AItem.Id) > 0) or (Pos('/', AItem.Id) > 0) or
    (Pos(':', AItem.Id) > 0) then
    raise EDelphiBackupError.Create
      ('Identificador de item inválido no backup.');
  if AItem.Kind = ikRegistry then
    Result := TPath.Combine(TPath.Combine(FBackupRoot, BACKUP_REGISTRY_DIR),
      AItem.Id + '.reg')
  else
  begin
    Base := BACKUP_FILES_DIR;
    if AItem.Kind = ikDll then
      Base := BACKUP_DLLS_DIR;
    Result := TPath.Combine(TPath.Combine(FBackupRoot, Base), AItem.Id);
    if AItem.Kind in [ikFile, ikDll] then
      Result := TPath.Combine(Result,
        ExtractFileName(StringReplace(AItem.SourcePath, '/', '\',
        [rfReplaceAll])));
  end;
  if not IsAbsoluteFileSystemPath(Result) or
    not IsPathInside(Result, FBackupRoot) or PathHasReparsePoint(Result) then
    raise EDelphiBackupError.Create('Caminho de origem inválido no backup: '
      + Result);
end;

procedure CheckRegFileScope(const AText, AKey: string);
var
  Lines: TStringList;
  Line, Header, Key: string;
  HasSection: Boolean;
begin
  if Pos(#0, AText) > 0 then
    raise EDelphiBackupError.Create
      ('Arquivo de registro contém um caractere nulo.');
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    HasSection := False;
    for Line in Lines do
    begin
      Header := Trim(Line);
      if (Header <> '') and (Header[1] = #$FEFF) then
        Header := TrimLeft(Copy(Header, 2, MaxInt));
      if (Header = '') or (Header[1] <> '[') then
        Continue;
      if (Length(Header) < 3) or (Header[Length(Header)] <> ']') then
        raise EDelphiBackupError.Create('Cabeçalho de registro inválido: '
          + Header);
      Key := Copy(Header, 2, Length(Header) - 2);
      if StartsText('-', Key) then
        Delete(Key, 1, 1);
      if StartsText('HKEY_CURRENT_USER\', Key) then
        Key := 'HKCU\' + Copy(Key, Length('HKEY_CURRENT_USER\') + 1, MaxInt)
      else if StartsText('HKEY_LOCAL_MACHINE\', Key) then
        Key := 'HKLM\' + Copy(Key, Length('HKEY_LOCAL_MACHINE\') + 1, MaxInt);
      if not RegistryKeyInScope(Key, AKey) then
        raise EDelphiBackupError.Create('Seção de registro fora da chave ' +
          AKey + ': ' + Header);
      HasSection := True;
    end;
    if not HasSection then
      raise EDelphiBackupError.Create
        ('Arquivo de registro sem seções para ' + AKey);
  finally
    Lines.Free;
  end;
end;

procedure TRestoreEngine.ApplyItem(AItem: TBackupItem;
  const ATempRoot, ASnapshot: string);
var
  Source, Dest, RegText, RegFile, DestVersion, BackupVersion: string;
  BackupMachine, DestMachine: Word;
  Hklm32: Boolean;
begin
  Dest := ItemDestination(AItem);
  Source := ItemSource(AItem);
  if AItem.Kind in [ikFile, ikDll] then
    Dest := RealFileSystemPath(Dest);
  FLogger.Info('Restaurando ' + Dest);
  case AItem.Kind of
    ikFolder:
      begin
        if not DirectoryExists(Source) then
          raise EDelphiBackupError.Create('Pasta ausente no backup: ' + Source);
        if not FRunner.CopyTree(Source, Dest, FManifest.HasExclusions,
          FManifest.ExcludeDirs, FManifest.ExcludeFiles) then
          raise EDelphiBackupError.Create('Falha ao restaurar pasta: ' + Dest);
      end;
    ikFile:
      begin
        if not FileExists(Source) then
          raise EDelphiBackupError.Create('Arquivo ausente no backup: '
            + Source);
        if not FRunner.CopyFile(Source, ExtractFileDir(Dest)) then
          raise EDelphiBackupError.Create
            ('Falha ao restaurar arquivo: ' + Dest);
      end;
    ikRegistry:
      begin
        RegText := TFile.ReadAllText(Source, TEncoding.Unicode);
        RegText := RemapRegFileText(RegText, FManifest.SourceUserProfile,
          GetUserProfileDir);
        CheckRegFileScope(RegText, Dest);
        RegFile := TPath.Combine(ATempRoot, 'import_' + AItem.Id + '.reg');
        TFile.WriteAllText(RegFile, RegText, TEncoding.Unicode);
        Hklm32 := StartsText('HKLM\', Dest);
        if not FRunner.RegDelete(Dest) then
          raise EDelphiBackupError.Create('Falha ao limpar registro: ' + Dest);
        try
          if not FRunner.RegImport(RegFile, Hklm32) then
            raise EDelphiBackupError.Create('reg import retornou falha.');
        except
          on E: Exception do
          begin
            FLogger.Error('Falha ao importar registro de ' + Dest + ': ' +
              E.Message);
            { Import merges values, so remove the partial key before restoring
              the original snapshot. Attempt the snapshot even if cleanup fails. }
            try
              if not FRunner.RegDelete(Dest) then
                raise EDelphiBackupError.Create('reg delete retornou falha.');
            except
              on CleanupError: Exception do
                FLogger.Error('Falha ao limpar importação parcial de ' + Dest +
                  ': ' + CleanupError.Message);
            end;
            if ASnapshot <> '' then
              try
                if not FRunner.RegImport(ASnapshot, Hklm32) then
                  raise EDelphiBackupError.Create('reg import retornou falha.');
                FLogger.Info('Snapshot de segurança reimportado: ' + Dest);
              except
                on RollbackError: Exception do
                  FLogger.Error('Falha ao reimportar snapshot de ' + Dest + ': '
                    + RollbackError.Message);
              end;
            raise EDelphiBackupError.Create('Falha ao importar registro: ' +
              Dest + '. ' + E.Message + ' Exportações de segurança: ' +
              ATempRoot);
          end;
        end;
      end;
    ikDll:
      begin
        if not FileExists(Source) then
          raise EDelphiBackupError.Create('DLL ausente no backup: ' + Source);
        if FileExists(Dest) then
        begin
          DestVersion := GetFileVersionText(Dest);
          BackupVersion := GetFileVersionText(Source);
          if (BackupVersion = '') or (DestVersion = '') then
          begin
            FLogger.Warn('DLL mantida por versão de arquivo ilegível: ' + Dest);
            Exit;
          end;
          BackupMachine := ReadPeMachine(Source);
          DestMachine := ReadPeMachine(Dest);
          if (BackupMachine = 0) or (BackupMachine <> DestMachine) then
          begin
            FLogger.Warn
              ('DLL mantida por arquitetura PE incompatível: ' + Dest);
            Exit;
          end;
          if CompareVersionText(DestVersion, BackupVersion) >= 0 then
          begin
            FLogger.Info
              ('DLL mantida: versão instalada igual ou mais nova em ' + Dest);
            Exit;
          end;
        end;
        if not ForceDirectories(ExtractFileDir(Dest)) then
          raise EDelphiBackupError.Create
            ('Não foi possível criar a pasta da DLL: ' + Dest);
        if not Winapi.Windows.CopyFile(PChar(Source), PChar(Dest), False) then
          RaiseLastOSError;
      end;
  end;
  FLogger.Debug('Item restaurado: ' + AItem.Id);
end;

procedure TRestoreEngine.MergeUserPath;
var
  Entries, Saved: TStringList;
  Current, S, Key: string;
  I, J: Integer;
  Found, Changed: Boolean;
begin
  FLogger.Info('Mesclando PATH do usuário.');
  Entries := TStringList.Create;
  Saved := TStringList.Create;
  try
    Current := GetUserPathEnv;
    Entries.StrictDelimiter := True;
    Entries.Delimiter := ';';
    Entries.QuoteChar := #0;
    Entries.DelimitedText := Current;
    Saved.StrictDelimiter := True;
    Saved.Delimiter := ';';
    Saved.QuoteChar := #0;
    Saved.DelimitedText := FManifest.UserPath;
    Changed := False;
    for I := 0 to Saved.Count - 1 do
    begin
      S := Trim(RemapPath(Saved[I], FManifest.SourceUserProfile,
        GetUserProfileDir));
      if S = '' then
        Continue;
      Key := ExcludeTrailingPathDelimiter
        (ExpandEnvVars(StringReplace(S, '"', '', [rfReplaceAll])));
      Found := False;
      for J := 0 to Entries.Count - 1 do
        if SameText(Key, ExcludeTrailingPathDelimiter
          (ExpandEnvVars(StringReplace(Trim(Entries[J]), '"', '',
          [rfReplaceAll])))) then
        begin
          Found := True;
          Break;
        end;
      if not Found then
      begin
        if (Current <> '') and (Current[Length(Current)] <> ';') then
          Current := Current + ';';
        Current := Current + S;
        Entries.Add(S);
        Changed := True;
      end;
    end;
    if Changed then
      SetUserPathEnv(Current);
    FLogger.Info('Mesclagem do PATH concluída.');
  finally
    Saved.Free;
    Entries.Free;
  end;
end;

procedure TRestoreEngine.Execute(const AOptions: TRestoreOptions;
  AInstalled: TDelphiVersionList; const AProgress: TProgressProc);
var
  Versions: TArray<string>;
  S, TempRoot, Key, Source, Snapshot: string;
  V: TDelphiVersion;
  M: TManifestItem;
  Done, Keys, Snapshots: TStringList;
  Pass, KindPass, Current, Total, KeyIndex: Integer;
  Applicable: Boolean;
begin
  FLogger.Info('Iniciando restauração.');
  try
    Precheck(AOptions, AInstalled);
    Versions := SortVersionsOldestFirst(SelectedVersions(AOptions), AInstalled);
    Done := TStringList.Create;
    Keys := TStringList.Create;
    Snapshots := TStringList.Create;
    try
      { Validate every selected source before creating safety exports or deleting registry keys. }
      Total := 0;
      for M in FManifest.Items do
        if ItemSelected(M.Item, AOptions) then
        begin
          if not UsedBySelectedVersion(M.Item, Versions) then
            Continue;
          if (M.Item.Kind = ikRegistry) and
            IsInstallerKey(ItemDestination(M.Item)) then
            Continue;
          if Done.IndexOf(M.Item.Id) >= 0 then
            raise EDelphiBackupError.Create('Id de item duplicado: ' +
              M.Item.Id);
          Done.Add(M.Item.Id);
          Source := ItemSource(M.Item);
          if ((M.Item.Kind = ikFolder) and not DirectoryExists(Source)) or
            ((M.Item.Kind <> ikFolder) and not FileExists(Source)) then
            raise EDelphiBackupError.Create('Item ausente no backup: '
              + Source);
          Inc(Total);
        end;
      Done.Clear;
      if not FManifest.HasExclusions then
        FLogger.Warn
          ('Manifesto sem listas de exclusão completas; as pastas serão copiadas sem espelhamento.');
      TempRoot := CreateTempDirectory('DelphiBackupRestore_pre_');
      FLogger.Info('Exportações de segurança do registro: ' + TempRoot);
      for S in Versions do
      begin
        V := AInstalled.FindByBds(S);
        if V.RegistryKey <> '' then
        begin
          Keys.Add('HKCU\' + V.RegistryKey);
          Keys.Add('HKLM\' + V.RegistryKey);
        end;
      end;
      for M in FManifest.Items do
        if ItemSelected(M.Item, AOptions) and (M.Item.Kind = ikRegistry) and
          UsedBySelectedVersion(M.Item, Versions) then
        begin
          Key := ItemDestination(M.Item);
          if not IsInstallerKey(Key) and (Keys.IndexOf(Key) < 0) then
            Keys.Add(Key);
        end;
      for Key in Keys do
      begin
        Snapshot := '';
        if FRunner.RegKeyExists(Key) then
        begin
          Snapshot := TPath.Combine(TempRoot, Format('before_%.3d.reg',
            [Snapshots.Count + 1]));
          if not FRunner.RegExport(Key, Snapshot) or not FileExists(Snapshot)
          then
            raise EDelphiBackupError.Create
              ('Falha ao exportar registro atual: ' + Key);
        end;
        Snapshots.Add(Snapshot);
      end;
      Current := 0;
      for Pass := 0 to Length(Versions) + 1 do
      begin
        S := '';
        if Pass < Length(Versions) then
          S := Versions[Pass];
        for KindPass := Ord(ikFolder) to Ord(ikDll) do
          for M in FManifest.Items do
          begin
            if Ord(M.Item.Kind) <> KindPass then
              Continue;
            if not ItemSelected(M.Item, AOptions) or
              (Done.IndexOf(M.Item.Id) >= 0) then
              Continue;
            Applicable := False;
            if Pass < Length(Versions) then
              Applicable := (M.Item.Kind <> ikDll) and
                (M.Item.Versions.Count > 0) and M.Item.UsedByVersion(S)
            else if Pass = Length(Versions) then
              Applicable := (M.Item.Kind <> ikDll) and
                (M.Item.Versions.Count = 0)
            else if M.Item.Kind = ikDll then
              for S in Versions do
                if M.Item.UsedByVersion(S) then
                  Applicable := True;
            if not Applicable then
              Continue;
            Snapshot := '';
            if M.Item.Kind = ikRegistry then
            begin
              Key := ItemDestination(M.Item);
              if IsInstallerKey(Key) then
              begin
                FLogger.Info('Chave do instalador ignorada: ' + Key);
                Continue;
              end;
              KeyIndex := Keys.IndexOf(Key);
              Snapshot := Snapshots[KeyIndex];
            end;
            if Assigned(AProgress) then
              AProgress(Current, Total, 'Restaurando ' + M.Item.Description);
            ApplyItem(M.Item, TempRoot, Snapshot);
            Done.Add(M.Item.Id);
            Inc(Current);
            if Assigned(AProgress) then
              AProgress(Current, Total, 'Restaurado: ' + M.Item.Description);
          end;
      end;
      MergeUserPath;
      FLogger.Info
        ('Restauração concluída. Exportações de segurança mantidas em ' +
        TempRoot);
    finally
      Snapshots.Free;
      Keys.Free;
      Done.Free;
    end;
  except
    on E: Exception do
    begin
      FLogger.Error('Falha na restauração: ' + E.Message);
      raise;
    end;
  end;
end;

end.
