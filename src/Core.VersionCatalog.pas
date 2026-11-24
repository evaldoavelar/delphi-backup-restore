unit Core.VersionCatalog;

interface

uses Core.Types;

function ProductNameForVersion(AEra: TDelphiEra;
  const ABdsVersion: string): string;
function RegistryRootForEra(AEra: TDelphiEra): string;
function RegistrySoftwareKey(const AKey: string): string;
function DelphiRegistryVersion(const AKey: string): string;
function IsInstallerKey(const AKey: string): Boolean;
{ Folder under Documents / Public Documents used by the IDE:
  2005/2006 'Borland Studio Projects', 2007..XE5 'RAD Studio',
  XE6 (BDS 14.0) and later 'Embarcadero\Studio'. Delphi 5..7 have none (''). }
function StudioFolderName(AEra: TDelphiEra;
  const ABdsVersion: string = ''): string;

implementation

uses System.SysUtils, System.StrUtils;

function ProductNameForVersion(AEra: TDelphiEra;
  const ABdsVersion: string): string;
var
  Name: string;
begin
  Name := '';
  if AEra = deBorlandDelphi then
  begin
    if ABdsVersion = '5.0' then
      Name := 'Delphi 5'
    else if ABdsVersion = '6.0' then
      Name := 'Delphi 6'
    else if ABdsVersion = '7.0' then
      Name := 'Delphi 7';
  end
  else if AEra = deBorlandBDS then
  begin
    if ABdsVersion = '3.0' then
      Name := 'Delphi 2005'
    else if ABdsVersion = '4.0' then
      Name := 'Delphi 2006'
    else if ABdsVersion = '5.0' then
      Name := 'Delphi 2007';
  end
  else if AEra = deCodeGear then
  begin
    if ABdsVersion = '6.0' then
      Name := 'Delphi 2009'
    else if ABdsVersion = '7.0' then
      Name := 'Delphi 2010';
  end
  else
  begin
    if ABdsVersion = '8.0' then
      Name := 'Delphi XE'
    else if ABdsVersion = '9.0' then
      Name := 'Delphi XE2'
    else if ABdsVersion = '10.0' then
      Name := 'Delphi XE3'
    else if ABdsVersion = '11.0' then
      Name := 'Delphi XE4'
    else if ABdsVersion = '12.0' then
      Name := 'Delphi XE5'
    else if ABdsVersion = '14.0' then
      Name := 'Delphi XE6'
    else if ABdsVersion = '15.0' then
      Name := 'Delphi XE7'
    else if ABdsVersion = '16.0' then
      Name := 'Delphi XE8'
    else if ABdsVersion = '17.0' then
      Name := 'Delphi 10 Seattle'
    else if ABdsVersion = '18.0' then
      Name := 'Delphi 10.1 Berlin'
    else if ABdsVersion = '19.0' then
      Name := 'Delphi 10.2 Tokyo'
    else if ABdsVersion = '20.0' then
      Name := 'Delphi 10.3 Rio'
    else if ABdsVersion = '21.0' then
      Name := 'Delphi 10.4 Sydney'
    else if ABdsVersion = '22.0' then
      Name := 'Delphi 11 Alexandria'
    else if ABdsVersion = '23.0' then
      Name := 'Delphi 12 Athens'
    else if ABdsVersion = '37.0' then
      Name := 'Delphi 13 Florence';
  end;
  if Name <> '' then
    Result := Name
  else
    Result := Format('Delphi (BDS %s)', [ABdsVersion]);
end;

function RegistryRootForEra(AEra: TDelphiEra): string;
begin
  case AEra of
    deBorlandDelphi:
      Result := 'Software\Borland\Delphi';
    deBorlandBDS:
      Result := 'Software\Borland\BDS';
    deCodeGear:
      Result := 'Software\CodeGear\BDS';
  else
    Result := 'Software\Embarcadero\BDS';
  end;
end;

function StudioFolderName(AEra: TDelphiEra;
  const ABdsVersion: string = ''): string;
var
  Major: Integer;
begin
  Major := StrToIntDef(Copy(ABdsVersion, 1, Pos('.', ABdsVersion + '.')
    - 1), 0);
  case AEra of
    deBorlandDelphi:
      Result := '';
    deBorlandBDS:
      if (Major > 0) and (Major < 5) then
        Result := 'Borland Studio Projects'
      else
        Result := 'RAD Studio';
    deCodeGear:
      Result := 'RAD Studio';
  else
    if (Major > 0) and (Major < 14) then
      Result := 'RAD Studio'
    else
      Result := 'Embarcadero\Studio';
  end;
end;

function IsVersionNumber(const S: string): Boolean;
var
  P, I: Integer;
begin
  Result := False;
  P := Pos('.', S);
  if (P <= 1) or (P >= Length(S)) then
    Exit;
  for I := 1 to Length(S) do
    if (I <> P) and not CharInSet(S[I], ['0' .. '9']) then
      Exit;
  Result := True;
end;

function RegistrySoftwareKey(const AKey: string): string;
begin
  Result := AKey;
  if StartsText('HKCU\Software\', AKey) or StartsText('HKLM\Software\', AKey)
  then
    if StartsText('WOW6432Node\', Copy(AKey, Length('HKCU\Software\') + 1,
      MaxInt)) then
      Delete(Result, Length('HKCU\Software\') + 1, Length('WOW6432Node\'));
end;

function DelphiRegistryVersion(const AKey: string): string;
var
  Key, Root, Version: string;
  Era: TDelphiEra;
  P: Integer;
begin
  Result := '';
  Key := RegistrySoftwareKey(AKey);
  for Era := Low(TDelphiEra) to High(TDelphiEra) do
  begin
    Root := Copy(Key, 1, 5) + RegistryRootForEra(Era) + '\';
    if not StartsText(Root, Key) then
      Continue;
    Version := Copy(Key, Length(Root) + 1, MaxInt);
    P := Pos('\', Version);
    if P > 0 then
      SetLength(Version, P - 1);
    if IsVersionNumber(Version) then
    begin
      if Era = deBorlandDelphi then
        Version := LegacyDelphiId(Version);
      Exit(Version);
    end;
  end;
end;

function IsInstallerKey(const AKey: string): Boolean;
begin
  Result := StartsText('HKLM\', AKey) and (DelphiRegistryVersion(AKey) <> '');
end;

end.
