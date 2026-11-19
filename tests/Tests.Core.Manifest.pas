unit Tests.Core.Manifest;

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  DUnitX.TestFramework,
  Core.Types,
  Core.Manifest;

type

  [TestFixture]
  TTestCoreManifest = class
  public
    [Test]
    procedure TestManifestSaveAndLoadRoundTrip;
    [Test]
    procedure TestComputeListingHashDeterminism;
  end;

implementation

{ TTestCoreManifest }

procedure TTestCoreManifest.TestManifestSaveAndLoadRoundTrip;
var
  M1, M2: TManifest;
  V: TManifestVersion;
  MI: TManifestItem;
  MF: TManifestFile;
  TempFile: string;
begin
  TempFile := TPath.Combine(TPath.GetTempPath, 'dbr_manifest_test_' +
    TGUID.NewGuid.ToString + '.json');
  try
    M1 := TManifest.Create;
    try
      M1.ToolVersion := '1.2.3';
      M1.MachineName := 'TEST-MACHINE';
      M1.CreatedUtc := '2026-11-19T10:00:00Z';
      M1.SourceUserProfile := 'C:\Users\TestUser';
      M1.SourcePublicDir := 'C:\Users\Public';
      M1.UserPath := 'C:\Tools;C:\Bin';

      V := TManifestVersion.Create;
      V.BdsVersion := '22.0';
      V.ProductName := 'Delphi 11 Alexandria';
      V.ProductVersion := '28.0.47991.2819';
      V.InstalledUpdates := 'Update 1';
      V.RootDir := 'C:\Delphi\22.0\';
      M1.Versions.Add(V);

      MI := TManifestItem.Create;
      MI.Item := TBackupItem.Create;
      MI.Item.Id := 'f001';
      MI.Item.Kind := ikFolder;
      MI.Item.Category := icComponents;
      MI.Item.SourcePath := 'C:\Components\MyLib';
      MI.Item.Description := 'MyLib library';
      MI.Item.Versions.Add('22.0');
      MI.Hash :=
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

      MF := TManifestFile.Create;
      MF.RelPath := 'Fontes\MyLibCore.pas';
      MF.Size := 10240;
      MF.ModifiedUtc := '2026-11-19T08:30:00Z';
      MI.Files.Add(MF);

      M1.Items.Add(MI);

      SaveManifest(M1, TempFile);
    finally
      M1.Free;
    end;

    Assert.IsTrue(TFile.Exists(TempFile));

    M2 := LoadManifest(TempFile);
    try
      Assert.AreEqual(MANIFEST_FORMAT_VERSION, M2.FormatVersion);
      Assert.AreEqual('1.2.3', M2.ToolVersion);
      Assert.AreEqual('TEST-MACHINE', M2.MachineName);
      Assert.AreEqual('2026-11-19T10:00:00Z', M2.CreatedUtc);
      Assert.AreEqual('C:\Users\TestUser', M2.SourceUserProfile);
      Assert.AreEqual('C:\Users\Public', M2.SourcePublicDir);
      Assert.AreEqual('C:\Tools;C:\Bin', M2.UserPath);

      Assert.AreEqual(1, M2.Versions.Count);
      Assert.AreEqual('22.0', M2.Versions[0].BdsVersion);
      Assert.AreEqual('Delphi 11 Alexandria', M2.Versions[0].ProductName);
      Assert.AreEqual('28.0.47991.2819', M2.Versions[0].ProductVersion);
      Assert.AreEqual('Update 1', M2.Versions[0].InstalledUpdates);
      Assert.AreEqual('C:\Delphi\22.0\', M2.Versions[0].RootDir);

      Assert.AreEqual(1, M2.Items.Count);
      Assert.AreEqual('f001', M2.Items[0].Item.Id);
      Assert.AreEqual(ikFolder, M2.Items[0].Item.Kind);
      Assert.AreEqual(icComponents, M2.Items[0].Item.Category);
      Assert.AreEqual('C:\Components\MyLib', M2.Items[0].Item.SourcePath);
      Assert.AreEqual('MyLib library', M2.Items[0].Item.Description);
      Assert.AreEqual
        ('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        M2.Items[0].Hash);

      Assert.AreEqual(1, M2.Items[0].Files.Count);
      Assert.AreEqual('Fontes\MyLibCore.pas', M2.Items[0].Files[0].RelPath);
      Assert.AreEqual(Int64(10240), M2.Items[0].Files[0].Size);
      Assert.AreEqual('2026-11-19T08:30:00Z', M2.Items[0].Files[0].ModifiedUtc);
    finally
      M2.Free;
    end;
  finally
    if TFile.Exists(TempFile) then
      TFile.Delete(TempFile);
  end;
end;

procedure TTestCoreManifest.TestComputeListingHashDeterminism;
var
  Item: TManifestItem;
  F1, F2: TManifestFile;
  Hash1, Hash2, HashChanged: string;
begin
  Item := TManifestItem.Create;
  try
    F1 := TManifestFile.Create;
    F1.RelPath := 'a.pas';
    F1.Size := 100;
    F1.ModifiedUtc := '2026-01-01T00:00:00Z';
    Item.Files.Add(F1);

    F2 := TManifestFile.Create;
    F2.RelPath := 'b.pas';
    F2.Size := 200;
    F2.ModifiedUtc := '2026-01-01T00:00:00Z';
    Item.Files.Add(F2);

    Hash1 := ComputeListingHash(Item);
    Hash2 := ComputeListingHash(Item);

    Assert.IsNotEmpty(Hash1);
    Assert.AreEqual(Hash1, Hash2,
      'Hash calculation must be completely deterministic');

    { Mutating a file changes the hash }
    F2.Size := 201;
    HashChanged := ComputeListingHash(Item);
    Assert.AreNotEqual(Hash1, HashChanged);
  finally
    Item.Free;
  end;
end;

initialization

TDUnitX.RegisterTestFixture(TTestCoreManifest);

end.
