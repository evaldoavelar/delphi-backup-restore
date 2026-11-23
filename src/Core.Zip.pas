unit Core.Zip;

interface

uses System.Classes, System.Generics.Collections, Core.Types;

function BuildZipArguments(const AParent, AName, AZip: string;
  AUsing7Zip, AStore: Boolean): string;
function FormatZipProgress(ADone, ATotal: Int64;
  AElapsedSeconds: Double): string;
function TryTakeTarFileSize(const ALine, ATopFolder: string;
  ASizes: TDictionary<string, Int64>; out ASize: Int64): Boolean;
function TryParse7ZipPercent(const ALine: string;
  out APercent: Integer): Boolean;
function CreateBackupZip(const AFolder, AZip: string; AStore: Boolean;
  const ARunner: IProcessRunner; const ALogger: ILogger;
  const AProgress: TProgressProc): Boolean;
function ListBackupZip(const AZip: string; const ARunner: IProcessRunner;
  const ALogger: ILogger; AEntries: TStrings): Boolean;
function ExtractBackupZip(const AZip, ADest: string;
  const ARunner: IProcessRunner; const ALogger: ILogger;
  const AProgress: TProgressProc = nil): Boolean;

implementation

uses System.SysUtils, System.StrUtils, System.Math, System.IOUtils,
  System.Win.Registry, Winapi.Windows, Core.ProcessRunner, Core.SystemUtils;

const
  MEBIBYTE = 1024.0 * 1024;
  GIBIBYTE = 1024.0 * MEBIBYTE;
  PROGRESS_INTERVAL_MS = 2000;

type
  TZipProgress = record
    Callback: TProgressProc;
    Action: string;
    Done, Total: Int64;
    Started, LastReport: UInt64;
    LastPercent, Latest7ZipPercent: Integer;
    procedure Report(APercent: Integer; AForce: Boolean = False);
    function Report7ZipLine(const ALine: string): Boolean;
  end;

function ZipPercent(ADone, ATotal: Int64): Integer;
begin
  if ATotal <= 0 then
    Exit(0);
  if ADone >= ATotal then
    Exit(100);
  Result := Min(99, Round((ADone / ATotal) * 100));
end;

function FormatProgress(const AAction: string; ADone, ATotal: Int64;
  AElapsedSeconds: Double; APercent: Integer): string;
var
  Settings: TFormatSettings;
  Speed, Scale, RemainingSeconds: Double;
  Remaining: Int64;
  Units, ETA: string;
begin
  Settings := TFormatSettings.Create;
  Settings.DecimalSeparator := ',';
  Scale := MEBIBYTE;
  Units := 'MB';
  if ATotal >= GIBIBYTE then
  begin
    Scale := GIBIBYTE;
    Units := 'GB';
  end;
  Result := Format('%s: %d%% (%s de %s %s)',
    [AAction, APercent, FormatFloat('0.0', ADone / Scale, Settings),
    FormatFloat('0.0', ATotal / Scale, Settings), Units]);
  if (AElapsedSeconds <= 0) or (ADone <= 0) then
    Exit;
  Speed := ADone / AElapsedSeconds;
  Result := Result + ' - ' + FormatFloat('0.0', Speed / MEBIBYTE, Settings)
    + ' MB/s';
  if APercent = 100 then
    Exit;
  RemainingSeconds := (ATotal - ADone) / Speed;
  if RemainingSeconds >= High(Int64) then
    Exit;
  Remaining := Trunc(RemainingSeconds);
  if RemainingSeconds > Remaining then
    Inc(Remaining);
  if Remaining < 60 then
    ETA := IntToStr(Remaining) + ' s'
  else if Remaining < 3600 then
    ETA := IntToStr((Remaining + 59) div 60) + ' min'
  else
    ETA := Format('%d h %d min', [Remaining div 3600,
      (Remaining mod 3600) div 60]);
  Result := Result + ' - faltam ~' + ETA;
end;

procedure TZipProgress.Report(APercent: Integer; AForce: Boolean);
var
  Tick: UInt64;
begin
  if not Assigned(Callback) or (APercent <= LastPercent) then
    Exit;
  Tick := GetTickCount64;
  if not AForce and (LastPercent >= 0) and
    (Tick - LastReport < PROGRESS_INTERVAL_MS) then
    Exit;
  Callback(APercent, 100, FormatProgress(Action, Done, Total,
    (Tick - Started) / 1000.0, APercent));
  LastReport := Tick;
  LastPercent := APercent;
end;

function FormatZipProgress(ADone, ATotal: Int64;
  AElapsedSeconds: Double): string;
begin
  ATotal := Max(0, ATotal);
  ADone := Min(ATotal, Max(0, ADone));
  Result := FormatProgress('Compactando', ADone, ATotal, AElapsedSeconds,
    ZipPercent(ADone, ATotal));
end;

function TryTakeEntrySize(const ALine, APrefix: string;
  ASizes: TDictionary<string, Int64>; out ASize: Int64): Boolean;
var
  Entry: string;
begin
  ASize := 0;
  Entry := StringReplace(ALine, '/', '\', [rfReplaceAll]);
  Result := StartsStr(APrefix, Entry);
  if not Result then
    Exit;
  Entry := Copy(Entry, Length(APrefix) + 1, MaxInt);
  Result := ASizes.TryGetValue(Entry, ASize);
  if Result then
    ASizes.Remove(Entry);
end;

function TryTakeTarFileSize(const ALine, ATopFolder: string;
  ASizes: TDictionary<string, Int64>; out ASize: Int64): Boolean;
begin
  Result := TryTakeEntrySize(ALine, 'a ' + ATopFolder + '\', ASizes, ASize);
end;

function TryParse7ZipPercent(const ALine: string;
  out APercent: Integer): Boolean;
var
  Line: string;
  I: Integer;
begin
  APercent := 0;
  Line := TrimLeft(ALine);
  I := 1;
  while (I <= Length(Line)) and CharInSet(Line[I], ['0' .. '9']) do
    Inc(I);
  Result := (I > 1) and (I <= 4) and (I <= Length(Line)) and (Line[I] = '%') and
    ((I = Length(Line)) or CharInSet(Line[I + 1], [' ', #9])) and
    TryStrToInt(Copy(Line, 1, I - 1), APercent) and (APercent <= 100);
end;

function TZipProgress.Report7ZipLine(const ALine: string): Boolean;
var
  Percent: Integer;
begin
  Result := TryParse7ZipPercent(ALine, Percent);
  if Result then
  begin
    Latest7ZipPercent := Max(Latest7ZipPercent, Min(99, Percent));
    Done := Round(Total * (Latest7ZipPercent / 100.0));
    Report(Latest7ZipPercent);
  end;
end;

function BuildZipArguments(const AParent, AName, AZip: string;
  AUsing7Zip, AStore: Boolean): string;
begin
  if AUsing7Zip then
  begin
    if AStore then
      Result := 'a -tzip -mx=0'
    else
      Result := 'a -tzip -mx=5';
    Result := Result + ' -mmt=on -bsp1 -bso0 -sccUTF-8 ' + Quote(AZip) + ' -- '
      + Quote(AName);
  end
  else
  begin
    Result := '-a -c -v --options ';
    if AStore then
      Result := Result + 'zip:compression=store,';
    { The ZIP header encoding is independent of tar's console output. }
    Result := Result + 'zip:hdrcharset=UTF-8';
    Result := Result + ' -f ' + Quote(AZip) + ' -C ' + Quote(AParent) + ' -- ' +
      Quote(AName);
  end;
end;

function Find7Zip: string;
const
  Views: array [0 .. 1] of Cardinal = (KEY_WOW64_64KEY, KEY_WOW64_32KEY);
  Values: array [0 .. 1] of string = ('Path64', 'Path');
  EnvVars: array [0 .. 1] of string = ('ProgramW6432', 'ProgramFiles');
var
  Reg: TRegistry;
  View: Cardinal;
  Value, Path, EnvVar: string;

  function ExecutableIn(const APath: string): string;
  begin
    Result := '';
    if IsAbsoluteFileSystemPath(APath) then
    begin
      Path := TPath.Combine(APath, '7z.exe');
      if FileExists(Path) then
        Result := Path;
    end;
  end;

begin
  Result := '';
  for View in Views do
  begin
    Reg := TRegistry.Create(KEY_READ or View);
    try
      Reg.RootKey := HKEY_LOCAL_MACHINE;
      if Reg.OpenKeyReadOnly('SOFTWARE\7-Zip') then
        for Value in Values do
          if Reg.GetDataType(Value) in [rdString, rdExpandString] then
          begin
            Result := ExecutableIn(ExpandEnvVars(Reg.ReadString(Value)));
            if Result <> '' then
              Exit;
          end;
    finally
      Reg.Free;
    end;
  end;
  for EnvVar in EnvVars do
  begin
    Path := System.SysUtils.GetEnvironmentVariable(EnvVar);
    if Path <> '' then
    begin
      Result := ExecutableIn(TPath.Combine(Path, '7-Zip'));
      if Result <> '' then
        Exit;
    end;
  end;
end;

function CreateBackupZip(const AFolder, AZip: string; AStore: Boolean;
  const ARunner: IProcessRunner; const ALogger: ILogger;
  const AProgress: TProgressProc): Boolean;
var
  Runner: IStreamingProcessRunner;
  Sizes: TDictionary<string, Int64>;
  Progress: TZipProgress;
  Pending, Size: Int64;
  Folder, Parent, Name, SevenZip, Exe, Args, TempZip, Diagnostic: string;
  ID: TGUID;
  Code, CodePage: Cardinal;
  Streaming, Using7Zip: Boolean;

begin
  ALogger.Debug('Preparando compactação da pasta: ' + AFolder);
  Streaming := Supports(ARunner, IStreamingProcessRunner, Runner);
  if not Streaming and not AStore then
    Exit(ARunner.ZipFolder(AFolder, AZip));

  Folder := NormalizePath(AFolder);
  Parent := ExtractFileDir(Folder);
  Name := ExtractFileName(Folder);
  if Streaming then
    SevenZip := Find7Zip;
  Using7Zip := SevenZip <> '';
  if CreateGUID(ID) <> S_OK then
    raise EDelphiBackupError.Create
      ('Não foi possível gerar o nome do ZIP temporário.');
  TempZip := TPath.Combine(ExtractFileDir(NormalizePath(AZip)),
    'dbr-' + GUIDToString(ID) + '.zip');
  if Using7Zip then
  begin
    Exe := SevenZip;
    CodePage := CP_UTF8;
  end
  else
  begin
    Exe := 'tar.exe';
    CodePage := GetACP;
  end;
  Args := BuildZipArguments(Parent, Name, TempZip, Using7Zip, AStore);

  Sizes := TDictionary<string, Int64>.Create;
  try
    Progress := Default (TZipProgress);
    Progress.Callback := AProgress;
    Progress.Action := 'Compactando';
    if Assigned(AProgress) then
      if ListFilesInTree(Folder, nil, Sizes) then
        for Size in Sizes.Values do
          Inc(Progress.Total, Size)
      else
        ALogger.Warn
          ('Não foi possível calcular o tamanho da pasta para o progresso do ZIP.');
    Pending := 0;
    Progress.LastPercent := -1;
    Progress.Started := GetTickCount64;
    Progress.Report(0);

    if Streaming then
      Code := Runner.RunLines(Exe, Args, Parent, CodePage,
        procedure(const ALine: string)
        begin
          if Using7Zip then
          begin
            if not Progress.Report7ZipLine(ALine) and (Trim(ALine) <> '') then
              Diagnostic := ALine;
          end
          else
          begin
            if not StartsStr('a ', ALine) then
            begin
              Diagnostic := ALine;
              Exit;
            end;
            { bsdtar announces an entry before writing its data. A subsequent
              entry confirms that the previous one was processed. }
            Inc(Progress.Done, Pending);
            TryTakeTarFileSize(ALine, Name, Sizes, Pending);
            Progress.Report(Min(99, ZipPercent(Progress.Done, Progress.Total)));
          end;
        end)
    else
      Code := ARunner.Run(Exe, Args, Parent, Diagnostic);
    Result := Code = 0;
    if not Result then
    begin
      ALogger.Warn(Format('A criação do arquivo ZIP falhou (código %d): %s',
        [Code, Diagnostic]));
      Exit;
    end;

    if not MoveFileEx(PChar(TempZip), PChar(NormalizePath(AZip)),
      MOVEFILE_REPLACE_EXISTING) then
      RaiseLastOSError;
    Progress.Done := Progress.Total;
    Progress.Report(100);
    ALogger.Debug('Arquivo ZIP criado: ' + AZip);
  finally
    Sizes.Free;
    if FileExists(TempZip) and not System.SysUtils.DeleteFile(TempZip) then
      ALogger.Warn('Não foi possível remover o ZIP temporário: ' + TempZip);
  end;
end;

function ListBackupZip(const AZip: string; const ARunner: IProcessRunner;
const ALogger: ILogger; AEntries: TStrings): Boolean;
var
  Runner: IStreamingProcessRunner;
  Output: string;
begin
  ALogger.Debug('Listando conteúdo do ZIP: ' + AZip);
  AEntries.Clear;
  { Check that Windows tar can read the ZIP even without 7-Zip installed. }
  if Supports(ARunner, IStreamingProcessRunner, Runner) then
    Result := Runner.RunLines('tar.exe', '-t -f ' + Quote(AZip), '', GetACP,
      procedure(const ALine: string)
      begin
        AEntries.Add(ALine);
      end) = 0
  else
  begin
    Result := ARunner.Run('tar.exe', '-t -f ' + Quote(AZip), '', Output) = 0;
    AEntries.Text := Output;
  end;
  if Result then
    ALogger.Debug(Format('%d entradas listadas no ZIP.', [AEntries.Count]))
  else
    ALogger.Warn('Não foi possível listar o conteúdo do ZIP: ' + AZip);
end;

function TryParseTarListing(const ALine: string; out AName: string;
out ASize: Int64): Boolean;
var
  Field, First, P: Integer;
begin
  Result := False;
  P := 1;
  { bsdtar -tv prints mode, link count, owner, group, size and three date
    fields. The remainder is the filename, including any spaces. }
  for Field := 1 to 8 do
  begin
    while (P <= Length(ALine)) and (ALine[P] = ' ') do
      Inc(P);
    First := P;
    while (P <= Length(ALine)) and (ALine[P] <> ' ') do
      Inc(P);
    if First = P then
      Exit;
    if (Field = 5) and (not TryStrToInt64(Copy(ALine, First, P - First), ASize)
      or (ASize < 0)) then
      Exit;
  end;
  AName := StringReplace(Copy(ALine, P + 1, MaxInt), '/', '\', [rfReplaceAll]);
  Result := AName <> '';
end;

function IsPlainZipPath(const AName: string): Boolean;
var
  Part: string;
begin
  Result := False;
  if (AName[1] = '\') or (Pos(':', AName) > 0) then
    Exit;
  for Part in AName.Split(['\']) do
    if Part = '..' then
      Exit;
  Result := True;
end;

function ExtractBackupZip(const AZip, ADest: string;
const ARunner: IProcessRunner; const ALogger: ILogger;
const AProgress: TProgressProc): Boolean;
var
  Runner: IStreamingProcessRunner;
  Sizes: TDictionary<string, Int64>;
  Progress: TZipProgress;
  Exe, Args, Name, Diagnostic: string;
  Code, CodePage: Cardinal;
  Size, Pending: Int64;
  HaveSizes, PlainEntries, Using7Zip: Boolean;
begin
  ALogger.Debug('Preparando extração do ZIP: ' + AZip);
  if not Supports(ARunner, IStreamingProcessRunner, Runner) then
  begin
    if Assigned(AProgress) then
      AProgress(0, 0, 'Extraindo backup...');
    Exit(ARunner.UnzipTo(AZip, ADest));
  end;

  Sizes := TDictionary<string, Int64>.Create;
  try
    Progress := Default (TZipProgress);
    Progress.Action := 'Extraindo backup';
    Progress.Callback := AProgress;
    Progress.LastPercent := -1;
    HaveSizes := True;
    PlainEntries := True;
    if Assigned(AProgress) then
      AProgress(0, 0, 'Listando arquivos do backup...');
    Code := Runner.RunLines('tar.exe', '-t -v -f ' + Quote(AZip), '', GetACP,
      procedure(const ALine: string)
      begin
        if not TryParseTarListing(ALine, Name, Size) then
        begin
          HaveSizes := False;
          Diagnostic := ALine;
          Exit;
        end;
        PlainEntries := PlainEntries and CharInSet(ALine[1], ['-', 'd']) and
          IsPlainZipPath(Name);
        if ALine[1] = '-' then
        begin
          if Sizes.ContainsKey(Name) or (Size > High(Int64) - Progress.Total)
          then
            HaveSizes := False
          else
          begin
            Sizes.Add(Name, Size);
            Inc(Progress.Total, Size);
          end;
        end;
      end);
    HaveSizes := HaveSizes and (Code = 0);
    if not HaveSizes then
      ALogger.Warn('Não foi possível listar os tamanhos do ZIP: ' + Diagnostic);

    { Keep bsdtar's extraction checks for archives containing special entries. }
    if HaveSizes and PlainEntries then
      Exe := Find7Zip;
    Using7Zip := Exe <> '';
    if Using7Zip then
    begin
      Args := 'x -tzip -y -aoa -bsp1 -bso0 -sccUTF-8 -o' + Quote(ADest) + ' -- '
        + Quote(AZip);
      CodePage := CP_UTF8;
    end
    else
    begin
      Exe := 'tar.exe';
      Args := '-x -v -f ' + Quote(AZip) + ' -C ' + Quote(ADest);
      CodePage := GetACP;
    end;

    Pending := 0;
    Diagnostic := '';
    Progress.Started := GetTickCount64;
    if HaveSizes then
      Progress.Report(0)
    else if Assigned(AProgress) then
      AProgress(0, 0, 'Extraindo backup...');
    Code := Runner.RunLines(Exe, Args, '', CodePage,
      procedure(const ALine: string)
      begin
        if Using7Zip then
        begin
          if not Progress.Report7ZipLine(ALine) and (Trim(ALine) <> '') then
            Diagnostic := ALine;
        end
        else
        begin
          if not StartsStr('x ', ALine) then
          begin
            Diagnostic := ALine;
            Exit;
          end;
          if not HaveSizes then
            Exit;
          { A subsequent entry confirms the previous file was processed. }
          Inc(Progress.Done, Pending);
          TryTakeEntrySize(ALine, 'x ', Sizes, Pending);
          Progress.Report(Min(99, ZipPercent(Progress.Done, Progress.Total)));
        end;
      end);
    Result := Code = 0;
    if Result then
    begin
      if HaveSizes then
      begin
        Progress.Done := Progress.Total;
        Progress.Report(100, True);
      end;
      ALogger.Debug('Arquivo ZIP extraído: ' + AZip);
    end
    else
      ALogger.Warn(Format('A extração do arquivo ZIP falhou (código %d): %s',
        [Code, Diagnostic]));
  finally
    Sizes.Free;
  end;
end;

end.
