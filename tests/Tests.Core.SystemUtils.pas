unit Tests.Core.SystemUtils;

interface

uses
  System.SysUtils,
  DUnitX.TestFramework,
  Core.SystemUtils;

type

  [TestFixture]
  TTestCoreSystemUtils = class
  public
    [Test]
    procedure TestCompareVersionText;
    [Test]
    procedure TestIsPathInside;
  end;

implementation

{ TTestCoreSystemUtils }

procedure TTestCoreSystemUtils.TestCompareVersionText;
begin
  Assert.AreEqual(0, CompareVersionText('1.0.0.0', '1.0.0.0'));
  Assert.AreEqual(0, CompareVersionText('1.0', '1.0.0.0'));
  Assert.AreEqual(1, CompareVersionText('1.2.0.0', '1.1.9.9'));
  Assert.AreEqual(-1, CompareVersionText('1.0.0', '1.0.1'));
  Assert.AreEqual(1, CompareVersionText('2.0', '1.9.9.9'));
  Assert.AreEqual(1, CompareVersionText('10.1', '9.4'));
  Assert.AreEqual(-1, CompareVersionText('22.0', '23.0'));
  Assert.AreEqual(1, CompareVersionText('23.0', '22.0'));
end;

procedure TTestCoreSystemUtils.TestIsPathInside;
begin
  { Inside subfolder }
  Assert.IsTrue(IsPathInside('C:\Components\MyLib\Fontes',
    'C:\Components\MyLib'));
  { Case insensitive and trailing delimiter tolerant }
  Assert.IsTrue(IsPathInside('c:\components\mylib\fontes\',
    'C:\Components\MyLib\'));
  { Path inside itself }
  Assert.IsTrue(IsPathInside('C:\Components\MyLib', 'C:\Components\MyLib'));

  { Prefix match on folder name is NOT inside }
  Assert.IsFalse(IsPathInside('C:\Components\MyLibOther',
    'C:\Components\MyLib'));

  { Different drives }
  Assert.IsFalse(IsPathInside('D:\Components\MyLib', 'C:\Components\MyLib'));

  { Empty or root }
  Assert.IsFalse(IsPathInside('', 'C:\Components'));
  Assert.IsFalse(IsPathInside('C:\', 'C:\Components'));
end;

initialization

TDUnitX.RegisterTestFixture(TTestCoreSystemUtils);

end.
