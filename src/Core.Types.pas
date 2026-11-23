unit Core.Types;

{ Shared contracts for delphi-backup-restore.

  COMPATIBILITY: this unit (and the whole project) must compile on Delphi XE8
  (CompilerVersion 29) and every later version. See CONTRIBUTING.md:
  no inline vars, no type inference, no managed records, no ternary "if"
  expressions, no DFM files. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

const
  TOOL_NAME = 'DelphiBackupRestore';

  { Backup folder layout (relative to the backup root folder) }
  BACKUP_MANIFEST_FILE = 'manifest.json';
  BACKUP_LOG_FILE = 'backup.log';
  BACKUP_FILES_DIR = 'files'; // files\<ItemId>\...  (folders and single files)
  BACKUP_REGISTRY_DIR = 'registry'; // registry\<ItemId>.reg
  BACKUP_DLLS_DIR = 'dlls'; // dlls\<ItemId>\<FileName>
  BACKUP_FOLDER_PREFIX = 'DelphiEnv_'; // DelphiEnv_<MACHINE>_<yyyyMMdd_HHnn>

  MANIFEST_FORMAT_VERSION = 1;

  { Optional config file located next to the exe }
  CONFIG_FILE_NAME = 'DelphiBackupRestore.json';

  { Process exit codes (CLI) }
  EXIT_OK = 0;
  EXIT_DIFFERENCES = 1; // compare found differences
  EXIT_ERROR = 2; // generic failure
  EXIT_PRECHECK = 3;
  // precheck refused (IDE running, version missing, not admin)
  EXIT_USAGE = 4; // invalid command line

type
  EDelphiBackupError = class(Exception);
  EPrecheckError = class(EDelphiBackupError);

  { ---------------------------------------------------------------- Logging }

  TLogLevel = (llDebug, llInfo, llWarn, llError);

  TLogSink = reference to procedure(ALevel: TLogLevel; const AMessage: string);

  TProgressProc = reference to procedure(ACurrent, ATotal: Integer;
    const AStep: string);

  ILogger = interface
    ['{6F0C2B1E-9E52-4C3B-9E0B-2F6A3A1D7C01}']
    procedure Log(ALevel: TLogLevel; const AMessage: string);
    procedure Debug(const AMessage: string);
    procedure Info(const AMessage: string);
    procedure Warn(const AMessage: string);
    procedure Error(const AMessage: string);
    { Extra destinations (GUI memo, console). File sink is configured via SetLogFile. }
    procedure AddSink(const ASink: TLogSink);
    { Starts (or switches) mirroring every message to a UTF-8 file. Empty = stop. }
    procedure SetLogFile(const AFileName: string);
  end;

  { --------------------------------------------------------------- Versions }

  TDelphiEra = (deBorlandDelphi, // Software\Borland\Delphi\<v>   (Delphi 5..7)
    deBorlandBDS, // Software\Borland\BDS\<v>      (2005..2007, BDS 3.0..5.0)
    deCodeGear, // Software\CodeGear\BDS\<v>     (2009..2010, BDS 6.0..7.0)
    deEmbarcadero // Software\Embarcadero\BDS\<v>  (XE and later, BDS 8.0+)
    );

  TDelphiVersion = class
  public
    { Version identifier, unique per machine. Equals the registry version key ('22.0',
      '5.0') except for the Borland\Delphi era (Delphi 5..7), which is prefixed with 'D'
      ('D7.0') because Delphi 5 and Delphi 2007 (BDS 5.0) share the key name '5.0'.
      Use VersionIdNumber to get the registry key name back. }
    BdsVersion: string;
    Major: Integer; // parsed from BdsVersion, used for ordering
    Minor: Integer;
    Era: TDelphiEra;
    ProductName: string;
    // e.g. 'Delphi 11 Alexandria' (from Core.VersionCatalog)
    RegistryKey: string; // relative key, e.g. 'Software\Embarcadero\BDS\22.0'
    // (valid under HKCU and under HKLM\SOFTWARE\WOW6432Node minus 'Software\')
    RootDir: string; // install dir with trailing backslash
    ProductVersion: string;
    InstalledUpdates: string;
    // flattened 'name=value;...' from <key>\InstalledUpdates (may be empty)
    CommonDir: string;
    // $(BDSCOMMONDIR): Public Documents folder of this version
    UserDir: string; // $(BDSUSERDIR):   user Documents folder of this version
    AppDataDir: string;
    // %APPDATA% folder of this version (layouts, EnvOptions.proj)
    { Ordering key: older versions sort first. Delphi 5..7 (deBorlandDelphi)
      must sort before BDS 3.0 even though 7 > 3, so the era is part of the key. }
    function SortKey: Integer;
    function DisplayName: string; // 'Delphi 11 Alexandria (BDS 22.0)'
  end;

  TDelphiVersionList = class(TObjectList<TDelphiVersion>)
  public
    function FindByBds(const ABdsVersion: string): TDelphiVersion;
    procedure SortOldestFirst;
  end;

  { ------------------------------------------------------------ Backup items }

  TItemKind = (ikFolder, // whole folder tree, copied with robocopy
    ikFile, // single file (e.g. expert DLL living inside $(BDS)\bin)
    ikRegistry, // registry key, exported with reg.exe
    ikDll // third-party DLL from System32/SysWOW64 (optional scan)
    );

  TItemCategory = (icComponents,
    // third-party component folders found in library paths / packages
    icIdeConfig, // IDE registry key + BDSCOMMONDIR/BDSUSERDIR/AppData folders
    icExperts, // expert/plugin folders, files and their registry keys
    icBoss, // %USERPROFILE%\.boss
    icExtra, // from the config file
    icSystemDll // optional DLL scan results
    );
  TItemCategories = set of TItemCategory;

  TDllOrigin = (doNone, doDependency, doSystemScan);

  TBackupItem = class
  public
    Id: string; // stable, unique inside one backup: 'f001', 'r001', 'd001'
    Kind: TItemKind;
    Category: TItemCategory;
    { Absolute path for ikFolder/ikFile/ikDll.
      Full key for ikRegistry, always starting with 'HKCU\' or 'HKLM\',
      e.g. 'HKCU\Software\Embarcadero\BDS\22.0'. }
    SourcePath: string;
    { BDS versions that use this item ('22.0', '5.0'). Empty list = global item,
      restored when any version is restored. }
    Versions: TStringList;
    Selected: Boolean;
    // user choice (GUI/CLI); engines only process Selected items
    Description: string; // human readable, shown in GUI/log
    { ikDll only }
    Company: string;
    FileVersion: string; // 'a.b.c.d'
    DllOrigin: TDllOrigin;
    ReinstalledByIde: Boolean;
    // Borland/CodeGear/Embarcadero runtime: informational only
    constructor Create;
    destructor Destroy; override;
    function UsedByVersion(const ABdsVersion: string): Boolean;
    // True if global or listed
  end;

  TBackupItemList = class(TObjectList<TBackupItem>)
  public
    function FindById(const AId: string): TBackupItem;
    function FindBySource(AKind: TItemKind; const ASourcePath: string)
      : TBackupItem; // case-insensitive
    function NextId(AKind: TItemKind): string;
    // 'f'/'r'/'d' + 3 digits, unique in list
  end;

  { --------------------------------------------------------------- Manifest }

  TManifestFile = class
  public
    RelPath: string; // relative to the item root, backslash separated
    Size: Int64;
    ModifiedUtc: string; // ISO 8601, 'yyyy-mm-dd"T"hh:nn:ss"Z"'
  end;

  TManifestItem = class
  public
    Item: TBackupItem; // owned
    Files: TObjectList<TManifestFile>; // owned; empty for ikRegistry
    Hash: string; // SHA256 (hex, lowercase) of the sorted file listing,
    // or of the normalized .reg content for ikRegistry
    constructor Create;
    destructor Destroy; override;
  end;

  TManifestVersion = class
  public
    BdsVersion: string;
    ProductName: string;
    ProductVersion: string;
    InstalledUpdates: string;
    RootDir: string;
  end;

  TManifest = class
  public
    FormatVersion: Integer;
    ToolVersion: string;
    MachineName: string;
    CreatedUtc: string;
    SourceUserProfile: string;
    // e.g. 'C:\Users\Desenvolvimento' (for path remapping)
    SourceDocumentsDir: string;
    SourcePublicDir: string; // e.g. 'C:\Users\Public'
    UserPath: string; // user PATH environment variable at backup time
    HasExclusions: Boolean; // both exclusion fields were recorded
    ExcludeDirs: TStringList; // owned
    ExcludeFiles: TStringList; // owned
    Versions: TObjectList<TManifestVersion>; // owned
    Items: TObjectList<TManifestItem>; // owned
    constructor Create;
    destructor Destroy; override;
    function FindVersion(const ABdsVersion: string): TManifestVersion;
  end;

  { ---------------------------------------------------------------- Options }

  TToolConfig = class
  public
    ExtraFolders: TStringList; // absolute paths, %ENV% allowed
    ExtraRegistryKeys: TStringList; // 'HKCU\...' / 'HKLM\...'
    ExcludeDirs: TStringList; // folder names (robocopy /XD)
    ExcludeFiles: TStringList; // masks (robocopy /XF)
    constructor Create; // fills default excludes
    destructor Destroy; override;
  end;

  TBackupOptions = record
    Versions: TArray<string>; // BDS versions selected
    Destination: string;
    // parent folder; engine creates DelphiEnv_<MACHINE>_<stamp>
    CreateZip: Boolean; // default True
    { with CreateZip: keep the backup folder next to the .zip. Default False: the
      folder is deleted after the zip is verified (same file count). }
    KeepFolder: Boolean;
    ScanDlls: Boolean; // default False
    Categories: TItemCategories; // default all except icSystemDll
  end;

  TRestoreOptions = record
    Source: string; // backup folder or .zip
    Versions: TArray<string>; // empty = every version in the backup
    Categories: TItemCategories;
  end;

  TCompareOptions = record
    Source: string;
    Versions: TArray<string>;
  end;

  { ------------------------------------------------------- Compare result }

  TDiffKind = (dkAdded, dkRemoved, dkChanged, dkInfo);

  TDiffEntry = class
  public
    Kind: TDiffKind;
    ItemId: string;
    Path: string; // file path, registry key or version label
    Detail: string;
  end;

  TCompareResult = class
  public
    Entries: TObjectList<TDiffEntry>;
    constructor Create;
    destructor Destroy; override;
    function HasDifferences: Boolean; // any entry with Kind <> dkInfo
    procedure Add(AKind: TDiffKind; const AItemId, APath, ADetail: string);
  end;

  { ------------------------------------------------------- Service contracts }

  IProcessRunner = interface
    ['{A3E4C1D2-5B6F-4E7A-8C9D-0E1F2A3B4C02}']
    { Runs an executable hidden, waits, returns the exit code and captured stdout+stderr. }
    function Run(const AExe, AArgs, AWorkDir: string; out AOutput: string)
      : Cardinal;
    { robocopy wrappers. Mirror=True uses /MIR, otherwise /E. Returns True on robocopy exit < 8. }
    function CopyTree(const ASource, ADest: string; AMirror: Boolean;
      AExcludeDirs, AExcludeFiles: TStrings): Boolean;
    function CopyFile(const ASourceFile, ADestDir: string): Boolean;
    { reg.exe wrappers. AKey = 'HKCU\...' / 'HKLM\...'. Export uses /reg:32 for HKLM. }
    function RegExport(const AKey, AFileName: string): Boolean;
    function RegImport(const AFileName: string; AHklm32: Boolean): Boolean;
    function RegDelete(const AKey: string): Boolean;
    function RegKeyExists(const AKey: string): Boolean;
    { tar.exe wrappers (Windows 10 1803+). }
    function ZipFolder(const AFolder, AZipFile: string): Boolean;
    function UnzipTo(const AZipFile, ADestFolder: string): Boolean;
  end;

  IVersionDetector = interface
    ['{B4F5D2E3-6C7A-4F8B-9DAE-1F2A3B4C5D03}']
    { Fills AList with every Delphi version installed on this machine, oldest first. }
    procedure Detect(AList: TDelphiVersionList);
  end;

  IPathDiscovery = interface
    ['{C5A6E3F4-7D8B-4A9C-AEBF-2A3B4C5D6E04}']
    { Adds to AItems every folder/file/registry item needed by AVersions.
      Shared root folders appear once with all versions listed in Item.Versions. }
    procedure Discover(AVersions: TDelphiVersionList; AConfig: TToolConfig;
      AItems: TBackupItemList);
  end;

  IDllScanner = interface
    ['{D6B7F4A5-8E9C-4BAD-BFC0-3B4C5D6E7F05}']
    { Adds ikDll items (Selected=False) for third-party DLLs: static dependencies of
      the packages/experts of AVersions not covered by ACovered, plus non-Microsoft
      DLL/BPL files in System32/SysWOW64. }
    procedure Scan(AVersions: TDelphiVersionList; ACovered: TBackupItemList;
      AResult: TBackupItemList);
  end;

  { Free helpers shared by every unit }
function VersionsToText(const AVersions: TArray<string>): string; // '22.0,5.0'
function TextToVersions(const AText: string): TArray<string>; // accepts , or ;
function ContainsText(const AList: TArray<string>;
  const AValue: string): Boolean;
function LogLevelToText(ALevel: TLogLevel): string;
function ItemKindToText(AKind: TItemKind): string;
function TextToItemKind(const AText: string): TItemKind;
function ItemCategoryToText(ACategory: TItemCategory): string;
function TextToItemCategory(const AText: string): TItemCategory;
function AllCategories: TItemCategories;
function DefaultBackupCategories: TItemCategories; // all except icSystemDll
{ Version identifiers: 'D7.0' = Borland Delphi 7, '5.0' = BDS 5.0 (Delphi 2007), see BdsVersion }
function LegacyDelphiId(const ARegistryVersion: string): string;
// '7.0' -> 'D7.0'
function IsLegacyDelphiId(const AId: string): Boolean; // starts with 'D'
function VersionIdNumber(const AId: string): string; // 'D7.0' -> '7.0'

implementation

{ TDelphiVersion }

function TDelphiVersion.SortKey: Integer;
begin
  if Era = deBorlandDelphi then
    Result := Major * 100 + Minor // Delphi 5..7 -> 500..700
  else
    Result := 10000 + Major * 100 + Minor; // BDS 3.0+ always after Delphi 7
end;

function TDelphiVersion.DisplayName: string;
begin
  if ProductName <> '' then
    Result := Format('%s (BDS %s)', [ProductName, BdsVersion])
  else
    Result := Format('Delphi (BDS %s)', [BdsVersion]);
end;

{ TDelphiVersionList }

function TDelphiVersionList.FindByBds(const ABdsVersion: string)
  : TDelphiVersion;
var
  V: TDelphiVersion;
begin
  Result := nil;
  for V in Self do
    if SameText(V.BdsVersion, ABdsVersion) then
      Exit(V);
end;

procedure TDelphiVersionList.SortOldestFirst;
var
  I, J: Integer;
begin
  { simple insertion sort: lists are tiny and this avoids comparer API differences }
  for I := 1 to Count - 1 do
  begin
    J := I;
    while (J > 0) and (Items[J - 1].SortKey > Items[J].SortKey) do
    begin
      Exchange(J - 1, J);
      Dec(J);
    end;
  end;
end;

{ TBackupItem }

constructor TBackupItem.Create;
begin
  inherited Create;
  Versions := TStringList.Create;
  Versions.CaseSensitive := False;
  Versions.Duplicates := dupIgnore;
  Versions.Sorted := True;
  Selected := True;
  DllOrigin := doNone;
end;

destructor TBackupItem.Destroy;
begin
  Versions.Free;
  inherited;
end;

function TBackupItem.UsedByVersion(const ABdsVersion: string): Boolean;
begin
  Result := (Versions.Count = 0) or (Versions.IndexOf(ABdsVersion) >= 0);
end;

{ TBackupItemList }

function TBackupItemList.FindById(const AId: string): TBackupItem;
var
  It: TBackupItem;
begin
  Result := nil;
  for It in Self do
    if SameText(It.Id, AId) then
      Exit(It);
end;

function TBackupItemList.FindBySource(AKind: TItemKind;
  const ASourcePath: string): TBackupItem;
var
  It: TBackupItem;
begin
  Result := nil;
  for It in Self do
    if (It.Kind = AKind) and
      SameText(ExcludeTrailingPathDelimiter(It.SourcePath),
      ExcludeTrailingPathDelimiter(ASourcePath)) then
      Exit(It);
end;

function TBackupItemList.NextId(AKind: TItemKind): string;
const
  Prefix: array [TItemKind] of Char = ('f', 'f', 'r', 'd');
var
  N: Integer;
begin
  N := 1;
  repeat
    Result := Format('%s%.3d', [Prefix[AKind], N]);
    Inc(N);
  until FindById(Result) = nil;
end;

{ TManifestItem }

constructor TManifestItem.Create;
begin
  inherited Create;
  Files := TObjectList<TManifestFile>.Create(True);
end;

destructor TManifestItem.Destroy;
begin
  Files.Free;
  Item.Free;
  inherited;
end;

{ TManifest }

constructor TManifest.Create;
begin
  inherited Create;
  FormatVersion := MANIFEST_FORMAT_VERSION;
  ExcludeDirs := TStringList.Create;
  ExcludeFiles := TStringList.Create;
  Versions := TObjectList<TManifestVersion>.Create(True);
  Items := TObjectList<TManifestItem>.Create(True);
end;

destructor TManifest.Destroy;
begin
  ExcludeFiles.Free;
  ExcludeDirs.Free;
  Items.Free;
  Versions.Free;
  inherited;
end;

function TManifest.FindVersion(const ABdsVersion: string): TManifestVersion;
var
  V: TManifestVersion;
begin
  Result := nil;
  for V in Versions do
    if SameText(V.BdsVersion, ABdsVersion) then
      Exit(V);
end;

{ TToolConfig }

constructor TToolConfig.Create;
begin
  inherited Create;
  ExtraFolders := TStringList.Create;
  ExtraRegistryKeys := TStringList.Create;
  ExcludeDirs := TStringList.Create;
  ExcludeFiles := TStringList.Create;
  ExcludeDirs.Add('__history');
  ExcludeDirs.Add('__recovery');
  ExcludeDirs.Add('Samples');
  ExcludeFiles.Add('*.~*');
  { Platform SDKs downloaded into CatalogRepository by the IDE installer/GetIt:
    gigabytes that a reinstall of the IDE brings back. Override in the config file. }
  ExcludeDirs.Add('AndroidNDK-*');
  ExcludeDirs.Add('AndroidSDK-*');
  ExcludeDirs.Add('OpenJDK-*');
  ExcludeDirs.Add('AdoptOpenJDK-*');
end;

destructor TToolConfig.Destroy;
begin
  ExcludeFiles.Free;
  ExcludeDirs.Free;
  ExtraRegistryKeys.Free;
  ExtraFolders.Free;
  inherited;
end;

{ TCompareResult }

constructor TCompareResult.Create;
begin
  inherited Create;
  Entries := TObjectList<TDiffEntry>.Create(True);
end;

destructor TCompareResult.Destroy;
begin
  Entries.Free;
  inherited;
end;

function TCompareResult.HasDifferences: Boolean;
var
  E: TDiffEntry;
begin
  Result := False;
  for E in Entries do
    if E.Kind <> dkInfo then
      Exit(True);
end;

procedure TCompareResult.Add(AKind: TDiffKind;
  const AItemId, APath, ADetail: string);
var
  E: TDiffEntry;
begin
  E := TDiffEntry.Create;
  E.Kind := AKind;
  E.ItemId := AItemId;
  E.Path := APath;
  E.Detail := ADetail;
  Entries.Add(E);
end;

{ helpers }

function VersionsToText(const AVersions: TArray<string>): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AVersions) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + AVersions[I];
  end;
end;

function TextToVersions(const AText: string): TArray<string>;
var
  SL: TStringList;
  I: Integer;
begin
  SL := TStringList.Create;
  try
    SL.Delimiter := ',';
    SL.StrictDelimiter := True;
    SL.DelimitedText := StringReplace(AText, ';', ',', [rfReplaceAll]);
    SetLength(Result, 0);
    for I := 0 to SL.Count - 1 do
      if Trim(SL[I]) <> '' then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Trim(SL[I]);
      end;
  finally
    SL.Free;
  end;
end;

function ContainsText(const AList: TArray<string>;
  const AValue: string): Boolean;
var
  S: string;
begin
  Result := False;
  for S in AList do
    if SameText(S, AValue) then
      Exit(True);
end;

function LogLevelToText(ALevel: TLogLevel): string;
const
  Names: array [TLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
begin
  Result := Names[ALevel];
end;

const
  ItemKindNames: array [TItemKind] of string = ('folder', 'file',
    'registry', 'dll');
  ItemCategoryNames: array [TItemCategory] of string = ('components',
    'ide-config', 'experts', 'boss', 'extra', 'system-dll');

function ItemKindToText(AKind: TItemKind): string;
begin
  Result := ItemKindNames[AKind];
end;

function TextToItemKind(const AText: string): TItemKind;
var
  K: TItemKind;
begin
  for K := Low(TItemKind) to High(TItemKind) do
    if SameText(ItemKindNames[K], AText) then
      Exit(K);
  raise EDelphiBackupError.CreateFmt('Unknown item kind "%s"', [AText]);
end;

function ItemCategoryToText(ACategory: TItemCategory): string;
begin
  Result := ItemCategoryNames[ACategory];
end;

function TextToItemCategory(const AText: string): TItemCategory;
var
  C: TItemCategory;
begin
  for C := Low(TItemCategory) to High(TItemCategory) do
    if SameText(ItemCategoryNames[C], AText) then
      Exit(C);
  raise EDelphiBackupError.CreateFmt('Unknown item category "%s"', [AText]);
end;

function AllCategories: TItemCategories;
begin
  Result := [Low(TItemCategory) .. High(TItemCategory)];
end;

function DefaultBackupCategories: TItemCategories;
begin
  Result := AllCategories - [icSystemDll];
end;

function LegacyDelphiId(const ARegistryVersion: string): string;
begin
  Result := 'D' + ARegistryVersion;
end;

function IsLegacyDelphiId(const AId: string): Boolean;
begin
  Result := (Length(AId) > 1) and CharInSet(AId[1], ['D', 'd']);
end;

function VersionIdNumber(const AId: string): string;
begin
  if IsLegacyDelphiId(AId) then
    Result := Copy(AId, 2, MaxInt)
  else
    Result := AId;
end;

end.
