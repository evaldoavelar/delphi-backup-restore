unit Tests.Core.RestoreEngine;

interface

uses
  System.SysUtils,
  System.Classes,
  DUnitX.TestFramework,
  Core.Types,
  Core.RestoreEngine;

type

  [TestFixture]
  TTestCoreRestoreEngine = class
  public
    [Test]
    procedure TestSortVersionsOldestFirst;
    [Test]
    procedure TestRemapProfilePath;
    [Test]
    procedure TestRemapRegFileTextStringValues;
    [Test]
    procedure TestRemapRegFileTextHex2Utf16RoundTrip;
  end;

implementation

{ TTestCoreRestoreEngine }

procedure TTestCoreRestoreEngine.TestSortVersionsOldestFirst;
var
  Installed: TDelphiVersionList;
  V: TDelphiVersion;
  Input, Output: TArray<string>;
begin
  Installed := TDelphiVersionList.Create(True);
  try
    V := TDelphiVersion.Create;
    V.Era := deEmbarcadero;
    V.Major := 22;
    V.Minor := 0;
    V.BdsVersion := '22.0';
    Installed.Add(V);

    V := TDelphiVersion.Create;
    V.Era := deBorlandDelphi;
    V.Major := 7;
    V.Minor := 0;
    V.BdsVersion := 'D7.0';
    Installed.Add(V);

    V := TDelphiVersion.Create;
    V.Era := deBorlandBDS;
    V.Major := 5;
    V.Minor := 0;
    V.BdsVersion := '5.0';
    Installed.Add(V);

    { Input: 22.0, 99.0 (uninstalled), 5.0, D7.0 }
    SetLength(Input, 4);
    Input[0] := '22.0';
    Input[1] := '99.0';
    Input[2] := '5.0';
    Input[3] := 'D7.0';

    Output := SortVersionsOldestFirst(Input, Installed);

    Assert.AreEqual(4, Length(Output));
    Assert.AreEqual('D7.0', Output[0]);
    Assert.AreEqual('5.0', Output[1]);
    Assert.AreEqual('22.0', Output[2]);
    Assert.AreEqual('99.0', Output[3]); { uninstalled at the end }
  finally
    Installed.Free;
  end;
end;

procedure TTestCoreRestoreEngine.TestRemapProfilePath;
var
  OldProf, NewProf: string;
  Original, Expected, ResultPath: string;
begin
  OldProf := 'C:\Users\OldUser';
  NewProf := 'C:\Users\NewUser';

  Original := 'C:\Users\OldUser\Documents\Embarcadero\Studio\22.0';
  Expected := 'C:\Users\NewUser\Documents\Embarcadero\Studio\22.0';
  ResultPath := RemapProfilePath(Original, OldProf, NewProf);
  Assert.AreEqual(Expected, ResultPath);

  { Case-insensitive }
  Original := 'c:\users\olduser\documents\test';
  Expected := 'C:\Users\NewUser\documents\test';
  ResultPath := RemapProfilePath(Original, OldProf, NewProf);
  Assert.AreEqual(Expected, ResultPath);

  { Non-matching path remains unchanged }
  Original := 'D:\Components\MyLib\Fontes';
  ResultPath := RemapProfilePath(Original, OldProf, NewProf);
  Assert.AreEqual(Original, ResultPath);
end;

procedure TTestCoreRestoreEngine.TestRemapRegFileTextStringValues;
var
  RegIn, RegExpected, RegOut: string;
begin
  RegIn := 'Windows Registry Editor Version 5.00'#13#10 + #13#10 +
    '[HKEY_CURRENT_USER\Software\Embarcadero\BDS\22.0\Paths]'#13#10 +
    '"DocDir"="C:\\Users\\OldUser\\Documents"'#13#10 +
    '"Other"="D:\\Static\\Path"'#13#10;

  RegExpected := 'Windows Registry Editor Version 5.00'#13#10 + #13#10 +
    '[HKEY_CURRENT_USER\Software\Embarcadero\BDS\22.0\Paths]'#13#10 +
    '"DocDir"="C:\\Users\\NewUser\\Documents"'#13#10 +
    '"Other"="D:\\Static\\Path"'#13#10;

  RegOut := RemapRegFileText(RegIn, 'C:\Users\OldUser', 'C:\Users\NewUser');
  Assert.AreEqual(RegExpected, RegOut);
end;

procedure TTestCoreRestoreEngine.TestRemapRegFileTextHex2Utf16RoundTrip;
var
  RegIn, RegRemapped, RegRoundTrip: string;
begin
  { hex(2) for "C:\Users\OldUser\Lib" in UTF-16LE:
    C: 43,00
    :: 3a,00
    \: 5c,00
    U: 55,00
    s: 73,00
    e: 65,00
    r: 72,00
    s: 73,00
    \: 5c,00
    O: 4f,00
    l: 6c,00
    d: 64,00
    U: 55,00
    s: 73,00
    e: 65,00
    r: 72,00
    \: 5c,00
    L: 4c,00
    i: 69,00
    b: 62,00
    NUL: 00,00 }
  RegIn := 'Windows Registry Editor Version 5.00'#13#10 + #13#10 +
    '[HKEY_CURRENT_USER\Software\Test]'#13#10 +
    '"Path"=hex(2):43,00,3a,00,5c,00,55,00,73,00,65,00,72,00,73,00,5c,00,4f,00,'
    + '6c,00,64,00,55,00,73,00,65,00,72,00,5c,00,4c,00,69,00,62,00,00,00'#13#10;

  { Remap from OldUser to NewUser }
  RegRemapped := RemapRegFileText(RegIn, 'C:\Users\OldUser',
    'C:\Users\NewUser');

  { NewUser in UTF-16LE:
    N: 4e,00
    e: 65,00
    w: 77,00
    U: 55,00
    s: 73,00
    e: 65,00
    r: 72,00 }
  Assert.IsTrue(Pos('4e,00,65,00,77,00,55,00,73,00,65,00,72,00', RegRemapped) >
    0, 'Hex bytes for NewUser must be present in remapped text');

  { Round trip: remap back from NewUser to OldUser }
  RegRoundTrip := RemapRegFileText(RegRemapped, 'C:\Users\NewUser',
    'C:\Users\OldUser');
  Assert.AreEqual(RegIn, RegRoundTrip,
    'Remapping back to original must produce exact original');
end;

initialization

TDUnitX.RegisterTestFixture(TTestCoreRestoreEngine);

end.
