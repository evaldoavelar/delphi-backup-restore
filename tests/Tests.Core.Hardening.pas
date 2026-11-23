unit Tests.Core.Hardening;

interface

uses
  System.SysUtils,
  System.Classes,
  System.StrUtils,
  System.IOUtils,
  System.Win.Registry,
  Winapi.Windows,
  DUnitX.TestFramework,
  Core.Types,
  Core.Hash,
  Core.SystemUtils,
  Core.RestoreEngine;

type

  [TestFixture]
  TTestCoreHardening = class
  public
    [Test]
    procedure Sha256HexMatchesKnownVectors;
    [Test]
    procedure DeleteTreeRejectsRootsAndRelativePaths;
    [Test]
    procedure DeleteTreeRemovesTemporaryFolder;
    [Test]
    procedure WritePathValuePreservesExpandString;
    [Test]
    procedure RealFileSystemPathUsesSysnativeUnderWow64;
    [Test]
    procedure RemapRewritesValueNamesAndKeyHeaders;
    [Test]
    procedure CreateTempDirectoryWorksWithMissingTemp;
  end;

implementation

function QueryWow64Process(AProcess: THandle; out AIsWow64: BOOL): BOOL;
  stdcall; external 'kernel32.dll' name 'IsWow64Process';

const
  TEST_KEY = 'Software\DelphiBackupRestoreTests\Hardening';

  { TTestCoreHardening }

procedure TTestCoreHardening.Sha256HexMatchesKnownVectors;
begin
  Assert.AreEqual
    ('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    Sha256Hex(''));
  Assert.AreEqual
    ('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    Sha256Hex('abc'));
end;

procedure TTestCoreHardening.DeleteTreeRejectsRootsAndRelativePaths;
begin
  Assert.IsFalse(DeleteTree(''), 'vazio');
  Assert.IsFalse(DeleteTree('C:\'), 'raiz de drive');
  Assert.IsFalse(DeleteTree('C:'), 'drive sem barra');
  Assert.IsFalse(DeleteTree('C:Windows'), 'relativo ao drive');
  Assert.IsFalse(DeleteTree('relativo\pasta'), 'relativo');
  Assert.IsFalse(DeleteTree('\Windows'), 'relativo a raiz');
  Assert.IsFalse(DeleteTree('C:\Temp\..\Windows'), 'com ..');
  Assert.IsFalse(DeleteTree('\\servidor\compartilhamento'), 'raiz UNC');
  Assert.IsFalse(DeleteTree('\\servidor\compartilhamento\'),
    'raiz UNC com barra');
end;

procedure TTestCoreHardening.DeleteTreeRemovesTemporaryFolder;
var
  Dir: string;
begin
  Dir := CreateTempDirectory('dbr_hardening_');
  ForceDirectories(TPath.Combine(Dir, 'a\b'));
  TFile.WriteAllText(TPath.Combine(Dir, 'a\b\f.txt'), 'x');
  Assert.IsTrue(DeleteTree(Dir));
  Assert.IsFalse(DirectoryExists(Dir));
end;

procedure TTestCoreHardening.WritePathValuePreservesExpandString;
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_ALL_ACCESS);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    Reg.DeleteKey(TEST_KEY);
    Assert.IsTrue(Reg.OpenKey(TEST_KEY, True));
    try
      { new value with % -> REG_EXPAND_SZ }
      WritePathValue(Reg, '%USERPROFILE%\bin');
      Assert.IsTrue(Reg.GetDataType('Path') = rdExpandString, 'com %');
      { existing REG_EXPAND_SZ is kept even without % }
      WritePathValue(Reg, 'C:\Tools');
      Assert.IsTrue(Reg.GetDataType('Path') = rdExpandString, 'mantém tipo');
      Assert.AreEqual('C:\Tools', Reg.ReadString('Path'));
      { plain REG_SZ without % stays REG_SZ }
      Reg.DeleteValue('Path');
      Reg.WriteString('Path', 'C:\A');
      WritePathValue(Reg, 'C:\B');
      Assert.IsTrue(Reg.GetDataType('Path') = rdString, 'REG_SZ');
    finally
      Reg.CloseKey;
      Reg.DeleteKey(TEST_KEY);
    end;
  finally
    Reg.Free;
  end;
end;

procedure TTestCoreHardening.RealFileSystemPathUsesSysnativeUnderWow64;
var
  IsWow: BOOL;
  Sys32, Other: string;
begin
  Sys32 := TPath.Combine(GetSystem32Dir, 'foo.dll');
  Other := 'C:\Program Files (x86)\Lib\foo.dll';
  Assert.AreEqual(Other, RealFileSystemPath(Other));
  Assert.IsTrue(QueryWow64Process(GetCurrentProcess, IsWow));
  if IsWow then
    Assert.AreEqual(TPath.Combine(ExtractFileDir(GetSystem32Dir),
      'Sysnative\foo.dll'), RealFileSystemPath(Sys32), True)
  else
    Assert.AreEqual(Sys32, RealFileSystemPath(Sys32));
end;

procedure TTestCoreHardening.RemapRewritesValueNamesAndKeyHeaders;
var
  RegIn, RegExpected: string;
begin
  RegIn := 'Windows Registry Editor Version 5.00'#13#10#13#10 +
    '[HKEY_CURRENT_USER\Software\Embarcadero\BDS\22.0\Known Packages]'#13#10 +
    '"C:\\Users\\OldUser\\Documents\\bpl\\Lib.bpl"="Minha Lib"'#13#10 +
    '"D:\\Fixo\\Outra.bpl"="Outra"'#13#10#13#10 +
    '[HKEY_CURRENT_USER\Software\Teste\C:\Users\OldUser\Projetos]'#13#10 +
    '"X"="1"'#13#10;
  RegExpected := 'Windows Registry Editor Version 5.00'#13#10#13#10 +
    '[HKEY_CURRENT_USER\Software\Embarcadero\BDS\22.0\Known Packages]'#13#10 +
    '"C:\\Users\\NewUser\\Documents\\bpl\\Lib.bpl"="Minha Lib"'#13#10 +
    '"D:\\Fixo\\Outra.bpl"="Outra"'#13#10#13#10 +
    '[HKEY_CURRENT_USER\Software\Teste\C:\Users\NewUser\Projetos]'#13#10 +
    '"X"="1"'#13#10;
  Assert.AreEqual(RegExpected, RemapRegFileText(RegIn, 'C:\Users\OldUser',
    'C:\Users\NewUser'));
end;

procedure TTestCoreHardening.CreateTempDirectoryWorksWithMissingTemp;
var
  OldTemp, OldTmp, Dir: string;
begin
  OldTemp := GetEnvironmentVariable('TEMP');
  OldTmp := GetEnvironmentVariable('TMP');
  SetEnvironmentVariable('TEMP', 'Z:\dbr\nao\existe');
  SetEnvironmentVariable('TMP', 'Z:\dbr\nao\existe');
  try
    Dir := CreateTempDirectory('dbr_notemp_');
  finally
    SetEnvironmentVariable('TEMP', PChar(OldTemp));
    SetEnvironmentVariable('TMP', PChar(OldTmp));
  end;
  try
    Assert.IsTrue(DirectoryExists(Dir), Dir);
    Assert.IsFalse(StartsText('Z:\', Dir), Dir);
  finally
    DeleteTree(Dir);
  end;
end;

initialization

TDUnitX.RegisterTestFixture(TTestCoreHardening);

end.
