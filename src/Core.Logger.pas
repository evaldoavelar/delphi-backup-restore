unit Core.Logger;

interface

uses
  Core.Types;

function CreateLogger: ILogger;

implementation

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections;

type
  TLogger = class(TInterfacedObject, ILogger)
  private
    FLock: TCriticalSection;
    FSinks: TList<TLogSink>;
    FLogFile: string;
    procedure WriteFileLine(const ALine: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Log(ALevel: TLogLevel; const AMessage: string);
    procedure Debug(const AMessage: string);
    procedure Info(const AMessage: string);
    procedure Warn(const AMessage: string);
    procedure Error(const AMessage: string);
    procedure AddSink(const ASink: TLogSink);
    procedure SetLogFile(const AFileName: string);
  end;

function CreateLogger: ILogger;
begin
  Result := TLogger.Create;
end;

constructor TLogger.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSinks := TList<TLogSink>.Create;
end;

destructor TLogger.Destroy;
begin
  FSinks.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TLogger.WriteFileLine(const ALine: string);
var
  Stream: TFileStream;
  Bytes: TBytes;
begin
  if FLogFile = '' then
    Exit;
  Bytes := TEncoding.UTF8.GetBytes(ALine + sLineBreak);
  if FileExists(FLogFile) then
    Stream := TFileStream.Create(FLogFile, fmOpenWrite or fmShareDenyNone)
  else
    Stream := TFileStream.Create(FLogFile, fmCreate or fmShareDenyNone);
  try
    Stream.Seek(0, soEnd);
    if Stream.Size = 0 then
    begin
      Bytes := TEncoding.UTF8.GetPreamble + Bytes;
    end;
    if Length(Bytes) > 0 then
      Stream.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
end;

procedure TLogger.Log(ALevel: TLogLevel; const AMessage: string);
var
  Line: string;
  Sinks: TArray<TLogSink>;
  I: Integer;
begin
  Line := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' [' +
    LogLevelToText(ALevel) + '] ' + AMessage;
  FLock.Acquire;
  try
    WriteFileLine(Line);
    Sinks := FSinks.ToArray;
  finally
    FLock.Release;
  end;
  for I := 0 to High(Sinks) do
    Sinks[I](ALevel, AMessage);
end;

procedure TLogger.Debug(const AMessage: string);
begin
  Log(llDebug, AMessage);
end;

procedure TLogger.Info(const AMessage: string);
begin
  Log(llInfo, AMessage);
end;

procedure TLogger.Warn(const AMessage: string);
begin
  Log(llWarn, AMessage);
end;

procedure TLogger.Error(const AMessage: string);
begin
  Log(llError, AMessage);
end;

procedure TLogger.AddSink(const ASink: TLogSink);
begin
  FLock.Acquire;
  try
    FSinks.Add(ASink);
  finally
    FLock.Release;
  end;
  Log(llDebug, 'Destino de log adicionado.');
end;

procedure TLogger.SetLogFile(const AFileName: string);
begin
  FLock.Acquire;
  try
    FLogFile := AFileName;
  finally
    FLock.Release;
  end;
  if AFileName <> '' then
    Log(llInfo, 'Arquivo de log configurado: ' + AFileName)
  else
    Log(llInfo, 'Gravação em arquivo de log desativada.');
end;

end.
