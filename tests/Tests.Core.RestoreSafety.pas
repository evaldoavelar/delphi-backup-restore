unit Tests.Core.RestoreSafety;

interface

uses
  System.Classes, System.SysUtils, DUnitX.TestFramework, Core.Types,
  Core.RestoreEngine;

type
  TRestoreTestContext = class
  protected type
    TTestRunner = class(TInterfacedObject, IProcessRunner)
    public
      Calls: TStringList;
      RegistryQueries: TStringList;
      TreeDirs: TStringList;
      TreeFiles: TStringList;
      TreeMirror, FailTrees: Boolean;
      RegistryValue, ImportedText: string;
      ImportFailure: Integer;
      Extracted: string;
      ZipManifest: string;
      UnzipFails: Boolean;
      ZipFolderName: string;
      ZipWrongName, ZipDiagnostic: Boolean;
      ZipListArgs: string;
      constructor Create;
      destructor Destroy; override;
      function Run(const AExe, AArgs, AWorkDir: string; out AOutput: string)
        : Cardinal;
      function CopyTree(const ASource, ADest: string; AMirror: Boolean;
        AExcludeDirs, AExcludeFiles: TStrings): Boolean;
      function CopyFile(const ASourceFile, ADestDir: string): Boolean;
      function RegExport(const AKey, AFileName: string): Boolean;
      function RegImport(const AFileName: string; AHklm32: Boolean): Boolean;
      function RegDelete(const AKey: string): Boolean;
      function RegKeyExists(const AKey: string): Boolean;
      function ZipFolder(const AFolder, AZipFile: string): Boolean;
      function UnzipTo(const AZipFile, ADestFolder: string): Boolean;
    end;

    TTestRestoreEngine = class(TRestoreEngine)
    protected
      procedure CheckHostRequirements; override;
      procedure MergeUserPath; override;
      function UserDocumentsDirectory: string; override;
    public
      DocumentsPath: string;
      MergeCalls: Integer;
    end;
  protected
    FTemp, FBackup: string;
    FInstalled: TDelphiVersionList;
    FVersion: TDelphiVersion;
    FManifest: TManifest;
    FLogger: ILogger;
    FRunner: IProcessRunner;
    FFake: TTestRunner;
    FEngine: TTestRestoreEngine;
    FOptions: TRestoreOptions;
    FTemps, FMessages: TStringList;
    function AddItem(const AId: string; AKind: TItemKind;
      ACategory: TItemCategory; const ADest: string): TBackupItem;
    function AddRegistryFixture(const AExtraSection: string = ''): string;
    procedure OpenBackup;
    procedure Execute;
    function PrepareZip: string;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;
  end;

  [TestFixture]
  TTestRestoreSafety = class(TRestoreTestContext)
  private
    procedure CheckRollback(AFailure: Integer; AKeyExists: Boolean);
    procedure CheckZipVerification(AWrongName: Boolean);
  public
    [Test]
    procedure PrecheckAggregatesResolvedDestinationViolations;
    [Test]
    procedure PrecheckAcceptsListedIdeFolderAndAllowedRegistryKeys;
    [Test]
    procedure PrecheckRejectsDestinationInExtractionOutsideBackupRoot;
    [Test]
    procedure RegistryRejectsSectionsOutsideItem;
    [Test]
    procedure RegistryRestoresSnapshotWhenImportFails;
    [Test]
    procedure RegistryRestoresSnapshotWhenImportRaises;
    [Test]
    procedure RegistryRemovesPartialKeyWhenNoSnapshotExists;
    [Test]
    procedure InstallerKeysAreSkipped;
    [Test]
    procedure CompareSkipsInstallerKeys;
    [Test]
    procedure CompareListsRegistryValueChanges;
    [Test]
    procedure CompareLimitsRegistryDetails;
    [Test]
    procedure RegistrySecurityExportsRemainInDocuments;
    [Test]
    procedure RestoreUsesRecordedExclusionsAndLegacyCopyOnly;
    [Test]
    procedure RobocopyMirrorPreservesExcludedDestinationEntries;
    [Test]
    procedure CompareUsesRecordedExclusions;
    [Test]
    procedure DllKeepsExistingFileWithUnreadableVersion;
    [Test]
    procedure DllRequiresMatchingPeMachine;
    [Test]
    procedure BackupRetainsFolderWhenZipNamesDiffer;
    [Test]
    procedure BackupRemovesFolderWhenZipNamesMatchIgnoringCase;
    [Test]
    procedure RestoreCleansExtractionOnCloseAndOpenFailure;
    [Test]
    procedure CompareCleansExtractionOnSuccessAndFailure;
  end;

implementation

uses
  System.IOUtils, System.StrUtils, Winapi.Windows,
  Core.BackupEngine, Core.CompareEngine, Core.DllScanner, Core.Logger,
  Core.Hash, Core.Manifest, Core.ProcessRunner, Core.SystemUtils;

const
  TestKey = 'HKCU\Software\DelphiBackupRestoreTests\Product';
  TestFullKey = 'HKEY_CURRENT_USER\Software\DelphiBackupRestoreTests\Product';
  RegHeader = 'Windows Registry Editor Version 5.00' + sLineBreak + sLineBreak;
  TempMessage = 'Exportações de segurança do registro: ';

constructor TRestoreTestContext.TTestRunner.Create;
begin
  inherited;
  Calls := TStringList.Create;
  RegistryQueries := TStringList.Create;
  TreeDirs := TStringList.Create;
  TreeFiles := TStringList.Create;
end;

destructor TRestoreTestContext.TTestRunner.Destroy;
begin
  TreeFiles.Free;
  TreeDirs.Free;
  RegistryQueries.Free;
  Calls.Free;
  inherited;
end;

function TRestoreTestContext.TTestRunner.Run(const AExe, AArgs,
  AWorkDir: string; out AOutput: string): Cardinal;
begin
  Assert.AreEqual('tar.exe', AExe);
  Assert.IsTrue(StartsText('-t -f ', AArgs));
  ZipListArgs := AArgs;
  AOutput := UpperCase(ZipFolderName) + '/' + sLineBreak +
    UpperCase(ZipFolderName) + '/MANIFEST.JSON' + sLineBreak;
  if ZipWrongName then
    AOutput := AOutput + ZipFolderName + '/wrong.log' + sLineBreak
  else
    AOutput := AOutput + ZipFolderName + '/backup.log' + sLineBreak;
  if ZipDiagnostic then
    AOutput := AOutput + 'tar: simulação de diagnóstico' + sLineBreak;
  Result := 0;
end;

function TRestoreTestContext.TTestRunner.CopyTree(const ASource, ADest: string;
  AMirror: Boolean; AExcludeDirs, AExcludeFiles: TStrings): Boolean;
begin
  Calls.Add('tree');
  TreeMirror := AMirror;
  TreeDirs.Assign(AExcludeDirs);
  TreeFiles.Assign(AExcludeFiles);
  Result := not FailTrees;
end;

function TRestoreTestContext.TTestRunner.CopyFile(const ASourceFile,
  ADestDir: string): Boolean;
begin
  Calls.Add('file');
  Result := True;
end;

function TRestoreTestContext.TTestRunner.RegExport(const AKey,
  AFileName: string): Boolean;
begin
  Assert.AreEqual(TestKey, AKey);
  Calls.Add('export');
  TFile.WriteAllText(AFileName, RegistryValue, TEncoding.Unicode);
  Result := True;
end;

function TRestoreTestContext.TTestRunner.RegImport(const AFileName: string;
  AHklm32: Boolean): Boolean;
begin
  Assert.IsFalse(AHklm32);
  if StartsText('before_', ExtractFileName(AFileName)) then
  begin
    Calls.Add('rollback');
    Assert.AreEqual('', RegistryValue,
      'A chave parcial deve ser removida primeiro.');
    RegistryValue := TFile.ReadAllText(AFileName, TEncoding.Unicode);
    Exit(True);
  end;
  Calls.Add('import');
  ImportedText := TFile.ReadAllText(AFileName, TEncoding.Unicode);
  RegistryValue := 'partial';
  if ImportFailure = 2 then
    raise EDelphiBackupError.Create('Falha simulada em reg import.');
  Result := ImportFailure = 0;
end;

function TRestoreTestContext.TTestRunner.RegDelete(const AKey: string): Boolean;
begin
  Assert.AreEqual(TestKey, AKey);
  Calls.Add('delete');
  RegistryValue := '';
  Result := True;
end;

function TRestoreTestContext.TTestRunner.RegKeyExists
  (const AKey: string): Boolean;
begin
  RegistryQueries.Add(AKey);
  Result := SameText(AKey, TestKey) and (RegistryValue <> '');
end;

function TRestoreTestContext.TTestRunner.ZipFolder(const AFolder,
  AZipFile: string): Boolean;
begin
  ZipFolderName := ExtractFileName(AFolder);
  TFile.WriteAllText(AZipFile, 'zip simulado');
  Result := True;
end;

function TRestoreTestContext.TTestRunner.UnzipTo(const AZipFile,
  ADestFolder: string): Boolean;
begin
  Extracted := ADestFolder;
  ForceDirectories(TPath.Combine(Extracted, 'backup'));
  if ZipManifest <> '' then
    TFile.Copy(ZipManifest, TPath.Combine(Extracted,
      'backup\' + BACKUP_MANIFEST_FILE));
  Result := not UnzipFails;
end;

procedure TRestoreTestContext.TTestRestoreEngine.CheckHostRequirements;
begin
  { The simulated restore uses only a fake runner and temporary files. }
end;

procedure TRestoreTestContext.TTestRestoreEngine.MergeUserPath;
begin
  Inc(MergeCalls);
end;

function TRestoreTestContext.TTestRestoreEngine.UserDocumentsDirectory: string;
begin
  Result := DocumentsPath;
end;

procedure TRestoreTestContext.Setup;
var
  V: TManifestVersion;
begin
  FTemp := CreateTempDirectory('dbr_safety_tests_');
  FBackup := TPath.Combine(FTemp, 'backup');
  ForceDirectories(FBackup);
  FTemps := TStringList.Create;
  FMessages := TStringList.Create;
  FLogger := CreateLogger;
  FLogger.AddSink(procedure(ALevel: TLogLevel; const AMessage: string)
    begin
      FMessages.Add(AMessage);
      if StartsText(TempMessage, AMessage) then
        FTemps.Add(Copy(AMessage, Length(TempMessage) + 1, MaxInt));
    end);
  FFake := TTestRunner.Create;
  FRunner := FFake;
  FEngine := TTestRestoreEngine.Create(FLogger, FRunner);
  FEngine.DocumentsPath := TPath.Combine(FTemp, 'documents');
  FInstalled := TDelphiVersionList.Create(True);
  FVersion := TDelphiVersion.Create;
  FVersion.Era := deEmbarcadero;
  FVersion.BdsVersion := '22.0';
  FVersion.RootDir := TPath.Combine(FTemp, 'ide\installation');
  FVersion.UserDir := TPath.Combine(FTemp, 'ide\settings');
  ForceDirectories(TPath.Combine(FVersion.RootDir, 'bin'));
  ForceDirectories(FVersion.UserDir);
  TFile.WriteAllText(TPath.Combine(FVersion.RootDir, 'bin\bds.exe'), 'mock');
  FInstalled.Add(FVersion);
  FManifest := TManifest.Create;
  FManifest.HasExclusions := True;
  V := TManifestVersion.Create;
  V.BdsVersion := FVersion.BdsVersion;
  V.ProductName := 'Delphi 11 Alexandria';
  FManifest.Versions.Add(V);
  FOptions := Default (TRestoreOptions);
  FOptions.Categories := AllCategories;
end;

procedure TRestoreTestContext.TearDown;
var
  P: string;
begin
  FEngine.Free;
  FManifest.Free;
  FInstalled.Free;
  FRunner := nil;
  FLogger := nil;
  try
    for P in FTemps do
      Assert.IsTrue(DeleteTree(P), P);
    Assert.IsTrue(DeleteTree(FTemp), FTemp);
  finally
    FMessages.Free;
    FTemps.Free;
  end;
end;

function TRestoreTestContext.AddItem(const AId: string; AKind: TItemKind;
ACategory: TItemCategory; const ADest: string): TBackupItem;
var
  M: TManifestItem;
begin
  M := TManifestItem.Create;
  FManifest.Items.Add(M);
  M.Item := TBackupItem.Create;
  Result := M.Item;
  Result.Id := AId;
  Result.Kind := AKind;
  Result.Category := ACategory;
  Result.SourcePath := ADest;
end;

function TRestoreTestContext.AddRegistryFixture(const AExtraSection
  : string): string;
begin
  AddItem('r001', ikRegistry, icExtra, TestKey);
  ForceDirectories(TPath.Combine(FBackup, BACKUP_REGISTRY_DIR));
  Result := TPath.Combine(FBackup, BACKUP_REGISTRY_DIR + '\r001.reg');
  TFile.WriteAllText(Result, RegHeader + '[' + TestFullKey + ']' + sLineBreak +
    '"Name"="Value"' + sLineBreak + AExtraSection, TEncoding.Unicode);
end;

procedure TRestoreTestContext.OpenBackup;
begin
  SaveManifest(FManifest, TPath.Combine(FBackup, BACKUP_MANIFEST_FILE));
  FEngine.Open(FBackup);
end;

procedure TRestoreTestContext.Execute;
begin
  FEngine.Execute(FOptions, FInstalled, nil);
end;

procedure TTestRestoreSafety.PrecheckAggregatesResolvedDestinationViolations;
var
  BadIds: TArray<string>;
  Id: string;
begin
  FManifest.SourceUserProfile := 'Q:\previous-profile';
  AddItem('f001', ikFolder, icExtra, 'relative');
  AddItem('f002', ikFolder, icExtra, FBackup + '\child');
  AddItem('f003', ikFolder, icExtra, TPath.Combine(FTemp, 'ide'));
  AddItem('f004', ikFolder, icIdeConfig, FVersion.UserDir).Versions.Add('99.0');
  AddItem('f005', ikFolder, icExtra, FManifest.SourceUserProfile);
  AddItem('r001', ikRegistry, icExtra, 'HKLM\SYSTEM\CurrentControlSet\Example');
  AddItem('r002', ikRegistry, icExtra, 'HKCU\Software\Microsoft\Example');
  AddItem('r003', ikRegistry, icExtra, 'HKCU\Software');
  AddItem('r004', ikRegistry, icExtra, 'HKCR\Software\Delphi\Example');
  AddItem('r005', ikRegistry, icExtra,
    'HKLM\SOFTWARE\WOW6432Node\Borland\Delphi');
  AddItem('f006', ikFolder, icIdeConfig, FVersion.UserDir);
  AddItem('f007', ikFolder, icComponents, 'out-of-scope').Versions.Add('99.0');
  AddItem('f008', ikFolder, icComponents, TPath.GetPathRoot(FTemp));
  OpenBackup;
  BadIds := TArray<string>.Create('f001', 'f002', 'f003', 'f005', 'r001',
    'r002', 'r003', 'r004', 'r005', 'f006', 'f008');
  try
    FEngine.Precheck(FOptions, FInstalled);
    Assert.Fail('O pré-check deveria recusar os destinos.');
  except
    on E: EPrecheckError do
    begin
      for Id in BadIds do
        Assert.IsTrue(Pos('[' + Id + ']', E.Message) > 0, E.Message);
      Assert.IsTrue(Pos(GetUserProfileDir, E.Message) > 0, E.Message);
      Assert.IsFalse(Pos('[f004]', E.Message) > 0, E.Message);
      Assert.IsFalse(Pos('[f007]', E.Message) > 0, E.Message);
    end;
  end;
  Assert.AreEqual(0, FFake.Calls.Count);
  Assert.AreEqual(0, FTemps.Count);
end;

procedure TTestRestoreSafety.
  PrecheckAcceptsListedIdeFolderAndAllowedRegistryKeys;
begin
  AddItem('f001', ikFolder, icIdeConfig, FVersion.UserDir).Versions.Add('22.0');
  AddItem('r001', ikRegistry, icIdeConfig,
    'HKCU\Software\Embarcadero\BDS\22.0');
  AddItem('r002', ikRegistry, icIdeConfig,
    'HKLM\Software\Embarcadero\BDS\22.0');
  AddItem('r003', ikRegistry, icExperts, 'HKCU\Software\GExperts');
  AddItem('r004', ikRegistry, icExperts, 'HKCU\Software\CnPack\Settings');
  AddItem('r005', ikRegistry, icExperts, 'HKCU\Software\Scooter Software');
  AddItem('r006', ikRegistry, icExtra, TestKey);
  OpenBackup;
  FEngine.Precheck(FOptions, FInstalled);
  Assert.AreEqual(0, FFake.Calls.Count);
end;

procedure TTestRestoreSafety.
  PrecheckRejectsDestinationInExtractionOutsideBackupRoot;
begin
  FEngine.Open(PrepareZip);
  AddItem('f001', ikFolder, icExtra, TPath.Combine(FFake.Extracted, 'sibling'));
  FEngine.Manifest.Items.Add(FManifest.Items.Extract(FManifest.Items[0]));
  Assert.WillRaise(procedure
    begin
      FEngine.Precheck(FOptions, FInstalled);
    end, EPrecheckError);
end;

procedure TTestRestoreSafety.RegistryRejectsSectionsOutsideItem;
var
  Header: string;
begin
  for Header in TArray<string>.Create('[' + TestFullKey + 'Other]',
    '[-HKEY_LOCAL_MACHINE\SOFTWARE\Unrelated]', '[HKCU\Software\Unrelated]') do
  begin
    FManifest.Items.Clear;
    AddRegistryFixture('  ' + Header + sLineBreak);
    OpenBackup;
    Assert.WillRaise(Execute, EDelphiBackupError);
    Assert.AreEqual('', FFake.Calls.Text,
      'Nenhuma chave pode ser excluída ou importada.');
  end;
end;

procedure TTestRestoreSafety.CheckRollback(AFailure: Integer;
AKeyExists: Boolean);
begin
  AddRegistryFixture('[-' + TestFullKey + '\Obsolete]' + sLineBreak);
  if AKeyExists then
    FFake.RegistryValue := 'original';
  FFake.ImportFailure := AFailure;
  OpenBackup;
  Assert.WillRaise(Execute, EDelphiBackupError);
  if AKeyExists then
  begin
    Assert.AreEqual('export,delete,import,delete,rollback',
      FFake.Calls.CommaText);
    Assert.AreEqual('original', FFake.RegistryValue);
  end
  else
  begin
    Assert.AreEqual('delete,import,delete', FFake.Calls.CommaText);
    Assert.AreEqual('', FFake.RegistryValue);
  end;
end;

procedure TTestRestoreSafety.RegistryRestoresSnapshotWhenImportFails;
begin
  CheckRollback(1, True);
end;

procedure TTestRestoreSafety.RegistryRestoresSnapshotWhenImportRaises;
begin
  CheckRollback(2, True);
end;

procedure TTestRestoreSafety.RegistryRemovesPartialKeyWhenNoSnapshotExists;
begin
  CheckRollback(1, False);
end;

procedure TTestRestoreSafety.InstallerKeysAreSkipped;
var
  M: TManifestItem;
begin
  AddItem('r001', ikRegistry, icIdeConfig,
    'HKLM\SOFTWARE\Embarcadero\BDS\22.0');
  AddItem('r002', ikRegistry, icIdeConfig,
    'HKLM\SOFTWARE\WOW6432Node\Borland\Delphi\7.0');
  AddItem('r003', ikRegistry, icIdeConfig,
    'HKLM\SOFTWARE\CodeGear\BDS\6.0\Child');
  OpenBackup;
  Execute;
  Assert.AreEqual('', FFake.Calls.Text);
  for M in FManifest.Items do
    Assert.IsTrue(FMessages.IndexOf('Chave do instalador ignorada: ' +
      M.Item.SourcePath) >= 0, M.Item.SourcePath);
end;

procedure TTestRestoreSafety.CompareSkipsInstallerKeys;
var
  Engine: TCompareEngine;
  Options: TCompareOptions;
  Diff: TCompareResult;
begin
  AddItem('r001', ikRegistry, icIdeConfig,
    'hklm\software\Embarcadero\BDS\22.0');
  AddItem('r002', ikRegistry, icIdeConfig,
    'HKLM\SOFTWARE\WOW6432Node\Borland\Delphi\7.0');
  AddItem('r003', ikRegistry, icIdeConfig,
    'HKCU\Software\Embarcadero\BDS\22.0');
  OpenBackup;
  Engine := TCompareEngine.Create(FLogger, FRunner);
  try
    Options := Default (TCompareOptions);
    Options.Source := FBackup;
    Diff := Engine.Execute(Options, FInstalled, nil);
    try
      Assert.AreEqual('HKCU\Software\Embarcadero\BDS\22.0',
        FFake.RegistryQueries.CommaText);
      Assert.AreEqual(1, Diff.Entries.Count);
      Assert.AreEqual('r003', Diff.Entries[0].ItemId);
      Assert.AreEqual(dkRemoved, Diff.Entries[0].Kind);
    finally
      Diff.Free;
    end;
  finally
    Engine.Free;
  end;
end;

procedure TTestRestoreSafety.CompareListsRegistryValueChanges;
var
  Engine: TCompareEngine;
  Options: TCompareOptions;
  Diff: TCompareResult;
  BackupFile, Detail, Section: string;
begin
  Section := '[' + TestFullKey + '\Library\Win32]' + sLineBreak;
  BackupFile := AddRegistryFixture(Section + '@="padrão anterior"' + sLineBreak
    + '"Removed"="old"' + sLineBreak + '"Name=\"Escaped\""=hex:01,\' +
    sLineBreak + '  02' + sLineBreak + '"Same"=hex:aa,\' + sLineBreak + '  bb' +
    sLineBreak + '[' + TestFullKey + '\MRU]' + sLineBreak + '"Ignored"="old"' +
    sLineBreak);
  FManifest.Items[0].Hash := Sha256Hex(NormalizeRegFile(BackupFile));
  FFake.RegistryValue := RegHeader + '[' + TestFullKey + ']' + sLineBreak +
    '"NAME"="Value"' + sLineBreak + LowerCase(Section) + '@="novo padrão"' +
    sLineBreak + '"Added"="new"' + sLineBreak + '"Name=\"Escaped\""=hex:01,03' +
    sLineBreak + '"Same"=hex:AA,BB' + sLineBreak + '[' + TestFullKey + '\MRU]' +
    sLineBreak + '"Ignored"="new"' + sLineBreak;
  OpenBackup;
  Engine := TCompareEngine.Create(FLogger, FRunner);
  try
    Options := Default (TCompareOptions);
    Options.Source := FBackup;
    Diff := Engine.Execute(Options, FInstalled, nil);
    try
      Assert.AreEqual(1, Diff.Entries.Count);
      Assert.AreEqual(TestKey, Diff.Entries[0].Path);
      Assert.AreEqual(dkChanged, Diff.Entries[0].Kind);
      Detail := FormatCompareEntry(Diff.Entries[0]);
      Assert.IsTrue(StartsText('~ ' + TestKey + '  (Registro diferente)' +
        sLineBreak, Detail), Detail);
      Assert.IsTrue(ContainsText(Detail,
        'Library\Win32\(Padrão): alterado'), Detail);
      Assert.IsTrue(ContainsText(Detail,
        'Library\Win32\Removed: ausente'), Detail);
      Assert.IsTrue(ContainsText(Detail,
        'Library\Win32\Added: adicionado'), Detail);
      Assert.IsTrue(ContainsText(Detail,
        'Library\Win32\Name="Escaped": alterado'), Detail);
      Assert.IsFalse(ContainsText(Detail, '\Same:'), Detail);
      Assert.IsFalse(ContainsText(Detail, 'Ignored'), Detail);
      Assert.IsFalse(ContainsText(Detail, 'Name: '), Detail);
    finally
      Diff.Free;
    end;
  finally
    Engine.Free;
  end;
end;

procedure TTestRestoreSafety.CompareLimitsRegistryDetails;
var
  Engine: TCompareEngine;
  Options: TCompareOptions;
  Diff: TCompareResult;
  Lines: TStringList;
  I: Integer;
begin
  FManifest.Items.Clear;
  AddRegistryFixture;
  FFake.RegistryValue := RegHeader + '[' + TestFullKey + ']' + sLineBreak +
    '"Name"="Value"' + sLineBreak;
  for I := 1 to 23 do
    FFake.RegistryValue := FFake.RegistryValue +
      Format('"Valor%.2d"=dword:00000001', [I]) + sLineBreak;
  OpenBackup;
  Engine := TCompareEngine.Create(FLogger, FRunner);
  Lines := TStringList.Create;
  try
    Options := Default (TCompareOptions);
    Options.Source := FBackup;
    Diff := Engine.Execute(Options, FInstalled, nil);
    try
      Assert.AreEqual(1, Diff.Entries.Count);
      Lines.Text := Diff.Entries[0].Detail;
      Assert.AreEqual(22, Lines.Count);
      Assert.AreEqual('Valor01: adicionado', Trim(Lines[1]));
      Assert.AreEqual('Valor20: adicionado', Trim(Lines[20]));
      Assert.AreEqual('... mais 3', Trim(Lines[21]));
      Assert.IsTrue(FMessages.IndexOf(TestKey + '\Valor23: adicionado') >= 0);
    finally
      Diff.Free;
    end;
  finally
    Lines.Free;
    Engine.Free;
  end;
end;

procedure TTestRestoreSafety.RegistrySecurityExportsRemainInDocuments;
var
  Base, FirstExport, Leaf, Original: string;
begin
  AddRegistryFixture;
  Original := RegHeader + '[' + TestFullKey + ']' + sLineBreak +
    '"Name"="Original"' + sLineBreak;
  FFake.RegistryValue := Original;
  OpenBackup;
  Execute;
  Base := TPath.Combine(FEngine.DocumentsPath, 'DelphiBackups\seguranca');
  FirstExport := FEngine.SecurityExportDir;
  Leaf := ExtractFileName(FirstExport);
  Assert.AreEqual(Base, ExtractFileDir(FirstExport));
  Assert.IsTrue(StartsText('pre_restore_', Leaf), Leaf);
  Assert.AreEqual(27, Length(Leaf), Leaf);
  Assert.AreEqual('_', string(Leaf[21]));
  Assert.AreEqual(Original, TFile.ReadAllText(TPath.Combine(FirstExport,
    'before_001.reg'), TEncoding.Unicode));
  Assert.AreEqual(1, Length(TDirectory.GetFiles(FirstExport)));
  Assert.AreEqual(FirstExport, FTemps[0]);
  FFake.RegistryValue := Original;
  Execute;
  Assert.AreNotEqual(FirstExport, FEngine.SecurityExportDir);
  Assert.IsTrue(TFile.Exists(TPath.Combine(FirstExport, 'before_001.reg')));
  Assert.IsTrue(TFile.Exists(TPath.Combine(FEngine.SecurityExportDir,
    'before_001.reg')));
end;

procedure TTestRestoreSafety.RestoreUsesRecordedExclusionsAndLegacyCopyOnly;
begin
  AddItem('f001', ikFolder, icExtra, TPath.Combine(FTemp, 'live'));
  ForceDirectories(TPath.Combine(FBackup, 'files\f001'));
  FManifest.ExcludeDirs.Add('private-*');
  FManifest.ExcludeFiles.Add('*.local');
  OpenBackup;
  Execute;
  Assert.IsTrue(FFake.TreeMirror);
  Assert.AreEqual('private-*', FFake.TreeDirs.CommaText);
  Assert.AreEqual('*.local', FFake.TreeFiles.CommaText);
  FManifest.HasExclusions := False;
  OpenBackup;
  Assert.IsFalse(FEngine.Manifest.HasExclusions);
  Execute;
  Assert.IsFalse(FFake.TreeMirror);
  Assert.IsTrue(Pos('sem espelhamento', FMessages.Text) > 0);
end;

procedure TTestRestoreSafety.RobocopyMirrorPreservesExcludedDestinationEntries;
var
  Runner: IProcessRunner;
  Source, Dest, KeptFile, KeptDir, Removed: string;
begin
  Source := TPath.Combine(FTemp, 'source');
  Dest := TPath.Combine(FTemp, 'dest');
  KeptDir := TPath.Combine(Dest, 'private-cache\marker.txt');
  KeptFile := TPath.Combine(Dest, 'keep.local');
  Removed := TPath.Combine(Dest, 'remove.txt');
  ForceDirectories(Source);
  ForceDirectories(ExtractFileDir(KeptDir));
  TFile.WriteAllText(KeptDir, 'keep directory');
  TFile.WriteAllText(KeptFile, 'keep file');
  TFile.WriteAllText(Removed, 'remove file');
  FManifest.ExcludeDirs.Add('private-*');
  FManifest.ExcludeFiles.Add('*.local');
  Runner := CreateProcessRunner(FLogger);
  Assert.IsTrue(Runner.CopyTree(Source, Dest, True, FManifest.ExcludeDirs,
    FManifest.ExcludeFiles));
  Assert.IsTrue(TFile.Exists(KeptDir));
  Assert.IsTrue(TFile.Exists(KeptFile));
  Assert.IsFalse(TFile.Exists(Removed));
end;

procedure TTestRestoreSafety.CompareUsesRecordedExclusions;
var
  Compare: TCompareEngine;
  Options: TCompareOptions;
  Config: TToolConfig;
  Diff: TCompareResult;
  Live: string;
begin
  Live := TPath.Combine(FTemp, 'live');
  ForceDirectories(TPath.Combine(Live, 'skip-dir'));
  TFile.WriteAllText(TPath.Combine(Live, 'skip-dir\file.txt'), 'dir');
  TFile.WriteAllText(TPath.Combine(Live, 'skip.file'), 'file');
  TFile.WriteAllText(TPath.Combine(Live, 'include.txt'), 'unexcluded');
  AddItem('f001', ikFolder, icExtra, Live);
  FManifest.ExcludeDirs.Add('skip-*');
  FManifest.ExcludeFiles.Add('*.file');
  OpenBackup;
  Options := Default (TCompareOptions);
  Options.Source := FBackup;
  Config := TToolConfig.Create;
  Compare := TCompareEngine.Create(FLogger, FRunner);
  try
    Config.ExcludeFiles.Add('include.txt');
    Diff := Compare.Execute(Options, FInstalled, Config);
    try
      Assert.AreEqual(1, Diff.Entries.Count);
      Assert.AreEqual('include.txt', Diff.Entries[0].Path);
    finally
      Diff.Free;
    end;
  finally
    Compare.Free;
    Config.Free;
  end;
end;

procedure TTestRestoreSafety.DllKeepsExistingFileWithUnreadableVersion;
var
  Dest, Source: string;
begin
  Dest := TPath.Combine(FTemp, 'live.dll');
  Source := TPath.Combine(FBackup, 'dlls\d001\live.dll');
  ForceDirectories(ExtractFileDir(Source));
  TFile.WriteAllText(Source, 'backup version unreadable');
  TFile.WriteAllText(Dest, 'existing version unreadable');
  AddItem('d001', ikDll, icSystemDll, Dest).FileVersion := '99.0.0.0';
  OpenBackup;
  Execute;
  Assert.AreEqual('existing version unreadable', TFile.ReadAllText(Dest));
  Assert.IsTrue(Pos('versão de arquivo ilegível', FMessages.Text) > 0);
end;

procedure WriteVersionedPe(const AFileName: string; AMachine, AMajor: Word);
const
  Nt = $80;
  Optional = Nt + 24;
  RawResource = $200;
  ResourceRva = $1000;
  Version = RawResource + $60;
  VersionName = 'VS_VERSION_INFO';
var
  Bytes: TBytes;
  Section, NumberOfDirs, I, FixedInfo: Integer;

  procedure PutWord(AOffset: Integer; AValue: Word);
  begin
    Move(AValue, Bytes[AOffset], SizeOf(AValue));
  end;

  procedure PutDWord(AOffset: Integer; AValue: Cardinal);
  begin
    Move(AValue, Bytes[AOffset], SizeOf(AValue));
  end;

begin
  SetLength(Bytes, $400);
  PutWord(0, $5A4D);
  PutDWord($3C, Nt);
  PutDWord(Nt, $4550);
  PutWord(Nt + 4, AMachine);
  PutWord(Nt + 6, 1);
  if AMachine = $8664 then
  begin
    Section := Optional + 240;
    NumberOfDirs := Optional + 108;
    PutWord(Optional, $20B);
  end
  else
  begin
    Section := Optional + 224;
    NumberOfDirs := Optional + 92;
    PutWord(Optional, $10B);
  end;
  PutWord(Nt + 20, Section - Optional);
  PutWord(Nt + 22, $2002);
  PutDWord(Optional + 32, $1000);
  PutDWord(Optional + 36, $200);
  PutDWord(Optional + 56, $2000);
  PutDWord(Optional + 60, $200);
  PutDWord(NumberOfDirs, 16);
  PutDWord(NumberOfDirs + 20, ResourceRva);
  PutDWord(NumberOfDirs + 24, $200);
  PutDWord(Section, $7273722E); // .rsr
  Bytes[Section + 4] := Ord('c');
  PutDWord(Section + 8, $200);
  PutDWord(Section + 12, ResourceRva);
  PutDWord(Section + 16, $200);
  PutDWord(Section + 20, RawResource);
  PutDWord(Section + 36, $40000040);
  PutWord(RawResource + 14, 1); // type (RT_VERSION)
  PutDWord(RawResource + 16, 16);
  PutDWord(RawResource + 20, $80000018);
  PutWord(RawResource + 24 + 14, 1); // resource name (ID 1)
  PutDWord(RawResource + 40, 1);
  PutDWord(RawResource + 44, $80000030);
  PutWord(RawResource + 48 + 14, 1); // language
  PutDWord(RawResource + 64, $409);
  PutDWord(RawResource + 68, $48);
  PutDWord(RawResource + 72, ResourceRva + $60);
  PutDWord(RawResource + 76, 92);
  PutWord(Version, 92);
  PutWord(Version + 2, 52);
  for I := 1 to Length(VersionName) do
    PutWord(Version + 4 + I * 2, Ord(VersionName[I]));
  FixedInfo := Version + 40;
  PutDWord(FixedInfo, $FEEF04BD);
  PutDWord(FixedInfo + 4, $10000);
  PutDWord(FixedInfo + 8, Cardinal(AMajor) shl 16);
  TFile.WriteAllBytes(AFileName, Bytes);
end;

procedure TTestRestoreSafety.DllRequiresMatchingPeMachine;
var
  Dest, Source: string;
begin
  Dest := TPath.Combine(FTemp, 'live.dll');
  Source := TPath.Combine(FBackup, 'dlls\d001\live.dll');
  ForceDirectories(ExtractFileDir(Source));
  WriteVersionedPe(Dest, $014C, 1);
  WriteVersionedPe(Source, $8664, 2);
  Assert.AreEqual('1.0.0.0', GetFileVersionText(Dest));
  Assert.AreEqual('2.0.0.0', GetFileVersionText(Source));
  Assert.AreEqual<Integer>($014C, ReadPeMachine(Dest));
  Assert.AreEqual<Integer>($8664, ReadPeMachine(Source));
  AddItem('d001', ikDll, icSystemDll, Dest);
  OpenBackup;
  Execute;
  Assert.AreEqual('1.0.0.0', GetFileVersionText(Dest));
  Assert.IsTrue(Pos('arquitetura PE incompatível', FMessages.Text) > 0);
  WriteVersionedPe(Source, $014C, 2);
  Execute;
  Assert.AreEqual('2.0.0.0', GetFileVersionText(Dest));
end;

procedure TTestRestoreSafety.CheckZipVerification(AWrongName: Boolean);
var
  Engine: TBackupEngine;
  Options: TBackupOptions;
  Items: TBackupItemList;
  Config: TToolConfig;
  Zip, Folder: string;
  Manifest: TManifest;
begin
  Options := Default (TBackupOptions);
  Options.Destination := FTemp;
  Options.CreateZip := True;
  Options.Categories := AllCategories;
  FFake.ZipWrongName := AWrongName;
  Engine := TBackupEngine.Create(FLogger, FRunner);
  Items := TBackupItemList.Create(True);
  Config := TToolConfig.Create;
  try
    Config.ExcludeFiles.Add('*.local');
    Zip := Engine.Execute(Options, FInstalled, Items, Config, nil);
    Folder := ChangeFileExt(Zip, '');
    Assert.IsTrue(TFile.Exists(Zip));
    Assert.AreEqual(AWrongName, DirectoryExists(Folder));
    if AWrongName then
    begin
      Manifest := LoadManifest(TPath.Combine(Folder, BACKUP_MANIFEST_FILE));
      try
        Assert.IsTrue(Manifest.HasExclusions);
        Assert.AreEqual(Config.ExcludeDirs.Text, Manifest.ExcludeDirs.Text);
        Assert.AreEqual(Config.ExcludeFiles.Text, Manifest.ExcludeFiles.Text);
      finally
        Manifest.Free;
      end;
    end;
  finally
    Config.Free;
    Items.Free;
    Engine.Free;
  end;
end;

procedure TTestRestoreSafety.BackupRetainsFolderWhenZipNamesDiffer;
begin
  CheckZipVerification(True);
end;

procedure TTestRestoreSafety.BackupRemovesFolderWhenZipNamesMatchIgnoringCase;
begin
  CheckZipVerification(False);
end;

function TRestoreTestContext.PrepareZip: string;
begin
  FFake.ZipManifest := TPath.Combine(FBackup, BACKUP_MANIFEST_FILE);
  SaveManifest(FManifest, FFake.ZipManifest);
  Result := TPath.Combine(FTemp, 'backup.zip');
  TFile.WriteAllText(Result, '');
end;

procedure TTestRestoreSafety.RestoreCleansExtractionOnCloseAndOpenFailure;
var
  Zip, Extracted: string;
begin
  Zip := PrepareZip;
  FEngine.Open(Zip);
  Extracted := FFake.Extracted;
  Assert.IsTrue(DirectoryExists(Extracted));
  FEngine.Open(Zip);
  Assert.IsFalse(DirectoryExists(Extracted));
  Extracted := FFake.Extracted;
  FFake.UnzipFails := True;
  Assert.WillRaise(procedure
    begin
      FEngine.Open(Zip);
    end, EDelphiBackupError);
  Assert.IsFalse(DirectoryExists(FFake.Extracted));
  Assert.IsTrue(DirectoryExists(Extracted));
  FreeAndNil(FEngine);
  Assert.IsFalse(DirectoryExists(Extracted));
end;

procedure TTestRestoreSafety.CompareCleansExtractionOnSuccessAndFailure;
var
  Engine: TCompareEngine;
  Options: TCompareOptions;
  Diff: TCompareResult;
begin
  Options := Default (TCompareOptions);
  Options.Source := PrepareZip;
  Engine := TCompareEngine.Create(FLogger, FRunner);
  try
    Diff := Engine.Execute(Options, FInstalled, nil);
    Diff.Free;
    Assert.IsFalse(DirectoryExists(FFake.Extracted));
    FFake.UnzipFails := True;
    Assert.WillRaise(procedure
      begin
        Engine.Execute(Options, FInstalled, nil).Free;
      end, EDelphiBackupError);
    Assert.IsFalse(DirectoryExists(FFake.Extracted));
  finally
    Engine.Free;
  end;
end;

initialization

TDUnitX.RegisterTestFixture(TTestRestoreSafety);

end.
