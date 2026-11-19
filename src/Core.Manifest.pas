unit Core.Manifest;

interface

uses System.SysUtils, System.Classes, Core.Types;
procedure SaveManifest(AManifest: TManifest; const AFileName: string);
function LoadManifest(const AFileName: string): TManifest;
procedure ScanItemFiles(const ARoot: string; AItem: TManifestItem;
  AExcludeDirs, AExcludeFiles: TStrings);
function ComputeListingHash(AItem: TManifestItem): string;
function NormalizeRegFile(const AFileName: string): string;
function BuildEnvironmentManifest(AVersions: TDelphiVersionList;
  AItems: TBackupItemList; const AItemRootResolver: TFunc<TBackupItem, string>;
  AConfig: TToolConfig; const ALogger: ILogger): TManifest;

implementation

uses System.JSON, System.IOUtils, System.Hash, System.DateUtils, System.Masks,
  System.Generics.Collections, Core.SystemUtils;

function Pretty(const S: string): string;
var
  I, Level: Integer;
  C: Char;
  Quoted, Escaped: Boolean;
  procedure Indent;
  begin
    Result := Result + sLineBreak + StringOfChar(' ', Level * 2);
  end;

begin
  Result := '';
  Level := 0;
  Quoted := False;
  Escaped := False;
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if Quoted then
    begin
      Result := Result + C;
      if Escaped then
        Escaped := False
      else if C = '\' then
        Escaped := True
      else if C = '"' then
        Quoted := False;
    end
    else
      case C of
        '"':
          begin
            Quoted := True;
            Result := Result + C;
          end;
        '{', '[':
          begin
            Result := Result + C;
            Inc(Level);
            Indent;
          end;
        '}', ']':
          begin
            Dec(Level);
            Indent;
            Result := Result + C;
          end;
        ',':
          begin
            Result := Result + C;
            Indent;
          end;
        ':':
          Result := Result + ': ';
      else
        Result := Result + C;
      end;
  end;
end;

function SVal(O: TJSONObject; const N: string): string;
var
  V: TJSONValue;
begin
  V := O.Values[N];
  if not(V is TJSONString) then
    raise EDelphiBackupError.Create('Campo inválido: ' + N);
  Result := V.Value;
end;

function Arr(O: TJSONObject; const N: string): TJSONArray;
var
  V: TJSONValue;
begin
  V := O.Values[N];
  if not(V is TJSONArray) then
    raise EDelphiBackupError.Create('Lista inválida: ' + N);
  Result := TJSONArray(V);
end;

function Obj(V: TJSONValue): TJSONObject;
begin
  if not(V is TJSONObject) then
    raise EDelphiBackupError.Create('Objeto JSON inválido.');
  Result := TJSONObject(V);
end;

procedure SaveManifest(AManifest: TManifest; const AFileName: string);
var
  O, X, Y: TJSONObject;
  A, B: TJSONArray;
  V: TManifestVersion;
  M: TManifestItem;
  F: TManifestFile;
  S: string;
begin
  O := TJSONObject.Create;
  try
    O.AddPair('formatVersion', TJSONNumber.Create(AManifest.FormatVersion));
    O.AddPair('toolVersion', AManifest.ToolVersion);
    O.AddPair('machineName', AManifest.MachineName);
    O.AddPair('createdUtc', AManifest.CreatedUtc);
    O.AddPair('sourceUserProfile', AManifest.SourceUserProfile);
    O.AddPair('sourcePublicDir', AManifest.SourcePublicDir);
    O.AddPair('userPath', AManifest.UserPath);
    A := TJSONArray.Create;
    O.AddPair('versions', A);
    for V in AManifest.Versions do
    begin
      X := TJSONObject.Create;
      A.AddElement(X);
      X.AddPair('bdsVersion', V.BdsVersion);
      X.AddPair('productName', V.ProductName);
      X.AddPair('productVersion', V.ProductVersion);
      X.AddPair('installedUpdates', V.InstalledUpdates);
      X.AddPair('rootDir', V.RootDir);
    end;
    A := TJSONArray.Create;
    O.AddPair('items', A);
    for M in AManifest.Items do
    begin
      X := TJSONObject.Create;
      A.AddElement(X);
      X.AddPair('id', M.Item.Id);
      X.AddPair('kind', ItemKindToText(M.Item.Kind));
      X.AddPair('category', ItemCategoryToText(M.Item.Category));
      X.AddPair('sourcePath', M.Item.SourcePath);
      X.AddPair('description', M.Item.Description);
      X.AddPair('company', M.Item.Company);
      X.AddPair('fileVersion', M.Item.FileVersion);
      X.AddPair('dllOrigin', TJSONNumber.Create(Ord(M.Item.DllOrigin)));
      if M.Item.ReinstalledByIde then
        X.AddPair('reinstalledByIde', TJSONTrue.Create)
      else
        X.AddPair('reinstalledByIde', TJSONFalse.Create);
      X.AddPair('hash', M.Hash);
      B := TJSONArray.Create;
      X.AddPair('versions', B);
      for S in M.Item.Versions do
        B.Add(S);
      B := TJSONArray.Create;
      X.AddPair('files', B);
      for F in M.Files do
      begin
        Y := TJSONObject.Create;
        B.AddElement(Y);
        Y.AddPair('relPath', F.RelPath);
        Y.AddPair('size', TJSONNumber.Create(F.Size));
        Y.AddPair('modifiedUtc', F.ModifiedUtc);
      end;
    end;
    TFile.WriteAllText(AFileName, Pretty(O.ToString), TEncoding.UTF8);
  finally
    O.Free;
  end;
end;

function LoadManifest(const AFileName: string): TManifest;
var
  J: TJSONValue;
  O, X, Y: TJSONObject;
  A, B: TJSONArray;
  I, K, N: Integer;
  V: TManifestVersion;
  M: TManifestItem;
  F: TManifestFile;
begin
  Result := nil;
  J := nil;
  try
    J := TJSONObject.ParseJSONValue(TFile.ReadAllText(AFileName,
      TEncoding.UTF8));
    O := Obj(J);
    Result := TManifest.Create;
    if not(O.Values['formatVersion'] is TJSONNumber) then
      raise EDelphiBackupError.Create('Versão do manifesto inválida.');
    Result.FormatVersion := StrToInt(O.Values['formatVersion'].Value);
    if Result.FormatVersion <> MANIFEST_FORMAT_VERSION then
      raise EDelphiBackupError.Create('Versão do manifesto não suportada.');
    Result.ToolVersion := SVal(O, 'toolVersion');
    Result.MachineName := SVal(O, 'machineName');
    Result.CreatedUtc := SVal(O, 'createdUtc');
    Result.SourceUserProfile := SVal(O, 'sourceUserProfile');
    Result.SourcePublicDir := SVal(O, 'sourcePublicDir');
    Result.UserPath := SVal(O, 'userPath');
    A := Arr(O, 'versions');
    for I := 0 to A.Count - 1 do
    begin
      X := Obj(A.Items[I]);
      V := TManifestVersion.Create;
      Result.Versions.Add(V);
      V.BdsVersion := SVal(X, 'bdsVersion');
      V.ProductName := SVal(X, 'productName');
      V.ProductVersion := SVal(X, 'productVersion');
      V.InstalledUpdates := SVal(X, 'installedUpdates');
      V.RootDir := SVal(X, 'rootDir');
    end;
    A := Arr(O, 'items');
    for I := 0 to A.Count - 1 do
    begin
      X := Obj(A.Items[I]);
      M := TManifestItem.Create;
      Result.Items.Add(M);
      M.Item := TBackupItem.Create;
      M.Item.Id := SVal(X, 'id');
      M.Item.Kind := TextToItemKind(SVal(X, 'kind'));
      M.Item.Category := TextToItemCategory(SVal(X, 'category'));
      M.Item.SourcePath := SVal(X, 'sourcePath');
      M.Item.Description := SVal(X, 'description');
      M.Item.Company := SVal(X, 'company');
      M.Item.FileVersion := SVal(X, 'fileVersion');
      if not(X.Values['dllOrigin'] is TJSONNumber) then
        raise EDelphiBackupError.Create('Origem de DLL inválida.');
      N := StrToInt(X.Values['dllOrigin'].Value);
      if (N < Ord(Low(TDllOrigin))) or (N > Ord(High(TDllOrigin))) then
        raise EDelphiBackupError.Create('Origem de DLL inválida.');
      M.Item.DllOrigin := TDllOrigin(N);
      if not((X.Values['reinstalledByIde'] is TJSONTrue) or
        (X.Values['reinstalledByIde'] is TJSONFalse)) then
        raise EDelphiBackupError.Create('Indicador inválido.');
      M.Item.ReinstalledByIde := X.Values['reinstalledByIde'] is TJSONTrue;
      M.Hash := SVal(X, 'hash');
      B := Arr(X, 'versions');
      for K := 0 to B.Count - 1 do
      begin
        if not(B.Items[K] is TJSONString) then
          raise EDelphiBackupError.Create('Versão inválida.');
        M.Item.Versions.Add(B.Items[K].Value);
      end;
      B := Arr(X, 'files');
      for K := 0 to B.Count - 1 do
      begin
        Y := Obj(B.Items[K]);
        F := TManifestFile.Create;
        M.Files.Add(F);
        F.RelPath := SVal(Y, 'relPath');
        if not(Y.Values['size'] is TJSONNumber) then
          raise EDelphiBackupError.Create('Tamanho inválido.');
        F.Size := StrToInt64(Y.Values['size'].Value);
        F.ModifiedUtc := SVal(Y, 'modifiedUtc');
      end;
    end;
  except
    on E: Exception do
    begin
      Result.Free;
      Result := nil;
      J.Free;
      raise EDelphiBackupError.Create('Manifesto inválido: ' + E.Message);
    end;
  end;
  J.Free;
end;

function Matches(const Name: string; Patterns: TStrings): Boolean;
var
  S: string;
begin
  Result := False;
  if Patterns <> nil then
    for S in Patterns do
      if MatchesMask(Name, S) then
        Exit(True);
end;

procedure ScanItemFiles(const ARoot: string; AItem: TManifestItem;
  AExcludeDirs, AExcludeFiles: TStrings);
var
  Base: string;
  procedure AddFile(const P, Rel: string);
  var
    F: TManifestFile;
    St: TFileStream;
  begin
    F := TManifestFile.Create;
    try
      F.RelPath := Rel;
      St := TFileStream.Create(P, fmOpenRead or fmShareDenyNone);
      try
        F.Size := St.Size;
      finally
        St.Free;
      end;
      F.ModifiedUtc := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
        TFile.GetLastWriteTimeUtc(P));
      AItem.Files.Add(F);
    except
      F.Free;
      raise;
    end;
  end;
  procedure Walk(const Dir, Rel: string);
  var
    SR: TSearchRec;
    P, R: string;
  begin
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) = 0
    then
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then
            Continue;
          P := IncludeTrailingPathDelimiter(Dir) + SR.Name;
          R := Rel + SR.Name;
          if (SR.Attr and faDirectory) <> 0 then
          begin
            if ((SR.Attr and faSymLink) = 0) and
              not Matches(SR.Name, AExcludeDirs) then
              Walk(P, R + '\');
          end
          else if not Matches(SR.Name, AExcludeFiles) then
            AddFile(P, R);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
  end;

var
  I, J: Integer;
begin
  AItem.Files.Clear;
  if AItem.Item.Kind = ikFolder then
  begin
    if DirectoryExists(ARoot) then
      Walk(ARoot, '');
  end
  else if AItem.Item.Kind in [ikFile, ikDll] then
  begin
    Base := ARoot;
    if DirectoryExists(Base) then
      Base := IncludeTrailingPathDelimiter(Base) +
        ExtractFileName(AItem.Item.SourcePath);
    if FileExists(Base) then
      AddFile(Base, ExtractFileName(Base));
  end;
  for I := 1 to AItem.Files.Count - 1 do
  begin
    J := I;
    while (J > 0) and (CompareStr(AItem.Files[J - 1].RelPath,
      AItem.Files[J].RelPath) > 0) do
    begin
      AItem.Files.Exchange(J - 1, J);
      Dec(J);
    end;
  end;
end;

function ComputeListingHash(AItem: TManifestItem): string;
var
  F: TManifestFile;
  S: string;
begin
  S := '';
  for F in AItem.Files do
    S := S + F.RelPath + '|' + IntToStr(F.Size) + '|' + F.ModifiedUtc + #10;
  Result := LowerCase(THashSHA2.GetHashString(S));
end;

function Volatile(const S: string): Boolean;
var
  U: string;
begin
  U := UpperCase(S);
  Result := (Pos('CLOSED FILES', U) > 0) or (Pos('CLOSED PROJECTS', U) > 0) or
    (Pos('HISTORY LISTS', U) > 0) or (Pos('SESSION', U) > 0) or
    (Pos('DESKTOP', U) > 0) or (Pos('AUTORECOVER', U) > 0) or
    (Pos('RECOVER FILES', U) > 0) or (Pos('MRU', U) > 0);
end;

function NormalizeRegFile(const AFileName: string): string;
var
  L: TStringList;
  I: Integer;
  S, Name: string;
  SkipSection, SkipValue, Continued: Boolean;
begin
  Result := '';
  L := TStringList.Create;
  try
    L.LoadFromFile(AFileName);
    SkipSection := False;
    SkipValue := False;
    Continued := False;
    for I := 0 to L.Count - 1 do
    begin
      S := Trim(L[I]);
      if S = '' then
        Continue;
      if (Pos('Windows Registry Editor', S) = 1) or (Pos('REGEDIT4', S) = 1)
      then
        Continue;
      if S[1] = '[' then
      begin
        SkipSection := Volatile(S);
        SkipValue := False;
        Continued := False;
      end
      else if not Continued then
      begin
        Name := Copy(S, 1, Pos('=', S) - 1);
        SkipValue := Volatile(Name);
      end;
      if not SkipSection and not SkipValue then
        Result := Result + S + #10;
      Continued := S[Length(S)] = '\';
    end;
  finally
    L.Free;
  end;
end;

function CloneItem(A: TBackupItem): TBackupItem;
begin
  Result := TBackupItem.Create;
  Result.Id := A.Id;
  Result.Kind := A.Kind;
  Result.Category := A.Category;
  Result.SourcePath := A.SourcePath;
  Result.Description := A.Description;
  Result.Selected := A.Selected;
  Result.Versions.Assign(A.Versions);
  Result.Company := A.Company;
  Result.FileVersion := A.FileVersion;
  Result.DllOrigin := A.DllOrigin;
  Result.ReinstalledByIde := A.ReinstalledByIde;
end;

function BuildEnvironmentManifest(AVersions: TDelphiVersionList;
  AItems: TBackupItemList; const AItemRootResolver: TFunc<TBackupItem, string>;
  AConfig: TToolConfig; const ALogger: ILogger): TManifest;
var
  V: TDelphiVersion;
  MV: TManifestVersion;
  It: TBackupItem;
  M: TManifestItem;
  P: string;
  D, F: TStrings;
begin
  ALogger.Info('Montando manifesto do ambiente.');
  Result := TManifest.Create;
  try
    Result.ToolVersion := ToolVersion;
    Result.MachineName := MachineName;
    Result.CreatedUtc := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
      TTimeZone.Local.ToUniversalTime(Now));
    Result.SourceUserProfile := GetUserProfileDir;
    Result.SourcePublicDir := GetPublicDir;
    Result.UserPath := GetUserPathEnv;
    for V in AVersions do
    begin
      MV := TManifestVersion.Create;
      Result.Versions.Add(MV);
      MV.BdsVersion := V.BdsVersion;
      MV.ProductName := V.ProductName;
      MV.ProductVersion := V.ProductVersion;
      MV.InstalledUpdates := V.InstalledUpdates;
      MV.RootDir := V.RootDir;
    end;
    D := nil;
    F := nil;
    if AConfig <> nil then
    begin
      D := AConfig.ExcludeDirs;
      F := AConfig.ExcludeFiles;
    end;
    for It in AItems do
    begin
      M := TManifestItem.Create;
      Result.Items.Add(M);
      M.Item := CloneItem(It);
      P := AItemRootResolver(It);
      if It.Kind = ikRegistry then
      begin
        if FileExists(P) then
          M.Hash := LowerCase(THashSHA2.GetHashString(NormalizeRegFile(P)));
      end
      else
      begin
        ScanItemFiles(P, M, D, F);
        M.Hash := ComputeListingHash(M);
      end;
    end;
    ALogger.Info(Format('Manifesto criado com %d itens.',
      [Result.Items.Count]));
  except
    on E: Exception do
    begin
      ALogger.Error('Erro ao montar manifesto: ' + E.Message);
      Result.Free;
      raise;
    end;
  end;
end;

end.
