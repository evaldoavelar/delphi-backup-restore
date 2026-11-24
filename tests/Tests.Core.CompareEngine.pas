unit Tests.Core.CompareEngine;

interface

uses
  System.SysUtils,
  System.Classes,
  DUnitX.TestFramework,
  Core.Types,
  Core.CompareEngine;

type

  [TestFixture]
  TTestCoreCompareEngine = class
  public
    [Test]
    procedure TestDiffManifestsVersionMissing;
    [Test]
    procedure TestDiffManifestsFilesAddedRemovedChanged;
    [Test]
    procedure ToleratesRenamedNonAsciiFile;
    [Test]
    procedure ToleratesCollapsedNonAsciiFiles;
    [Test]
    procedure KeepsDifferencesForExactNamesAndDifferentAsciiCharacters;
  end;

implementation

{ TTestCoreCompareEngine }

procedure TTestCoreCompareEngine.TestDiffManifestsVersionMissing;
var
  Backup, Current: TManifest;
  VB: TManifestVersion;
  Diff: TCompareResult;
begin
  Backup := TManifest.Create;
  Current := TManifest.Create;
  try
    VB := TManifestVersion.Create;
    VB.BdsVersion := '22.0';
    VB.ProductName := 'Delphi 11 Alexandria';
    VB.ProductVersion := '28.0';
    Backup.Versions.Add(VB);

    { Current has no installed versions }
    Diff := DiffManifests(Backup, Current, []);
    try
      Assert.IsTrue(Diff.HasDifferences);
      Assert.AreEqual(1, Diff.Entries.Count);
      Assert.AreEqual(dkRemoved, Diff.Entries[0].Kind);
      Assert.AreEqual('22.0', Diff.Entries[0].Path);
      Assert.AreEqual('Versão não instalada', Diff.Entries[0].Detail);
    finally
      Diff.Free;
    end;
  finally
    Current.Free;
    Backup.Free;
  end;
end;

procedure TTestCoreCompareEngine.TestDiffManifestsFilesAddedRemovedChanged;
var
  Backup, Current: TManifest;
  VB, VC: TManifestVersion;
  ItemB, ItemC: TManifestItem;
  F: TManifestFile;
  Diff: TCompareResult;
  E: TDiffEntry;
  FoundAdded, FoundRemoved, FoundChanged: Boolean;
begin
  Backup := TManifest.Create;
  Current := TManifest.Create;
  try
    Backup.SourceUserProfile := 'C:\Users\Dev';
    Current.SourceUserProfile := 'C:\Users\Dev';

    VB := TManifestVersion.Create;
    VB.BdsVersion := '22.0';
    VB.ProductVersion := '28.0';
    Backup.Versions.Add(VB);

    VC := TManifestVersion.Create;
    VC.BdsVersion := '22.0';
    VC.ProductVersion := '28.0';
    Current.Versions.Add(VC);

    { Setup item in Backup: has 'unchanged.pas', 'removed.pas', 'changed.pas' }
    ItemB := TManifestItem.Create;
    ItemB.Item := TBackupItem.Create;
    ItemB.Item.Id := 'f001';
    ItemB.Item.Kind := ikFolder;
    ItemB.Item.SourcePath := 'C:\Components\Test';
    ItemB.Item.Versions.Add('22.0');

    F := TManifestFile.Create;
    F.RelPath := 'unchanged.pas';
    F.Size := 100;
    F.ModifiedUtc := '2026-01-01T00:00:00Z';
    ItemB.Files.Add(F);

    F := TManifestFile.Create;
    F.RelPath := 'removed.pas';
    F.Size := 200;
    F.ModifiedUtc := '2026-01-01T00:00:00Z';
    ItemB.Files.Add(F);

    F := TManifestFile.Create;
    F.RelPath := 'changed.pas';
    F.Size := 300;
    F.ModifiedUtc := '2026-01-01T00:00:00Z';
    ItemB.Files.Add(F);

    Backup.Items.Add(ItemB);

    { Setup item in Current: has 'unchanged.pas', 'changed.pas' (modified), 'added.pas' }
    ItemC := TManifestItem.Create;
    ItemC.Item := TBackupItem.Create;
    ItemC.Item.Id := 'f001';
    ItemC.Item.Kind := ikFolder;
    ItemC.Item.SourcePath := 'C:\Components\Test';
    ItemC.Item.Versions.Add('22.0');

    F := TManifestFile.Create;
    F.RelPath := 'unchanged.pas';
    F.Size := 100;
    F.ModifiedUtc := '2026-01-01T00:00:00Z';
    ItemC.Files.Add(F);

    F := TManifestFile.Create;
    F.RelPath := 'changed.pas';
    F.Size := 350; { size changed }
    F.ModifiedUtc := '2026-01-02T00:00:00Z';
    ItemC.Files.Add(F);

    F := TManifestFile.Create;
    F.RelPath := 'added.pas';
    F.Size := 400;
    F.ModifiedUtc := '2026-01-01T00:00:00Z';
    ItemC.Files.Add(F);

    Current.Items.Add(ItemC);

    Diff := DiffManifests(Backup, Current, ['22.0']);
    try
      Assert.IsTrue(Diff.HasDifferences);
      Assert.AreEqual(3, Diff.Entries.Count);

      FoundAdded := False;
      FoundRemoved := False;
      FoundChanged := False;

      for E in Diff.Entries do
      begin
        if (E.Kind = dkRemoved) and (E.Path = 'removed.pas') then
          FoundRemoved := True;
        if (E.Kind = dkChanged) and (E.Path = 'changed.pas') then
          FoundChanged := True;
        if (E.Kind = dkAdded) and (E.Path = 'added.pas') then
          FoundAdded := True;
      end;

      Assert.IsTrue(FoundRemoved, 'removed.pas should be flagged as removed');
      Assert.IsTrue(FoundChanged, 'changed.pas should be flagged as changed');
      Assert.IsTrue(FoundAdded, 'added.pas should be flagged as added');
    finally
      Diff.Free;
    end;
  finally
    Current.Free;
    Backup.Free;
  end;
end;

function AddFolder(AManifest: TManifest): TManifestItem;
begin
  Result := TManifestItem.Create;
  AManifest.Items.Add(Result);
  Result.Item := TBackupItem.Create;
  Result.Item.Id := 'f001';
  Result.Item.Kind := ikFolder;
  Result.Item.SourcePath := 'C:\ACBr';
end;

procedure AddFile(AItem: TManifestItem; const APath: string; ASize: Int64);
var
  F: TManifestFile;
begin
  F := TManifestFile.Create;
  AItem.Files.Add(F);
  F.RelPath := APath;
  F.Size := ASize;
  F.ModifiedUtc := '2026-01-01T00:00:00Z';
end;

procedure TTestCoreCompareEngine.ToleratesRenamedNonAsciiFile;
var
  Backup, Current: TManifest;
  Diff: TCompareResult;
begin
  Backup := TManifest.Create;
  Current := TManifest.Create;
  try
    AddFile(AddFolder(Backup), 'Manuais\Automação Comercial.sxi', 100);
    AddFile(AddFolder(Current), 'manuais\Automaç╞o Comercial.sxi', 200);
    Diff := DiffManifests(Backup, Current, []);
    try
      Assert.IsFalse(Diff.HasDifferences);
      Assert.AreEqual(0, Diff.Entries.Count);
      Assert.AreEqual(1, Diff.TolerantFileCount);
    finally
      Diff.Free;
    end;
  finally
    Current.Free;
    Backup.Free;
  end;
end;

procedure TTestCoreCompareEngine.ToleratesCollapsedNonAsciiFiles;
var
  Backup, Current: TManifest;
  Folder: TManifestItem;
  Diff: TCompareResult;
begin
  Backup := TManifest.Create;
  Current := TManifest.Create;
  try
    Folder := AddFolder(Backup);
    AddFile(Folder, 'Automação Comercial.sxi', 100);
    AddFile(Folder, 'Automaç╞o Comercial.sxi', 200);
    AddFile(AddFolder(Current), 'Automação Comercial.sxi', 200);
    Diff := DiffManifests(Backup, Current, []);
    try
      Assert.IsFalse(Diff.HasDifferences);
      Assert.AreEqual(0, Diff.Entries.Count);
      Assert.AreEqual(2, Diff.TolerantFileCount);
    finally
      Diff.Free;
    end;
  finally
    Current.Free;
    Backup.Free;
  end;
end;

procedure TTestCoreCompareEngine.
  KeepsDifferencesForExactNamesAndDifferentAsciiCharacters;
var
  Backup, Current: TManifest;
  Folder: TManifestItem;
  Diff: TCompareResult;
begin
  Backup := TManifest.Create;
  Current := TManifest.Create;
  try
    Folder := AddFolder(Backup);
    AddFile(Folder, 'Automação Comercial.sxi', 100);
    AddFile(Folder, 'Ação.sxi', 300);
    Folder := AddFolder(Current);
    AddFile(Folder, 'AUTOMAÇÃO COMERCIAL.SXI', 200);
    AddFile(Folder, 'Aça╞.sxi', 300);
    Diff := DiffManifests(Backup, Current, []);
    try
      Assert.AreEqual(3, Diff.Entries.Count);
      Assert.AreEqual(0, Diff.TolerantFileCount);
      Assert.AreEqual(dkChanged, Diff.Entries[0].Kind);
      Assert.AreEqual(dkRemoved, Diff.Entries[1].Kind);
      Assert.AreEqual(dkAdded, Diff.Entries[2].Kind);
    finally
      Diff.Free;
    end;
  finally
    Current.Free;
    Backup.Free;
  end;
end;

initialization

TDUnitX.RegisterTestFixture(TTestCoreCompareEngine);

end.
