unit Tests.Core.Safety;

{ Safety rules that keep a backup from copying system folders (regression for the
  "whole Program Files copied" bug), metadata-only scanning with long paths and
  excludes, size estimate / free space, and the PE import reader.

  Lexical tests use fake paths that do not need to exist. Tests that touch the disk
  only use their own folder under %TEMP%, removed in TearDown, so the suite behaves
  the same on any machine and on the CI runner. }

interface

uses
  System.SysUtils, System.Classes,
  DUnitX.TestFramework,
  Core.Types;

type

  [TestFixture]
  TTestCoreSafety = class
  private
    FTemp: string;
    FVersions: TDelphiVersionList;
    procedure MakeFile(const AFileName: string; ASize: Integer);
    procedure MakeDir(const ADir: string);
    function LongDir: string;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;
    [Test]
    procedure TestSystemFoldersAreContainers;
    [Test]
    procedure TestComponentRootStopsBeforeIdeInstall;
    [Test]
    procedure TestComponentRootNeverReturnsProgramFiles;
    [Test]
    procedure TestComponentRootRejectsUnsafeFolders;
    [Test]
    procedure TestComponentRootStopsAtVcsRoot;
    [Test]
    procedure TestScanItemFilesLongPathsAndExcludes;
    [Test]
    procedure TestEstimateItemSizeAndFreeSpace;
    [Test]
    procedure TestItemInScope;
    [Test]
    procedure TestReadPeImports;
  end;

implementation

uses
  Winapi.Windows, System.IOUtils,
  Core.SystemUtils, Core.PathDiscovery, Core.Manifest, Core.BackupEngine,
  Core.DllScanner;

const
  FAKE_ROOT = 'C:\FakeVendor';
  FAKE_IDE = 'C:\FakeVendor\Studio\22.0\';

function LongPath(const APath: string): string;
begin
  if Copy(APath, 1, 4) = '\\?\' then
    Result := APath
  else
    Result := '\\?\' + APath;
end;

procedure RemoveTree(const ADir: string);
var
  Find: TWin32FindData;
  H: THandle;
  Base, Name: string;
begin
  Base := IncludeTrailingPathDelimiter(LongPath(ADir));
  H := FindFirstFile(PChar(Base + '*'), Find);
  if H <> INVALID_HANDLE_VALUE then
    try
      repeat
        Name := Find.cFileName;
        if (Name = '.') or (Name = '..') then
          Continue;
        if (Find.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
          RemoveTree(Base + Name)
        else
          Winapi.Windows.DeleteFile(PChar(Base + Name));
      until not FindNextFile(H, Find);
    finally
      Winapi.Windows.FindClose(H);
    end;
  Winapi.Windows.RemoveDirectory(PChar(ExcludeTrailingPathDelimiter(Base)));
end;

{ TTestCoreSafety }

procedure TTestCoreSafety.Setup;
var
  V: TDelphiVersion;
begin
  FTemp := IncludeTrailingPathDelimiter(TPath.GetTempPath) + 'dbr-tests-' +
    IntToStr(GetCurrentProcessId) + '-' + IntToStr(GetTickCount);
  MakeDir(FTemp);
  FVersions := TDelphiVersionList.Create(True);
  V := TDelphiVersion.Create;
  V.BdsVersion := '22.0';
  V.RootDir := FAKE_IDE;
  V.CommonDir := 'C:\FakePublic\Studio\22.0';
  V.UserDir := 'C:\FakeDocs\Studio\22.0';
  V.AppDataDir := 'C:\FakeAppData\BDS\22.0';
  FVersions.Add(V);
end;

procedure TTestCoreSafety.TearDown;
begin
  FVersions.Free;
  RemoveTree(FTemp);
end;

procedure TTestCoreSafety.MakeDir(const ADir: string);
var
  Parts: TStringList;
  Current: string;
  I: Integer;
begin
  { segment by segment with the \\?\ prefix, so paths > MAX_PATH work }
  Parts := TStringList.Create;
  try
    Parts.StrictDelimiter := True;
    Parts.Delimiter := '\';
    Parts.DelimitedText := ExcludeTrailingPathDelimiter(ADir);
    Current := Parts[0];
    for I := 1 to Parts.Count - 1 do
    begin
      Current := Current + '\' + Parts[I];
      Winapi.Windows.CreateDirectory(PChar(LongPath(Current)), nil);
    end;
  finally
    Parts.Free;
  end;
end;

procedure TTestCoreSafety.MakeFile(const AFileName: string; ASize: Integer);
var
  H: THandle;
  Buffer: TBytes;
  Written: DWORD;
begin
  MakeDir(ExtractFileDir(AFileName));
  H := CreateFile(PChar(LongPath(AFileName)), GENERIC_WRITE, 0, nil,
    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  Assert.IsTrue(H <> INVALID_HANDLE_VALUE, 'could not create ' + AFileName);
  try
    SetLength(Buffer, ASize);
    if ASize > 0 then
      FillChar(Buffer[0], ASize, Ord('x'));
    if ASize > 0 then
      WriteFile(H, Buffer[0], ASize, Written, nil);
  finally
    CloseHandle(H);
  end;
end;

function TTestCoreSafety.LongDir: string;
var
  I: Integer;
begin
  { > 300 characters below FTemp }
  Result := FTemp + '\lib';
  for I := 1 to 12 do
    Result := Result + '\nivel_de_pasta_bem_comprido_' + IntToStr(I);
end;

procedure TTestCoreSafety.TestSystemFoldersAreContainers;
var
  Safety: TPathSafety;
  S: string;
begin
  Safety := TPathSafety.Create(nil);
  try
    Assert.IsTrue(Safety.IsContainer('C:\'), 'drive root');
    Assert.IsTrue(Safety.IsContainer(GetEnvironmentVariable('SystemRoot')),
      'Windows');
    Assert.IsTrue(Safety.IsContainer(GetUserProfileDir), 'user profile');
    S := GetEnvironmentVariable('ProgramW6432');
    if S <> '' then
      Assert.IsTrue(Safety.IsContainer(S), '64-bit Program Files: ' + S);
    S := GetEnvironmentVariable('ProgramFiles(x86)');
    if S <> '' then
      Assert.IsTrue(Safety.IsContainer(S), 'Program Files (x86): ' + S);
    Assert.IsTrue(Safety.IsForbidden(GetEnvironmentVariable('SystemRoot') +
      '\System32'), 'inside Windows is forbidden');
    Assert.IsFalse(Safety.IsContainer(FAKE_ROOT + '\Componentes'));
  finally
    Safety.Free;
  end;
end;

procedure TTestCoreSafety.TestComponentRootStopsBeforeIdeInstall;
var
  Safety: TPathSafety;
begin
  { FAKE_ROOT holds the IDE install, so the root must stop one level below it }
  Safety := TPathSafety.Create(FVersions);
  try
    Assert.AreEqual(FAKE_ROOT + '\Componentes',
      Safety.ComponentRoot(FAKE_ROOT +
      '\Componentes\Alexandria\jcl\lib\d28\win32'));
    Assert.IsTrue(Safety.ContainsProtected(FAKE_ROOT));
    Assert.IsTrue(Safety.IsUnsafeRoot(FAKE_ROOT));
  finally
    Safety.Free;
  end;
end;

procedure TTestCoreSafety.TestComponentRootNeverReturnsProgramFiles;
var
  Safety: TPathSafety;
  PF: string;
  Checked: Integer;
begin
  { regression: a 32-bit process sees ProgramFiles = "Program Files (x86)", so the
    64-bit "Program Files" (ProgramW6432) was not a container and got copied whole }
  Safety := TPathSafety.Create(nil);
  try
    Checked := 0;
    PF := GetEnvironmentVariable('ProgramW6432');
    if PF <> '' then
    begin
      Assert.AreEqual(PF + '\SomeVendor',
        Safety.ComponentRoot(PF + '\SomeVendor\Lib\Win32\Release'));
      Inc(Checked);
    end;
    PF := GetEnvironmentVariable('ProgramFiles(x86)');
    if PF <> '' then
    begin
      Assert.AreEqual(PF + '\SomeVendor',
        Safety.ComponentRoot(PF + '\SomeVendor\Lib\Win32\Release'));
      Inc(Checked);
    end;
    if Checked = 0 then
      Assert.Pass('32-bit Windows: no Program Files variants to check');
  finally
    Safety.Free;
  end;
end;

procedure TTestCoreSafety.TestComponentRootRejectsUnsafeFolders;
var
  Safety: TPathSafety;
begin
  Safety := TPathSafety.Create(FVersions);
  try
    Assert.AreEqual('', Safety.ComponentRoot(FAKE_IDE + 'lib\win32\release'),
      'inside the IDE install');
    Assert.AreEqual('', Safety.ComponentRoot('C:\FakeDocs\Studio\22.0\Imports'),
      'inside the IDE user folder');
    Assert.AreEqual('',
      Safety.ComponentRoot(GetEnvironmentVariable('SystemRoot') + '\System32'),
      'inside Windows');
    Assert.AreEqual('', Safety.ComponentRoot('C:\'), 'drive root');
    Assert.AreEqual('', Safety.ComponentRoot(''), 'empty');
  finally
    Safety.Free;
  end;
end;

procedure TTestCoreSafety.TestComponentRootStopsAtVcsRoot;
var
  Safety: TPathSafety;
  Repo: string;
begin
  Repo := FTemp + '\projetos\meu-repo';
  MakeDir(Repo + '\.git');
  MakeDir(Repo + '\src\lib');
  Safety := TPathSafety.Create(nil);
  try
    Assert.AreEqual(Repo, Safety.ComponentRoot(Repo + '\src\lib'));
  finally
    Safety.Free;
  end;
end;

procedure TTestCoreSafety.TestScanItemFilesLongPathsAndExcludes;
var
  M: TManifestItem;
  Config: TToolConfig;
  F: TManifestFile;
  Total: Int64;
  Names: string;
begin
  Assert.IsTrue(Length(LongDir) > 300, 'test path must exceed MAX_PATH');
  MakeFile(FTemp + '\lib\a.txt', 10);
  MakeFile(LongDir + '\deep.txt', 5);
  MakeFile(FTemp + '\lib\AndroidNDK-21\big.bin', 100);
  MakeFile(FTemp + '\lib\__history\old.pas', 100);
  MakeFile(FTemp + '\lib\unit.~pas', 100);
  Config := TToolConfig.Create;
  M := TManifestItem.Create;
  try
    M.Item := TBackupItem.Create;
    M.Item.Kind := ikFolder;
    M.Item.SourcePath := FTemp + '\lib';
    ScanItemFiles(FTemp + '\lib', M, Config.ExcludeDirs, Config.ExcludeFiles);
    Total := 0;
    Names := '';
    for F in M.Files do
    begin
      Inc(Total, F.Size);
      Names := Names + F.RelPath + ';';
      Assert.AreEqual(0, Pos('\\?\', F.RelPath), 'RelPath keeps no prefix');
    end;
    Assert.AreEqual(2, M.Files.Count, 'files: ' + Names);
    Assert.AreEqual(Int64(15), Total);
    Assert.IsTrue(Pos('deep.txt', Names) > 0, 'long path file listed');
  finally
    M.Free;
    Config.Free;
  end;
end;

procedure TTestCoreSafety.TestEstimateItemSizeAndFreeSpace;
var
  It: TBackupItem;
  Config: TToolConfig;
begin
  MakeFile(FTemp + '\est\one.bin', 1000);
  MakeFile(FTemp + '\est\sub\two.bin', 24);
  MakeFile(FTemp + '\est\__history\skip.bin', 5000);
  Config := TToolConfig.Create;
  It := TBackupItem.Create;
  try
    It.Kind := ikFolder;
    It.SourcePath := FTemp + '\est';
    Assert.AreEqual(Int64(1024), EstimateItemSize(It, Config));
    It.Kind := ikFile;
    It.SourcePath := FTemp + '\est\one.bin';
    Assert.AreEqual(Int64(1000), EstimateItemSize(It, Config));
    It.Kind := ikRegistry;
    It.SourcePath := 'HKCU\Software\Whatever';
    Assert.AreEqual(Int64(0), EstimateItemSize(It, Config));
  finally
    It.Free;
    Config.Free;
  end;
  Assert.IsTrue(FreeSpaceAt(FTemp) > 0, 'free space of an existing folder');
  Assert.IsTrue(FreeSpaceAt(FTemp + '\ainda\nao\existe') > 0,
    'walks up to the first existing folder');
end;

procedure TTestCoreSafety.TestItemInScope;
var
  It: TBackupItem;
  Options: TBackupOptions;
  V: TDelphiVersion;
begin
  V := TDelphiVersion.Create;
  V.BdsVersion := '23.0';
  FVersions.Add(V);
  Options.Versions := TextToVersions('22.0');
  Options.Categories := [icComponents];
  It := TBackupItem.Create;
  try
    It.Category := icComponents;
    It.Versions.Add('22.0');
    Assert.IsTrue(ItemInScope(It, Options, FVersions),
      'used by a selected version');
    It.Versions.Clear;
    It.Versions.Add('23.0');
    Assert.IsFalse(ItemInScope(It, Options, FVersions),
      'only used by an unselected version');
    It.Versions.Clear;
    Assert.IsTrue(ItemInScope(It, Options, FVersions), 'global item');
    It.Category := icExperts;
    Assert.IsFalse(ItemInScope(It, Options, FVersions),
      'category not requested');
    It.Category := icComponents;
    It.Selected := False;
    Assert.IsFalse(ItemInScope(It, Options, FVersions), 'not selected');
  finally
    It.Free;
  end;
end;

procedure TTestCoreSafety.TestReadPeImports;
var
  Imports: TStringList;
  I: Integer;
  Found: Boolean;
begin
  Imports := TStringList.Create;
  try
    { the test executable itself is a valid PE that imports kernel32 }
    Assert.IsTrue(ReadPeImports(ParamStr(0), Imports));
    Found := False;
    for I := 0 to Imports.Count - 1 do
      if SameText(Imports[I], 'kernel32.dll') then
        Found := True;
    Assert.IsTrue(Found, 'kernel32.dll in: ' + Imports.CommaText);
    { a non-PE file must return False without raising }
    MakeFile(FTemp + '\not-a-pe.dll', 64);
    Imports.Clear;
    Assert.IsFalse(ReadPeImports(FTemp + '\not-a-pe.dll', Imports));
  finally
    Imports.Free;
  end;
end;

initialization

TDUnitX.RegisterTestFixture(TTestCoreSafety);

end.
