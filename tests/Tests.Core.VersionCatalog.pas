unit Tests.Core.VersionCatalog;

interface

uses
  System.SysUtils,
  DUnitX.TestFramework,
  Core.Types,
  Core.VersionCatalog;

type

  [TestFixture]
  TTestCoreVersionCatalog = class
  public
    [Test]
    procedure TestProductNameForVersion;
    [Test]
    procedure TestRegistryRootForEra;
    [Test]
    procedure TestStudioFolderName;
  end;

implementation

{ TTestCoreVersionCatalog }

procedure TTestCoreVersionCatalog.TestProductNameForVersion;
var
  Name: string;
begin
  { 22.0 -> contains 'Alexandria' }
  Name := ProductNameForVersion(deEmbarcadero, '22.0');
  Assert.IsTrue(Pos('Alexandria', Name) > 0, 'Expected Alexandria in: ' + Name);
  Assert.AreEqual('Delphi 11 Alexandria', Name);

  { 23.0 -> 'Athens' }
  Name := ProductNameForVersion(deEmbarcadero, '23.0');
  Assert.IsTrue(Pos('Athens', Name) > 0, 'Expected Athens in: ' + Name);
  Assert.AreEqual('Delphi 12 Athens', Name);

  { 37.0 -> 'Florence' }
  Name := ProductNameForVersion(deEmbarcadero, '37.0');
  Assert.IsTrue(Pos('Florence', Name) > 0, 'Expected Florence in: ' + Name);
  Assert.AreEqual('Delphi 13 Florence', Name);

  { 5.0 BDS -> '2007' }
  Name := ProductNameForVersion(deBorlandBDS, '5.0');
  Assert.IsTrue(Pos('2007', Name) > 0, 'Expected 2007 in: ' + Name);
  Assert.AreEqual('Delphi 2007', Name);

  { 5.0 Borland Delphi -> 'Delphi 5' }
  Name := ProductNameForVersion(deBorlandDelphi, '5.0');
  Assert.AreEqual('Delphi 5', Name);

  { 7.0 Borland Delphi -> 'Delphi 7' }
  Name := ProductNameForVersion(deBorlandDelphi, '7.0');
  Assert.AreEqual('Delphi 7', Name);

  { Unknown 99.0 -> 'Delphi (BDS 99.0)' }
  Name := ProductNameForVersion(deEmbarcadero, '99.0');
  Assert.AreEqual('Delphi (BDS 99.0)', Name);
end;

procedure TTestCoreVersionCatalog.TestRegistryRootForEra;
begin
  Assert.AreEqual('Software\Borland\Delphi',
    RegistryRootForEra(deBorlandDelphi));
  Assert.AreEqual('Software\Borland\BDS', RegistryRootForEra(deBorlandBDS));
  Assert.AreEqual('Software\CodeGear\BDS', RegistryRootForEra(deCodeGear));
  Assert.AreEqual('Software\Embarcadero\BDS',
    RegistryRootForEra(deEmbarcadero));
end;

procedure TTestCoreVersionCatalog.TestStudioFolderName;
begin
  Assert.AreEqual('', StudioFolderName(deBorlandDelphi, '7.0'));
  Assert.AreEqual('Borland Studio Projects',
    StudioFolderName(deBorlandBDS, '3.0'));
  Assert.AreEqual('Borland Studio Projects',
    StudioFolderName(deBorlandBDS, '4.0'));
  Assert.AreEqual('RAD Studio', StudioFolderName(deBorlandBDS, '5.0'));
  Assert.AreEqual('RAD Studio', StudioFolderName(deCodeGear, '7.0'));
  Assert.AreEqual('RAD Studio', StudioFolderName(deEmbarcadero, '12.0'));
  Assert.AreEqual('Embarcadero\Studio', StudioFolderName(deEmbarcadero,
    '14.0'));
  Assert.AreEqual('Embarcadero\Studio', StudioFolderName(deEmbarcadero,
    '22.0'));
  Assert.AreEqual('Embarcadero\Studio', StudioFolderName(deEmbarcadero,
    '37.0'));
end;

initialization

TDUnitX.RegisterTestFixture(TTestCoreVersionCatalog);

end.
