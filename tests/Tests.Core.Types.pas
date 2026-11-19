unit Tests.Core.Types;

interface

uses
  System.SysUtils,
  System.Classes,
  DUnitX.TestFramework,
  Core.Types;

type

  [TestFixture]
  TTestCoreTypes = class
  public
    [Test]
    procedure TestDelphiVersionSortKey;
    [Test]
    procedure TestSortOldestFirst;
    [Test]
    procedure TestBackupItemListNextIdAndFindBySource;
    [Test]
    procedure TestTextToVersionsAndVersionsToText;
    [Test]
    procedure TestCompareResultHasDifferences;
    [Test]
    procedure TestLegacyDelphiIdFunctions;
  end;

implementation

{ TTestCoreTypes }

procedure TTestCoreTypes.TestDelphiVersionSortKey;
var
  VD5, VD7, VBDS3, VBDS5, VXE8, V11: TDelphiVersion;
begin
  VD5 := TDelphiVersion.Create;
  VD7 := TDelphiVersion.Create;
  VBDS3 := TDelphiVersion.Create;
  VBDS5 := TDelphiVersion.Create;
  VXE8 := TDelphiVersion.Create;
  V11 := TDelphiVersion.Create;
  try
    VD5.Era := deBorlandDelphi;
    VD5.Major := 5;
    VD5.Minor := 0;
    VD5.BdsVersion := 'D5.0';

    VD7.Era := deBorlandDelphi;
    VD7.Major := 7;
    VD7.Minor := 0;
    VD7.BdsVersion := 'D7.0';

    VBDS3.Era := deBorlandBDS;
    VBDS3.Major := 3;
    VBDS3.Minor := 0;
    VBDS3.BdsVersion := '3.0';

    VBDS5.Era := deBorlandBDS;
    VBDS5.Major := 5;
    VBDS5.Minor := 0;
    VBDS5.BdsVersion := '5.0';

    VXE8.Era := deEmbarcadero;
    VXE8.Major := 16;
    VXE8.Minor := 0;
    VXE8.BdsVersion := '16.0';

    V11.Era := deEmbarcadero;
    V11.Major := 22;
    V11.Minor := 0;
    V11.BdsVersion := '22.0';

    Assert.AreEqual(500, VD5.SortKey);
    Assert.AreEqual(700, VD7.SortKey);
    Assert.AreEqual(10300, VBDS3.SortKey);
    Assert.AreEqual(10500, VBDS5.SortKey);
    Assert.AreEqual(11600, VXE8.SortKey);
    Assert.AreEqual(12200, V11.SortKey);

    { Delphi 5..7 era must sort strictly before BDS 3.0 even though 7 > 3 }
    Assert.IsTrue(VD5.SortKey < VD7.SortKey);
    Assert.IsTrue(VD7.SortKey < VBDS3.SortKey);
    Assert.IsTrue(VBDS3.SortKey < VBDS5.SortKey);
    Assert.IsTrue(VBDS5.SortKey < VXE8.SortKey);
    Assert.IsTrue(VXE8.SortKey < V11.SortKey);
  finally
    V11.Free;
    VXE8.Free;
    VBDS5.Free;
    VBDS3.Free;
    VD7.Free;
    VD5.Free;
  end;
end;

procedure TTestCoreTypes.TestSortOldestFirst;
var
  List: TDelphiVersionList;
  V: TDelphiVersion;
begin
  List := TDelphiVersionList.Create(True);
  try
    { Add in chaotic order: 22.0, D7.0, 3.0, 16.0, D5.0, 5.0 }
    V := TDelphiVersion.Create;
    V.Era := deEmbarcadero;
    V.Major := 22;
    V.Minor := 0;
    V.BdsVersion := '22.0';
    List.Add(V);

    V := TDelphiVersion.Create;
    V.Era := deBorlandDelphi;
    V.Major := 7;
    V.Minor := 0;
    V.BdsVersion := 'D7.0';
    List.Add(V);

    V := TDelphiVersion.Create;
    V.Era := deBorlandBDS;
    V.Major := 3;
    V.Minor := 0;
    V.BdsVersion := '3.0';
    List.Add(V);

    V := TDelphiVersion.Create;
    V.Era := deEmbarcadero;
    V.Major := 16;
    V.Minor := 0;
    V.BdsVersion := '16.0';
    List.Add(V);

    V := TDelphiVersion.Create;
    V.Era := deBorlandDelphi;
    V.Major := 5;
    V.Minor := 0;
    V.BdsVersion := 'D5.0';
    List.Add(V);

    V := TDelphiVersion.Create;
    V.Era := deBorlandBDS;
    V.Major := 5;
    V.Minor := 0;
    V.BdsVersion := '5.0';
    List.Add(V);

    List.SortOldestFirst;

    Assert.AreEqual(6, List.Count);
    Assert.AreEqual('D5.0', List[0].BdsVersion);
    Assert.AreEqual('D7.0', List[1].BdsVersion);
    Assert.AreEqual('3.0', List[2].BdsVersion);
    Assert.AreEqual('5.0', List[3].BdsVersion);
    Assert.AreEqual('16.0', List[4].BdsVersion);
    Assert.AreEqual('22.0', List[5].BdsVersion);
  finally
    List.Free;
  end;
end;

procedure TTestCoreTypes.TestBackupItemListNextIdAndFindBySource;
var
  Items: TBackupItemList;
  It1, It2, It3, Found: TBackupItem;
begin
  Items := TBackupItemList.Create(True);
  try
    Assert.AreEqual('f001', Items.NextId(ikFolder));
    Assert.AreEqual('f001', Items.NextId(ikFile));
    Assert.AreEqual('r001', Items.NextId(ikRegistry));
    Assert.AreEqual('d001', Items.NextId(ikDll));

    It1 := TBackupItem.Create;
    It1.Id := Items.NextId(ikFolder);
    It1.Kind := ikFolder;
    It1.SourcePath := 'C:\Components\MyLib';
    Items.Add(It1);

    Assert.AreEqual('f002', Items.NextId(ikFolder));

    It2 := TBackupItem.Create;
    It2.Id := Items.NextId(ikRegistry);
    It2.Kind := ikRegistry;
    It2.SourcePath := 'HKCU\Software\Embarcadero\BDS\22.0';
    Items.Add(It2);

    Assert.AreEqual('r002', Items.NextId(ikRegistry));

    It3 := TBackupItem.Create;
    It3.Id := Items.NextId(ikDll);
    It3.Kind := ikDll;
    It3.SourcePath := 'C:\Windows\System32\midas.dll';
    Items.Add(It3);

    Assert.AreEqual('d002', Items.NextId(ikDll));

    { FindBySource tests: case-insensitive and trailing slash tolerant }
    Found := Items.FindBySource(ikFolder, 'c:\components\mylib\');
    Assert.IsNotNull(Found);
    Assert.AreEqual('f001', Found.Id);

    Found := Items.FindBySource(ikRegistry,
      'hkcu\software\embarcadero\bds\22.0');
    Assert.IsNotNull(Found);
    Assert.AreEqual('r001', Found.Id);

    Found := Items.FindBySource(ikFolder, 'HKCU\Software\Embarcadero\BDS\22.0');
    Assert.IsNull(Found); { Different kind }

    Found := Items.FindBySource(ikFolder, 'C:\NonExistent');
    Assert.IsNull(Found);
  finally
    Items.Free;
  end;
end;

procedure TTestCoreTypes.TestTextToVersionsAndVersionsToText;
var
  Arr: TArray<string>;
  Txt: string;
begin
  Arr := TextToVersions('22.0, 5.0; D7.0');
  Assert.AreEqual(3, Length(Arr));
  Assert.AreEqual('22.0', Arr[0]);
  Assert.AreEqual('5.0', Arr[1]);
  Assert.AreEqual('D7.0', Arr[2]);

  { Trims empty parts }
  Arr := TextToVersions('  22.0 , , 23.0 ; ');
  Assert.AreEqual(2, Length(Arr));
  Assert.AreEqual('22.0', Arr[0]);
  Assert.AreEqual('23.0', Arr[1]);

  Txt := VersionsToText(Arr);
  Assert.AreEqual('22.0,23.0', Txt);

  { Round trip }
  Arr := TextToVersions(Txt);
  Assert.AreEqual(2, Length(Arr));
  Assert.AreEqual('22.0', Arr[0]);
  Assert.AreEqual('23.0', Arr[1]);
end;

procedure TTestCoreTypes.TestCompareResultHasDifferences;
var
  Res: TCompareResult;
begin
  Res := TCompareResult.Create;
  try
    Assert.IsFalse(Res.HasDifferences);

    Res.Add(dkInfo, '', 'version', 'informational note');
    Assert.IsFalse(Res.HasDifferences);

    Res.Add(dkAdded, 'f001', 'sub\new.pas', 'Arquivo adicionado');
    Assert.IsTrue(Res.HasDifferences);
  finally
    Res.Free;
  end;
end;

procedure TTestCoreTypes.TestLegacyDelphiIdFunctions;
begin
  Assert.AreEqual('D7.0', LegacyDelphiId('7.0'));
  Assert.AreEqual('D5.0', LegacyDelphiId('5.0'));

  Assert.IsTrue(IsLegacyDelphiId('D7.0'));
  Assert.IsTrue(IsLegacyDelphiId('d5.0'));
  Assert.IsFalse(IsLegacyDelphiId('22.0'));
  Assert.IsFalse(IsLegacyDelphiId('5.0'));
  Assert.IsFalse(IsLegacyDelphiId(''));

  Assert.AreEqual('7.0', VersionIdNumber('D7.0'));
  Assert.AreEqual('5.0', VersionIdNumber('d5.0'));
  Assert.AreEqual('22.0', VersionIdNumber('22.0'));
  Assert.AreEqual('3.0', VersionIdNumber('3.0'));
end;

initialization

TDUnitX.RegisterTestFixture(TTestCoreTypes);

end.
