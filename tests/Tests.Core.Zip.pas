unit Tests.Core.Zip;

interface

uses
  DUnitX.TestFramework, Core.Types, Tests.Core.RestoreSafety;

type

  [TestFixture]
  TTestZip = class(TRestoreTestContext)
  private type
    TZipRunner = class(TTestRunner, IStreamingProcessRunner)
    public
      function RunLines(const AExe, AArgs, AWorkDir: string;
        ACodePage: Cardinal; const AOnLine: TProcessLineProc): Cardinal;
    end;

    TExtractRunner = class(TTestRunner, IStreamingProcessRunner)
    public
      ForceTar, FailExtraction: Boolean;
      function RunLines(const AExe, AArgs, AWorkDir: string;
        ACodePage: Cardinal; const AOnLine: TProcessLineProc): Cardinal;
    end;

  procedure CheckRealBackupZip(AStore: Boolean);
  procedure CheckZipProgress(AStore: Boolean);
  procedure CheckExtractionProgress(AForceTar: Boolean);
  public
    [Test]
    procedure FormatsPortugueseZipEta;
    [Test]
    procedure MapsTarEntryWithSpacesAndForwardSlashes;
    [Test]
    procedure Parses7ZipPercentFrames;
    [Test]
    procedure BackupEmitsThrottledMonotonicZipProgress;
    [Test]
    procedure StoreBackupEmitsThrottledMonotonicZipProgress;
    [Test]
    procedure StreamsCarriageReturnsAndSplitUtf8;
    [Test]
    procedure ExtractsZipAndReportsUnpackedBytes;
    [Test]
    procedure TarExtractionReportsCompletedFiles;
    [Test]
    procedure ExtractionFailureCleansTempAndDoesNotReportCompletion;
    [Test]
    procedure CancelsChildWhileItIsNotWritingOutput;
    [Test]
    procedure BackupVerifiesAndRemovesFolderAfterRealZip;
    [Test]
    procedure BackupVerifiesAndRemovesFolderAfterRealStoreZip;
    [Test]
    procedure Builds7ZipAndTarArgumentsForBothModes;
    [Test]
    procedure WindowsTarStorePreservesEntryNamesAndMethod;
    [Test]
    procedure ReadsZipStoreConfigRoundTrip;
    [Test]
    procedure ParsesBackupOnlyZipStoreAndRejectsNoZipConflict;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.IOUtils,
  System.StrUtils, System.JSON, System.Zip, Winapi.Windows, Core.BackupEngine,
  Core.ProcessRunner, Core.RestoreEngine, Core.SystemUtils, Core.ToolConfig,
  Core.Zip;

procedure TTestZip.FormatsPortugueseZipEta;
const
  MB = 1024 * 1024;
begin
  Assert.AreEqual('Compactando: 25% (1,0 de 4,0 GB) - 8,0 MB/s - faltam ~7 min',
    FormatZipProgress(1024 * MB, Int64(4096) * MB, 128));
  Assert.AreEqual('Compactando: 50% (5,0 de 10,0 MB) - 2,5 MB/s - faltam ~2 s',
    FormatZipProgress(5 * MB, 10 * MB, 2));
  Assert.AreEqual('Compactando: 0% (0,0 de 0,0 MB)',
    FormatZipProgress(0, 0, 0));
  Assert.AreEqual('Compactando: 100% (10,0 de 10,0 MB) - 5,0 MB/s',
    FormatZipProgress(10 * MB, 10 * MB, 2));
end;

procedure TTestZip.MapsTarEntryWithSpacesAndForwardSlashes;
var
  Sizes: TDictionary<string, Int64>;
  Size: Int64;
begin
  Sizes := TDictionary<string, Int64>.Create;
  try
    Sizes.Add('sub dir\arquivo teste.txt', 123);
    Assert.IsFalse(TryTakeTarFileSize('a backup top/sub dir/', 'backup top',
      Sizes, Size));
    Assert.IsFalse(TryTakeTarFileSize('a backup top2/sub dir/arquivo teste.txt',
      'backup top', Sizes, Size));
    Assert.IsTrue(TryTakeTarFileSize('a backup top/sub dir/arquivo teste.txt',
      'backup top', Sizes, Size));
    Assert.AreEqual<Int64>(123, Size);
    Assert.IsFalse(TryTakeTarFileSize('a backup top/sub dir/arquivo teste.txt',
      'backup top', Sizes, Size));
  finally
    Sizes.Free;
  end;
end;

procedure TTestZip.Parses7ZipPercentFrames;
var
  Percent: Integer;
begin
  Assert.IsTrue(TryParse7ZipPercent('  0%', Percent));
  Assert.AreEqual(0, Percent);
  Assert.IsTrue(TryParse7ZipPercent(' 37% 3 + arquivo com espaços', Percent));
  Assert.AreEqual(37, Percent);
  Assert.IsTrue(TryParse7ZipPercent('100%', Percent));
  Assert.AreEqual(100, Percent);
  Assert.IsFalse(TryParse7ZipPercent('arquivo 50%.txt', Percent));
  Assert.IsFalse(TryParse7ZipPercent('37%.txt', Percent));
  Assert.IsFalse(TryParse7ZipPercent('101%', Percent));
end;

function TTestZip.TZipRunner.RunLines(const AExe, AArgs, AWorkDir: string;
  ACodePage: Cardinal; const AOnLine: TProcessLineProc): Cardinal;
var
  QuoteStart, QuoteEnd: Integer;
  Archive, Root: string;
begin
  QuoteStart := Pos('"', AArgs);
  QuoteEnd := PosEx('"', AArgs, QuoteStart + 1);
  Archive := Copy(AArgs, QuoteStart + 1, QuoteEnd - QuoteStart - 1);
  if SameText(AExe, 'tar.exe') then
  begin
    Root := Copy(AArgs, LastDelimiter(' ', AArgs) + 2, MaxInt);
    SetLength(Root, Length(Root) - 1);
    AOnLine('a ' + Root + '/manifest.json');
    Sleep(2050);
    AOnLine('a ' + Root + '/backup.log');
    AOnLine('a ' + Root);
  end
  else
  begin
    AOnLine('  0%');
    Sleep(2050);
    AOnLine(' 50%');
    AOnLine(' 17%');
  end;
  TFile.WriteAllText(Archive, 'zip simulado');
  Result := 0;
end;

procedure TTestZip.CheckZipProgress(AStore: Boolean);
var
  Runner: IProcessRunner;
  Engine: TBackupEngine;
  Items: TBackupItemList;
  Options: TBackupOptions;
  Destination: string;
  Samples: TList<Integer>;
begin
  Destination := TPath.Combine(FTemp, 'progress');
  ForceDirectories(Destination);
  Options := Default (TBackupOptions);
  Options.Destination := Destination;
  Options.CreateZip := True;
  Options.KeepFolder := True;
  Options.ZipStore := AStore;
  Runner := TZipRunner.Create;
  Samples := TList<Integer>.Create;
  Items := TBackupItemList.Create;
  Engine := TBackupEngine.Create(FLogger, Runner);
  try
    Assert.IsTrue(FileExists(Engine.Execute(Options, FInstalled, Items, nil,
      nil, procedure(ACurrent, ATotal: Integer; const AStep: string)
      begin
        Assert.AreEqual(100, ATotal);
        Assert.IsTrue(StartsStr(Format('Compactando: %d%%',
          [ACurrent]), AStep));
        if Samples.Count > 0 then
          Assert.IsTrue(ACurrent > Samples.Last);
        Samples.Add(ACurrent);
      end)));
    Assert.AreEqual(2, Samples.Count);
    Assert.AreEqual(0, Samples[0]);
    Assert.IsTrue((Samples[1] > Samples[0]) and (Samples[1] < 100));
  finally
    Engine.Free;
    Items.Free;
    Samples.Free;
  end;
end;

procedure TTestZip.BackupEmitsThrottledMonotonicZipProgress;
begin
  CheckZipProgress(False);
end;

procedure TTestZip.StoreBackupEmitsThrottledMonotonicZipProgress;
begin
  CheckZipProgress(True);
end;

procedure TTestZip.StreamsCarriageReturnsAndSplitUtf8;
var
  Runner: IStreamingProcessRunner;
  Lines: TStringList;
begin
  Assert.IsTrue(Supports(CreateProcessRunner(FLogger),
    IStreamingProcessRunner, Runner));
  Lines := TStringList.Create;
  try
    Assert.AreEqual<Cardinal>(0, Runner.RunLines(ParamStr(0),
      '--zip-pipe-child', FTemp, CP_UTF8, procedure(const ALine: string)
      begin
        Lines.Add(ALine);
        if ALine = '37%' then
          TFile.WriteAllText(TPath.Combine(FTemp, 'pipe-ready'), '');
      end));
    Assert.AreEqual(3, Lines.Count);
    Assert.AreEqual('37%', Lines[0]);
    Assert.AreEqual('ação', Lines[1]);
    Assert.AreEqual('última', Lines[2]);
  finally
    Lines.Free;
  end;
end;

function TTestZip.TExtractRunner.RunLines(const AExe, AArgs, AWorkDir: string;
ACodePage: Cardinal; const AOnLine: TProcessLineProc): Cardinal;
const
  FirstFile = 'backup top/arquivo de 6 GB.txt';
  SecondFile = 'backup top/arquivo de 9 GB.txt';
  Manifest = 'backup top/manifest.json';
var
  Start, Finish: Integer;
begin
  Result := 0;
  if StartsStr('-t -v -f ', AArgs) then
  begin
    Assert.AreEqual('tar.exe', AExe);
    AOnLine('drwxrwxrwx  0 0      0          0 Nov 23 2025 backup top/');
    AOnLine('-rw-rw-rw-  0 0      0 6442450944 Nov 23 16:52 ' + FirstFile);
    AOnLine('-rw-rw-rw-  0 0      0 9663676416 Nov 23 16:52 ' + SecondFile);
    AOnLine('-rw-rw-rw-  0 0      0          0 Nov 23 16:52 ' + Manifest);
    if ForceTar then
      AOnLine('lrwxrwxrwx  0 0      0          0 Nov 23 16:52 link -> backup top');
    Exit;
  end;

  if AExe = 'tar.exe' then
  begin
    Assert.IsTrue(StartsStr('-x -v -f ', AArgs));
    Start := Pos(' -C "', AArgs) + Length(' -C "');
  end
  else
  begin
    Assert.IsFalse(ForceTar);
    Assert.IsTrue(StartsStr('x -tzip -y -aoa -bsp1 ', AArgs));
    Assert.AreEqual<Cardinal>(CP_UTF8, ACodePage);
    Start := Pos(' -o"', AArgs) + Length(' -o"');
  end;
  Finish := PosEx('"', AArgs, Start);
  Extracted := Copy(AArgs, Start, Finish - Start);
  ForceDirectories(TPath.Combine(Extracted, 'backup top'));
  if FailExtraction then
  begin
    AOnLine('Falha simulada de extração.');
    Exit(1);
  end;
  if AExe = 'tar.exe' then
  begin
    AOnLine('x ' + FirstFile);
    Sleep(2050);
    AOnLine('x ' + SecondFile);
    AOnLine('x ' + Manifest);
  end
  else
  begin
    AOnLine('  0%');
    Sleep(2050);
    AOnLine(' 40% 1 - ' + FirstFile);
    AOnLine(' 17%');
  end;
  TFile.Copy(ZipManifest, TPath.Combine(Extracted, Manifest));
end;

procedure TTestZip.CheckExtractionProgress(AForceTar: Boolean);
var
  Fake: TExtractRunner;
  Engine: TRestoreEngine;
  Zip: string;
  Samples: TList<Integer>;
  Stages: TStringList;
begin
  Zip := PrepareZip;
  Fake := TExtractRunner.Create;
  Fake.ZipManifest := FFake.ZipManifest;
  Fake.ForceTar := AForceTar;
  Samples := TList<Integer>.Create;
  Stages := TStringList.Create;
  Engine := TRestoreEngine.Create(FLogger, Fake);
  try
    Engine.Open(Zip, procedure(ACurrent, ATotal: Integer; const AStep: string)
      begin
        if ATotal = 0 then
          Stages.Add(AStep)
        else
        begin
          Assert.AreEqual(100, ATotal);
          Samples.Add(ACurrent);
          if ACurrent = 40 then
          begin
            Assert.IsTrue(StartsStr('Extraindo backup: 40% (6,0 de 15,0 GB)',
              AStep), AStep);
            Assert.IsTrue(ContainsStr(AStep, 'MB/s - faltam ~'), AStep);
          end;
        end;
      end);
    Assert.AreEqual(3, Stages.Count);
    Assert.AreEqual('Abrindo backup...', Stages[0]);
    Assert.AreEqual('Listando arquivos do backup...', Stages[1]);
    Assert.AreEqual('Lendo manifesto...', Stages[2]);
    Assert.AreEqual(3, Samples.Count);
    Assert.AreEqual(0, Samples[0]);
    Assert.AreEqual(40, Samples[1]);
    Assert.AreEqual(100, Samples[2]);
    Assert.AreEqual(1, Engine.Manifest.Versions.Count);
  finally
    Engine.Free;
    Stages.Free;
    Samples.Free;
  end;
end;

procedure TTestZip.ExtractsZipAndReportsUnpackedBytes;
begin
  CheckExtractionProgress(False);
end;

procedure TTestZip.TarExtractionReportsCompletedFiles;
begin
  CheckExtractionProgress(True);
end;

procedure TTestZip.ExtractionFailureCleansTempAndDoesNotReportCompletion;
var
  Fake: TExtractRunner;
  Engine: TRestoreEngine;
  Zip: string;
  Completed: Boolean;
begin
  Zip := PrepareZip;
  Fake := TExtractRunner.Create;
  Fake.FailExtraction := True;
  Engine := TRestoreEngine.Create(FLogger, Fake);
  Completed := False;
  try
    Assert.WillRaise(procedure
      begin
        Engine.Open(Zip,
          procedure(ACurrent, ATotal: Integer; const AStep: string)
          begin
            if ACurrent = 100 then
              Completed := True;
          end);
      end, EDelphiBackupError);
    Assert.IsFalse(Completed);
    Assert.IsTrue(Fake.Extracted <> '');
    Assert.IsFalse(DirectoryExists(Fake.Extracted));
  finally
    Engine.Free;
  end;
end;

procedure TTestZip.CancelsChildWhileItIsNotWritingOutput;
var
  Runner: IStreamingProcessRunner;
  LastOutput: UInt64;
begin
  LastOutput := 0;
  Assert.IsTrue(Supports(CreateProcessRunner(FLogger, function: Boolean
    begin
      Result := (LastOutput <> 0) and (GetTickCount64 - LastOutput >= 100);
    end), IStreamingProcessRunner, Runner));
  Assert.WillRaise(procedure
    begin
      Runner.RunLines(ParamStr(0), '--zip-pipe-child', FTemp, CP_UTF8,
        procedure(const ALine: string)
        begin
          if ALine = '37%' then
            LastOutput := GetTickCount64;
        end);
    end, EAbort);
  Assert.IsTrue(GetTickCount64 - LastOutput < 5000);
end;

procedure TTestZip.CheckRealBackupZip(AStore: Boolean);
var
  Engine: TBackupEngine;
  Opener: TRestoreEngine;
  Items: TBackupItemList;
  Options: TBackupOptions;
  Zip: string;
  Archive: TZipFile;
  Item: TBackupItem;
  I: Integer;
  Completed: Boolean;
begin
  Options := Default (TBackupOptions);
  Options.Destination := TPath.Combine(FTemp, 'zip com espaços');
  ForceDirectories(Options.Destination);
  Options.CreateZip := True;
  Options.ZipStore := AStore;
  Items := TBackupItemList.Create;
  Engine := TBackupEngine.Create(FLogger, CreateProcessRunner(FLogger));
  try
    Item := TBackupItem.Create;
    Items.Add(Item);
    Item.Id := 'f001';
    Item.Kind := ikFile;
    Item.Category := icExtra;
    Item.SourcePath := TPath.Combine(FTemp, 'arquivo com espaço.txt');
    TFile.WriteAllText(Item.SourcePath, StringOfChar('a', 4096));
    Include(Options.Categories, icExtra);
    Zip := Engine.Execute(Options, FInstalled, Items, nil, nil);
    Assert.AreEqual(0, Engine.FailureCount);
    Assert.IsTrue(FileExists(Zip));
    Assert.IsFalse(DirectoryExists(ChangeFileExt(Zip, '')),
      'O conteúdo do ZIP deve conferir com a pasta.');
    if AStore then
    begin
      Archive := TZipFile.Create;
      try
        Archive.Open(Zip, zmRead);
        Assert.IsTrue(Archive.FileCount > 0);
        for I := 0 to Archive.FileCount - 1 do
          Assert.AreEqual(0, Integer(Archive.FileInfo[I].CompressionMethod));
      finally
        Archive.Free;
      end;
    end;
    Opener := TRestoreEngine.Create(FLogger, CreateProcessRunner(FLogger));
    Completed := False;
    try
      Opener.Open(Zip, procedure(ACurrent, ATotal: Integer; const AStep: string)
        begin
          if (ACurrent = 100) and (ATotal = 100) then
            Completed := True;
        end);
      Assert.IsTrue(Completed);
      Assert.IsTrue(FileExists(TPath.Combine(Opener.BackupRoot,
        'files\f001\arquivo com espaço.txt')));
    finally
      Opener.Free;
    end;
  finally
    Engine.Free;
    Items.Free;
  end;
end;

procedure TTestZip.BackupVerifiesAndRemovesFolderAfterRealZip;
begin
  CheckRealBackupZip(False);
end;

procedure TTestZip.BackupVerifiesAndRemovesFolderAfterRealStoreZip;
begin
  CheckRealBackupZip(True);
end;

procedure TTestZip.Builds7ZipAndTarArgumentsForBothModes;
const
  Parent = 'C:\Temp\Parent with spaces';
  Name = 'Top folder';
  Zip = 'C:\Temp\Parent with spaces\a.zip';
  SevenZipSuffix =
    ' -mmt=on -bsp1 -bso0 -sccUTF-8 "C:\Temp\Parent with spaces\a.zip" -- "Top folder"';
  TarSuffix =
    'zip:hdrcharset=UTF-8 -f "C:\Temp\Parent with spaces\a.zip" -C "C:\Temp\Parent with spaces" -- "Top folder"';
begin
  Assert.AreEqual('a -tzip -mx=5' + SevenZipSuffix,
    BuildZipArguments(Parent, Name, Zip, True, False));
  Assert.AreEqual('a -tzip -mx=0' + SevenZipSuffix,
    BuildZipArguments(Parent, Name, Zip, True, True));
  Assert.AreEqual('-a -c -v --options ' + TarSuffix,
    BuildZipArguments(Parent, Name, Zip, False, False));
  Assert.AreEqual('-a -c -v --options zip:compression=store,' + TarSuffix,
    BuildZipArguments(Parent, Name, Zip, False, True));
end;

procedure TTestZip.WindowsTarStorePreservesEntryNamesAndMethod;
const
  Top = 'Top folder';
  FileName = 'nome com espaços.txt';
var
  Runner: IProcessRunner;
  Archive: TZipFile;
  Lines: TStringList;
  Source, Zip, Output, Tar: string;
  I: Integer;
  Code: Cardinal;
begin
  Source := TPath.Combine(FTemp, Top);
  ForceDirectories(Source);
  TFile.WriteAllText(TPath.Combine(Source, FileName), StringOfChar('a', 4096));
  Zip := TPath.Combine(FTemp, 'tar store.zip');
  Tar := RealFileSystemPath(TPath.Combine(GetSystem32Dir, 'tar.exe'));
  Runner := CreateProcessRunner(FLogger);
  Code := Runner.Run(Tar, BuildZipArguments(FTemp, Top, Zip, False, True),
    FTemp, Output);
  Assert.AreEqual<Cardinal>(0, Code, Output);
  Lines := TStringList.Create;
  Archive := TZipFile.Create;
  try
    Assert.IsTrue(ListBackupZip(Zip, Runner, FLogger, Lines));
    Assert.IsTrue(Lines.IndexOf(Top + '/' + FileName) >= 0, Lines.Text);
    Archive.Open(Zip, zmRead);
    Assert.AreEqual(2, Archive.FileCount);
    for I := 0 to Archive.FileCount - 1 do
      Assert.AreEqual(0, Integer(Archive.FileInfo[I].CompressionMethod));
  finally
    Archive.Free;
    Lines.Free;
  end;
end;

procedure TTestZip.ReadsZipStoreConfigRoundTrip;
var
  Config: TToolConfig;
  JSON: TJSONObject;
  ConfigPath: string;
  Store: Boolean;
begin
  ConfigPath := TPath.Combine(FTemp, 'config.json');
  Config := TToolConfig.Create;
  try
    Assert.IsFalse(Config.ZipStore);
    for Store := True downto False do
    begin
      JSON := TJSONObject.Create;
      try
        if Store then
          JSON.AddPair('zipStore', TJSONTrue.Create)
        else
          JSON.AddPair('zipStore', TJSONFalse.Create);
        TFile.WriteAllText(ConfigPath, JSON.ToString, TEncoding.UTF8);
      finally
        JSON.Free;
      end;
      Assert.IsTrue(LoadToolConfig(ConfigPath, Config, FLogger));
      Assert.IsTrue(Store = Config.ZipStore);
    end;
    Config.ZipStore := True;
    TFile.WriteAllText(ConfigPath, '{"extraFolders":["C:\\Test"]}',
      TEncoding.UTF8);
    Assert.IsTrue(LoadToolConfig(ConfigPath, Config, FLogger));
    Assert.IsFalse(Config.ZipStore);
    Assert.AreEqual('C:\Test', Config.ExtraFolders[0]);
  finally
    Config.Free;
  end;
end;

procedure TTestZip.ParsesBackupOnlyZipStoreAndRejectsNoZipConflict;
var
  Runner: IStreamingProcessRunner;
  Lines: TStringList;
  Cli: string;

  procedure CheckUsage(const AArgs, AMessage: string);
  begin
    Lines.Clear;
    Assert.AreEqual<Cardinal>(EXIT_USAGE, Runner.RunLines(Cli, AArgs, FTemp,
      CP_UTF8, procedure(const ALine: string)
      begin
        Lines.Add(ALine);
      end));
    Assert.IsTrue(Pos(AMessage, Lines.Text) > 0, Lines.Text);
  end;

begin
  Assert.IsTrue(Supports(CreateProcessRunner(FLogger),
    IStreamingProcessRunner, Runner));
  Cli := TPath.Combine(ExtractFilePath(ParamStr(0)),
    'DelphiBackupRestoreCli.exe');
  Lines := TStringList.Create;
  try
    CheckUsage('backup --zip-store', 'o comando backup exige --dest');
    CheckUsage('backup --zip-store --no-zip',
      '--zip-store é incompatível com --no-zip');
    CheckUsage('backup --no-zip --zip-store',
      '--zip-store é incompatível com --no-zip');
    CheckUsage('list --zip-store',
      '--zip-store só pode ser usada no comando backup');
  finally
    Lines.Free;
  end;
end;

initialization

TDUnitX.RegisterTestFixture(TTestZip);

end.
