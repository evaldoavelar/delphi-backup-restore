unit Core.ToolConfig;

interface

uses Core.Types;

function LoadToolConfig(const AFileName: string; AConfig: TToolConfig;
  const ALogger: ILogger): Boolean;

implementation

uses System.JSON, System.SysUtils, System.IOUtils, Core.PathDiscovery;

function LoadToolConfig(const AFileName: string; AConfig: TToolConfig;
  const ALogger: ILogger): Boolean;
var
  Config, Value: TJSONValue;
begin
  ALogger.Debug('Carregando opções de compactação: ' + AFileName);
  Result := Core.PathDiscovery.LoadToolConfig(AFileName, AConfig, ALogger);
  if not Result then
    Exit;
  try
    Config := TJSONObject.ParseJSONValue(TFile.ReadAllText(AFileName,
      TEncoding.UTF8));
    try
      if not(Config is TJSONObject) then
        raise EDelphiBackupError.Create('Configuração JSON inválida.');
      Value := TJSONObject(Config).Values['zipStore'];
      if (Value <> nil) and not((Value is TJSONTrue) or (Value is TJSONFalse))
      then
        raise EDelphiBackupError.Create
          ('A opção zipStore deve ser true ou false.');
      AConfig.ZipStore := Value is TJSONTrue;
      ALogger.Debug('Modo ZIP sem compressão: ' +
        BoolToStr(AConfig.ZipStore, True));
    finally
      Config.Free;
    end;
  except
    on E: Exception do
    begin
      ALogger.Error('Erro ao carregar opções de compactação: ' + E.Message);
      raise;
    end;
  end;
end;

end.
