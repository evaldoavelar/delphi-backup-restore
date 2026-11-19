unit Core.VersionCatalog;

interface

uses Core.Types;

function ProductNameForVersion(AEra: TDelphiEra;
  const ABdsVersion: string): string;
function RegistryRootForEra(AEra: TDelphiEra): string;
function StudioFolderName(AEra: TDelphiEra): string;

implementation

uses System.SysUtils;

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

function StudioFolderName(AEra: TDelphiEra): string;
begin
  case AEra of
    deBorlandDelphi:
      Result := 'Borland Studio Projects';
    deBorlandBDS:
      Result := 'RAD Studio';
  else
    Result := 'Embarcadero\Studio';
  end;
end;

end.
