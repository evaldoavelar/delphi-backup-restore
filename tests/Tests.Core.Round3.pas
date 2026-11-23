unit Tests.Core.Round3;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections,
  DUnitX.TestFramework, Core.Types,
  Core.BackupEngine, Tests.Core.RestoreSafety;

type

  [TestFixture]
  TTestCoreRound3 = class(TRestoreTestContext)
  private
    procedure CheckPrecheckRejection(const AMessage: string);
  public
    [Test]
    procedure PrecheckRejectsOverlappingDestinations;
    [Test]
    procedure PrecheckProtectsUnselectedRegistryVersions;
    [Test]
    procedure ExecuteValidatesAllRegFilesBeforeChanges;
    [Test]
    procedure ExecuteContinuesAndMergesPathAfterFailures;
    [Test]
    procedure PathMergeFollowsSelectedCategories;
    [Test]
    procedure MalformedRegistryHexIsPreserved;
    [Test]
    procedure RemapPathAcceptsRightDelimiters;
    [Test]
    procedure EstimateSizeWarnsAndReturnsZero;
    [Test]
    procedure QuoteStripsTrailingBackslashes;
    [Test]
    procedure PipeCapturesOutputFromGrandchild;
    [Test]
    procedure MalformedPeReturnsNoImportsOrMachine;
    [Test]
    procedure ZipVerificationIgnoresTarDiagnostics;
    [Test]
    procedure BackupProtectsDetectedUnselectedVersion;
    [Test]
    procedure RestoreRemapsDocumentsAndPublicPaths;
    [Test]
    procedure ManifestLoadsWithoutSourceDocumentsDir;
    [Test]
    procedure CompareToleratesTwoSeconds;
    [Test]
    procedure PeReadRestoresWow64Redirection;
  end;

implementation

uses
  System.IOUtils, System.StrUtils, Winapi.Windows,
  Core.CompareEngine, Core.DllScanner, Core.Manifest, Core.ProcessRunner,
  Core.RestoreEngine, Core.SystemUtils;

type
  TTestBackupEngine = class(TBackupEngine)
  protected
    procedure DetectInstalledVersions(AInstalled: TDelphiVersionList); override;
  public
    UnselectedRoot: string;
  end;

procedure TTestBackupEngine.DetectInstalledVersions
  (AInstalled: TDelphiVersionList);
var
  V: TDelphiVersion;
begin
  V := TDelphiVersion.Create;
  AInstalled.Add(V);
  V.BdsVersion := '23.0';
  V.RootDir := UnselectedRoot;
end;

procedure TTestCoreRound3.CheckPrecheckRejection(const AMessage: string);
begin
  OpenBackup;
  try
    FEngine.Precheck(FOptions, FInstalled);
    Assert.Fail('O pré-check deveria recusar o destino.');
  except
    on E: EPrecheckError do
      Assert.IsTrue(ContainsText(E.Message, AMessage), E.Message);
  end;
  Assert.AreEqual(0, FFake.Calls.Count);
end;

procedure TTestCoreRound3.PrecheckRejectsOverlappingDestinations;
var
  Parent: string;
begin
  Parent := TPath.Combine(FTemp, 'live');
  AddItem('f001', ikFolder, icExtra, Parent);
  AddItem('f002', ikFolder, icExtra, UpperCase(Parent) + '\');
  AddItem('f003', ikFolder, icExtra, TPath.Combine(Parent, 'child'));
  CheckPrecheckRejection('[f002] ' + UpperCase(Parent));
  CheckPrecheckRejection('[f003] ' + TPath.Combine(Parent, 'child'));
  FManifest.Items.Clear;
  AddItem('r001', ikRegistry, icExtra,
    'HKCU\Software\DelphiBackupRestoreTests\Product');
  AddItem('r002', ikRegistry, icExtra,
    'HKCU\software\DelphiBackupRestoreTests\Product\Child');
  CheckPrecheckRejection('destino se sobrepõe ao item [r001]');
  FManifest.Items[1].Item.Versions.Add('23.0');
  OpenBackup;
  FEngine.Precheck(FOptions, FInstalled);
end;

procedure TTestCoreRound3.PrecheckProtectsUnselectedRegistryVersions;
begin
  AddItem('r001', ikRegistry, icExtra, 'HKCU\Software\Embarcadero\BDS');
  CheckPrecheckRejection('versões não selecionadas');
  FManifest.Items[0].Item.SourcePath :=
    'HKCU\Software\Embarcadero\BDS\23.0\Library';
  CheckPrecheckRejection('versões não selecionadas');
  FManifest.Items[0].Item.SourcePath :=
    'HKCU\Software\Embarcadero\BDS\22.0\Library';
  OpenBackup;
  FEngine.Precheck(FOptions, FInstalled);
end;

procedure TTestCoreRound3.ExecuteValidatesAllRegFilesBeforeChanges;
begin
  AddItem('f001', ikFolder, icComponents, TPath.Combine(FTemp, 'live'));
  ForceDirectories(TPath.Combine(FBackup, 'files\f001'));
  AddRegistryFixture('[HKEY_CURRENT_USER\Software\OutOfScope]' + sLineBreak);
  FFake.RegistryValue := 'original';
  OpenBackup;
  Assert.WillRaise(Execute, EDelphiBackupError);
  Assert.AreEqual(0, FFake.Calls.Count);
  Assert.AreEqual(0, FEngine.MergeCalls);
end;

procedure TTestCoreRound3.ExecuteContinuesAndMergesPathAfterFailures;
var
  RegPath: string;
begin
  AddItem('f001', ikFolder, icComponents, TPath.Combine(FTemp, 'one'));
  AddItem('f002', ikFolder, icComponents, TPath.Combine(FTemp, 'two'));
  ForceDirectories(TPath.Combine(FBackup, 'files\f001'));
  ForceDirectories(TPath.Combine(FBackup, 'files\f002'));
  RegPath := AddRegistryFixture;
  OpenBackup;
  FFake.FailTrees := True;
  try
    FEngine.Execute(FOptions, FInstalled,
      procedure(ACurrent, ATotal: Integer; const AMessage: string)
      begin
        if ACurrent = 0 then
          TFile.WriteAllText(RegPath, 'changed after validation',
            TEncoding.Unicode);
      end);
    Assert.Fail('A restauração deveria informar as falhas.');
  except
    on E: EDelphiBackupError do
    begin
      Assert.IsTrue(ContainsText(E.Message, '2 falha(s)'));
      Assert.IsTrue(ContainsText(E.Message, '[f001]'));
      Assert.IsTrue(ContainsText(E.Message, '[f002]'));
    end;
  end;
  Assert.AreEqual('tree,tree,delete,import', FFake.Calls.CommaText);
  Assert.IsTrue(ContainsText(FFake.ImportedText, '"Name"="Value"'));
  Assert.AreEqual(1, FEngine.MergeCalls);
  Assert.IsTrue(ContainsText(FMessages.Text, '2 falha(s)'));
end;

procedure TTestCoreRound3.PathMergeFollowsSelectedCategories;
var
  Plan: TObjectList<TRestorePlanStep>;
  Category: TItemCategory;
  Expected: Integer;
begin
  OpenBackup;
  Expected := 0;
  for Category := Low(TItemCategory) to High(TItemCategory) do
  begin
    FOptions.Categories := [Category];
    Plan := FEngine.BuildPlan(FOptions);
    try
      if Category in [icComponents, icIdeConfig] then
      begin
        Assert.AreEqual(2, Plan.Count);
        Inc(Expected);
      end
      else
        Assert.AreEqual(1, Plan.Count);
    finally
      Plan.Free;
    end;
    Execute;
    Assert.AreEqual(Expected, FEngine.MergeCalls);
  end;
end;

procedure TTestCoreRound3.MalformedRegistryHexIsPreserved;
const
  OddLine = '"Q:\\Old\\Path"=hex(2):43,00,44';
  InvalidLine = '"Q:\\Old\\Other"=hex(7):43,00,\' + sLineBreak + '  rr,00';
  EmbeddedBackslash = '"Q:\\Old\\Extra"=hex(2):4\3,00';
var
  Text: string;
begin
  Text := OddLine + sLineBreak + InvalidLine + sLineBreak + EmbeddedBackslash;
  Assert.AreEqual(Text, RemapRegFileText(Text, 'Q:\Old', 'Q:\New'));
end;

procedure TTestCoreRound3.RemapPathAcceptsRightDelimiters;
begin
  Assert.AreEqual('Q:\New Q:\New'#9'Q:\New=Q:\OldOther',
    RemapProfilePath('Q:\Old Q:\Old'#9'Q:\Old=Q:\OldOther', 'Q:\Old',
    'Q:\New'));
end;

procedure TTestCoreRound3.EstimateSizeWarnsAndReturnsZero;
var
  Item: TBackupItem;
begin
  Item := TBackupItem.Create;
  try
    Item.Kind := ikFolder;
    Item.SourcePath := TPath.Combine(FTemp, 'missing');
    Assert.AreEqual<Int64>(0, EstimateItemSize(Item, nil, FLogger));
    Assert.IsTrue(ContainsText(FMessages.Text,
      'Não foi possível estimar o tamanho'));
  finally
    Item.Free;
  end;
end;

procedure TTestCoreRound3.QuoteStripsTrailingBackslashes;
begin
  Assert.AreEqual('"C:\work area"', Quote('C:\work area\\\'));
  Assert.AreEqual('"C:\\"', Quote('C:\'));
  Assert.AreEqual('"C:\\"', Quote('C:\\\'));
end;

procedure TTestCoreRound3.PipeCapturesOutputFromGrandchild;
var
  Runner: IProcessRunner;
  Output: string;
begin
  Runner := CreateProcessRunner(FLogger);
  Assert.AreEqual<Cardinal>(0, Runner.Run('cmd.exe', '/d /c start "" /b ' +
    Quote(ParamStr(0)) + ' --round3-pipe-child', FTemp, Output));
  Assert.AreEqual('grandchild output', Trim(Output));
end;

procedure TTestCoreRound3.MalformedPeReturnsNoImportsOrMachine;
const
  Nt = $40;
  Optional = Nt + 24;
  Sections = Optional + 112;
  RawOffset = $100;
  NameOffset = RawOffset + $2F;
var
  Bytes: TBytes;
  Names: TStringList;
  FileName: string;

  procedure PutWord(AOffset: Integer; AValue: Word);
  begin
    Move(AValue, Bytes[AOffset], SizeOf(AValue));
  end;

  procedure PutCardinal(AOffset: Integer; AValue: Cardinal);
  begin
    Move(AValue, Bytes[AOffset], SizeOf(AValue));
  end;

  procedure CheckMalformed;
  begin
    TFile.WriteAllBytes(FileName, Bytes);
    Names.Add('stale.dll');
    Assert.IsFalse(ReadPeImports(FileName, Names));
    Assert.AreEqual(0, Names.Count);
    Assert.AreEqual<Word>(0, ReadPeMachine(FileName));
  end;

begin
  SetLength(Bytes, $180);
  PutWord(0, $5A4D);
  PutCardinal($3C, Nt);
  PutCardinal(Nt, $4550);
  PutWord(Nt + 4, $14C);
  PutWord(Nt + 6, 2);
  PutWord(Nt + 20, Sections - Optional);
  PutWord(Optional, $10B);
  PutCardinal(Optional + 60, RawOffset);
  PutCardinal(Optional + 92, 2);
  PutCardinal(Optional + 104, $1000);
  PutCardinal(Optional + 108, 40);
  PutCardinal(Sections + 12, $1000);
  PutCardinal(Sections + 16, $30);
  PutCardinal(Sections + 20, RawOffset);
  PutCardinal(Sections + 40 + 12, $1030);
  PutCardinal(Sections + 40 + 16, $10);
  PutCardinal(Sections + 40 + 20, $160);
  PutCardinal(RawOffset + 12, $1028);
  Bytes[RawOffset + $28] := Ord('a');
  FileName := TPath.Combine(FTemp, 'fixture.dll');
  Names := TStringList.Create;
  try
    TFile.WriteAllBytes(FileName, Bytes);
    Assert.IsTrue(ReadPeImports(FileName, Names));
    Assert.AreEqual('a', Names[0]);
    Assert.AreEqual<Word>($14C, ReadPeMachine(FileName));
    FillChar(Bytes[RawOffset + $28], NameOffset - (RawOffset + $28) + 1,
      Ord('a'));
    CheckMalformed;
    Bytes[RawOffset + $29] := 0;
    PutCardinal(Sections + 16, $1000);
    CheckMalformed;
    PutCardinal(Sections + 16, $30);
    PutCardinal(Sections + 20, $FFFFFFFE);
    CheckMalformed;
  finally
    Names.Free;
  end;
end;

procedure TTestCoreRound3.ZipVerificationIgnoresTarDiagnostics;
var
  Engine: TBackupEngine;
  Options: TBackupOptions;
  Items: TBackupItemList;
  Zip: string;
begin
  Options := Default (TBackupOptions);
  Options.Destination := TPath.Combine(FTemp, 'destination with spaces');
  ForceDirectories(Options.Destination);
  Options.CreateZip := True;
  FFake.ZipDiagnostic := True;
  Engine := TBackupEngine.Create(FLogger, FRunner);
  Items := TBackupItemList.Create(True);
  try
    Zip := Engine.Execute(Options, FInstalled, Items, nil, nil);
    Assert.AreEqual('-t -f ' + Quote(Zip), FFake.ZipListArgs);
    Assert.IsFalse(DirectoryExists(ChangeFileExt(Zip, '')));
  finally
    Items.Free;
    Engine.Free;
  end;
end;

procedure TTestCoreRound3.BackupProtectsDetectedUnselectedVersion;
var
  Engine: TTestBackupEngine;
  Options: TBackupOptions;
  Items: TBackupItemList;
  Item: TBackupItem;
begin
  Options := Default (TBackupOptions);
  Options.Destination := TPath.Combine(FTemp, 'backups');
  Options.Categories := [icComponents];
  Options.Versions := TArray<string>.Create('22.0');
  Engine := TTestBackupEngine.Create(FLogger, FRunner);
  Items := TBackupItemList.Create(True);
  try
    Item := TBackupItem.Create;
    Items.Add(Item);
    Item.Kind := ikFolder;
    Item.Category := icComponents;
    Item.SourcePath := TPath.Combine(FTemp, 'unselected');
    Engine.UnselectedRoot := TPath.Combine(Item.SourcePath, 'installation');
    ForceDirectories(Engine.UnselectedRoot);
    Assert.WillRaise(procedure
      begin
        Engine.Execute(Options, FInstalled, Items, nil, nil);
      end, EDelphiBackupError);
    Assert.AreEqual(0, FFake.Calls.Count);
    Assert.IsFalse(DirectoryExists(Options.Destination));
  finally
    Items.Free;
    Engine.Free;
  end;
end;

function RegEscape(const AValue: string): string;
begin
  Result := StringReplace(AValue, '\', '\\', [rfReplaceAll]);
end;

procedure TTestCoreRound3.RestoreRemapsDocumentsAndPublicPaths;
var
  RegPath, RegText: string;
  Plan: TObjectList<TRestorePlanStep>;
begin
  FManifest.SourceUserProfile := 'Q:\Previous';
  FManifest.SourceDocumentsDir := 'Q:\Previous\Documents';
  FManifest.SourcePublicDir := 'Q:\Past public';
  AddItem('f001', ikFolder, icComponents, FManifest.SourceDocumentsDir
    + '\Lib');
  AddItem('f002', ikFolder, icComponents, FManifest.SourcePublicDir + '\Lib');
  RegPath := AddRegistryFixture('"Paths"="' +
    RegEscape(FManifest.SourceDocumentsDir + '\One;' + FManifest.SourcePublicDir
    + '\Two') + '"' + sLineBreak);
  OpenBackup;
  Assert.AreEqual(FManifest.SourceDocumentsDir,
    FEngine.Manifest.SourceDocumentsDir);
  Plan := FEngine.BuildPlan(FOptions);
  try
    Assert.IsTrue(ContainsText(Plan[1].Description,
      TPath.Combine(GetDocumentsDir, 'Lib')));
    Assert.IsTrue(ContainsText(Plan[2].Description,
      TPath.Combine(GetPublicDir, 'Lib')));
  finally
    Plan.Free;
  end;
  FOptions.Categories := [icExtra];
  Execute;
  RegText := FFake.ImportedText;
  Assert.IsTrue(ContainsText(RegText, RegEscape(TPath.Combine(GetDocumentsDir,
    'One'))));
  Assert.IsTrue(ContainsText(RegText, RegEscape(TPath.Combine(GetPublicDir,
    'Two'))));
  Assert.AreEqual(0, FEngine.MergeCalls);
  Assert.IsTrue(FileExists(RegPath));
end;

procedure TTestCoreRound3.ManifestLoadsWithoutSourceDocumentsDir;
var
  FileName, Json: string;
  Loaded: TManifest;
begin
  FileName := TPath.Combine(FBackup, BACKUP_MANIFEST_FILE);
  SaveManifest(FManifest, FileName);
  Json := TFile.ReadAllText(FileName, TEncoding.UTF8);
  Assert.IsTrue(ContainsText(Json, '"sourceDocumentsDir": "",'));
  Json := StringReplace(Json, '"sourceDocumentsDir": "",', '', []);
  TFile.WriteAllText(FileName, Json, TEncoding.UTF8);
  Loaded := LoadManifest(FileName);
  try
    Assert.AreEqual('', Loaded.SourceDocumentsDir);
  finally
    Loaded.Free;
  end;
end;

procedure TTestCoreRound3.CompareToleratesTwoSeconds;
var
  Current: TManifest;
  Item: TManifestItem;
  BackFile, LiveFile: TManifestFile;

  procedure CheckDifferences(AExpected: Integer);
  var
    Diff: TCompareResult;
  begin
    Diff := DiffManifests(FManifest, Current, nil);
    try
      Assert.AreEqual(AExpected, Diff.Entries.Count);
    finally
      Diff.Free;
    end;
  end;

begin
  FManifest.Versions.Clear;
  AddItem('f001', ikFolder, icExtra, TPath.Combine(FTemp, 'live'));
  BackFile := TManifestFile.Create;
  FManifest.Items[0].Files.Add(BackFile);
  BackFile.RelPath := 'a.txt';
  BackFile.Size := 1;
  BackFile.ModifiedUtc := '2026-01-01T23:59:59Z';
  Current := TManifest.Create;
  try
    Item := TManifestItem.Create;
    Current.Items.Add(Item);
    Item.Item := TBackupItem.Create;
    Item.Item.Kind := ikFolder;
    Item.Item.SourcePath := FManifest.Items[0].Item.SourcePath;
    LiveFile := TManifestFile.Create;
    Item.Files.Add(LiveFile);
    LiveFile.RelPath := BackFile.RelPath;
    LiveFile.Size := 1;
    LiveFile.ModifiedUtc := '2026-01-02T00:00:01Z';
    CheckDifferences(0);
    LiveFile.ModifiedUtc := '2026-01-01T23:59:57Z';
    CheckDifferences(0);
    LiveFile.ModifiedUtc := '2026-01-02T00:00:02Z';
    CheckDifferences(1);
    LiveFile.ModifiedUtc := BackFile.ModifiedUtc;
    LiveFile.Size := 2;
    CheckDifferences(1);
  finally
    Current.Free;
  end;
end;

procedure TTestCoreRound3.PeReadRestoresWow64Redirection;
var
  SysFile: string;
  NativeMachine, RedirectedMachine: Word;

  function ReadRedirectedMachine: Word;
  var
    Stream: TFileStream;
    NtOffset: Cardinal;
  begin
    Stream := TFileStream.Create(SysFile, fmOpenRead or fmShareDenyNone);
    try
      Stream.Position := $3C;
      Stream.ReadBuffer(NtOffset, SizeOf(NtOffset));
      Stream.Position := NtOffset + 4;
      Stream.ReadBuffer(Result, SizeOf(Result));
    finally
      Stream.Free;
    end;
  end;

begin
  SysFile := TPath.Combine(GetSystem32Dir, 'kernel32.dll');
  RedirectedMachine := ReadRedirectedMachine;
  NativeMachine := ReadPeMachine(SysFile);
  Assert.AreNotEqual<Word>(0, NativeMachine);
  if not SameText(SysFile, RealFileSystemPath(SysFile)) then
    Assert.AreNotEqual<Word>(RedirectedMachine, NativeMachine);
  Assert.AreEqual<Word>(RedirectedMachine, ReadRedirectedMachine);
  Assert.AreEqual<Word>(0, ReadPeMachine(TPath.Combine(GetSystem32Dir,
    'DelphiBackupRestore_DoesNotExist.dll')));
  Assert.AreEqual<Word>(RedirectedMachine, ReadRedirectedMachine);
end;

initialization

TDUnitX.RegisterTestFixture(TTestCoreRound3);

end.
