unit Tests.Core.PathDiscovery;

interface

uses
  System.SysUtils,
  System.Classes,
  DUnitX.TestFramework,
  Core.Types,
  Core.PathDiscovery;

type

  [TestFixture]
  TTestCorePathDiscovery = class
  public
    [Test]
    procedure TestResolveBdsMacros;
    [Test]
    procedure TestResolveBdsMacrosUnresolvedReturnsEmpty;
    [Test]
    procedure TestReduceToRootFolders;
  end;

implementation

{ TTestCorePathDiscovery }

procedure TTestCorePathDiscovery.TestResolveBdsMacros;
var
  Ver: TDelphiVersion;
  Resolved: string;
begin
  Ver := TDelphiVersion.Create;
  try
    Ver.RootDir := 'C:\Program Files\Embarcadero\Studio\22.0\';
    Ver.CommonDir := 'C:\Users\Public\Documents\Embarcadero\Studio\22.0';
    Ver.UserDir := 'C:\Users\Dev\Documents\Embarcadero\Studio\22.0';

    Resolved := ResolveBdsMacros('$(BDS)\bin', Ver, 'Win32');
    Assert.AreEqual('C:\Program Files\Embarcadero\Studio\22.0\bin', Resolved);

    Resolved := ResolveBdsMacros('$(BDSCOMMONDIR)\Dcp\$(Platform)',
      Ver, 'Win32');
    Assert.AreEqual
      ('C:\Users\Public\Documents\Embarcadero\Studio\22.0\Dcp\Win32', Resolved);

    Resolved := ResolveBdsMacros('$(BDSUSERDIR)\Imports\$(Config)',
      Ver, 'Win32');
    Assert.AreEqual
      ('C:\Users\Dev\Documents\Embarcadero\Studio\22.0\Imports\Release',
      Resolved);

    Resolved := ResolveBdsMacros('$(BDSBIN)\bds.exe', Ver, 'Win32');
    Assert.AreEqual('C:\Program Files\Embarcadero\Studio\22.0\bin\bds.exe',
      Resolved);
  finally
    Ver.Free;
  end;
end;

procedure TTestCorePathDiscovery.TestResolveBdsMacrosUnresolvedReturnsEmpty;
var
  Ver: TDelphiVersion;
  Resolved: string;
begin
  Ver := TDelphiVersion.Create;
  try
    Ver.RootDir := 'C:\Delphi\';
    Resolved := ResolveBdsMacros('$(UNKNOWN_MACRO)\folder', Ver, 'Win32');
    Assert.AreEqual('', Resolved,
      'Unresolved macro must result in empty string');
  finally
    Ver.Free;
  end;
end;

procedure TTestCorePathDiscovery.TestReduceToRootFolders;
var
  List: TStringList;
begin
  List := TStringList.Create;
  try
    List.Add('C:\Components\MyLib\Fontes\MyLibCore');
    List.Add('C:\Components\MyLib\Fontes');
    List.Add('C:\Components\MyLib');
    List.Add('C:\OtherComponent');
    List.Add('C:\OtherComponent\SubFolder');
    List.Add('C:\Components\MyLib\'); { duplicate with trailing slash }

    ReduceToRootFolders(List);

    Assert.AreEqual(2, List.Count);
    Assert.IsTrue(List.IndexOf('C:\Components\MyLib') >= 0);
    Assert.IsTrue(List.IndexOf('C:\OtherComponent') >= 0);
  finally
    List.Free;
  end;
end;

initialization

TDUnitX.RegisterTestFixture(TTestCorePathDiscovery);

end.
