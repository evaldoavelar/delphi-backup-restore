unit Core.ProcessRunner;

interface

uses Core.Types;

function CreateProcessRunner(const ALogger: ILogger): IProcessRunner;

implementation

uses
  System.SysUtils, System.Classes, System.StrUtils, System.Win.Registry,
  Winapi.Windows;

type
  TProcessRunner = class(TInterfacedObject, IProcessRunner)
  private
    FLogger: ILogger;
    function Quote(const S: string): string;
    function RunTool(const AExe, AArgs, AWorkDir: string; out AOutput: string)
      : Cardinal;
  public
    constructor Create(const ALogger: ILogger);
    function Run(const AExe, AArgs, AWorkDir: string; out AOutput: string)
      : Cardinal;
    function CopyTree(const ASource, ADest: string; AMirror: Boolean;
      AExcludeDirs, AExcludeFiles: TStrings): Boolean;
    function CopyFile(const ASourceFile, ADestDir: string): Boolean;
    function RegExport(const AKey, AFileName: string): Boolean;
    function RegImport(const AFileName: string; AHklm32: Boolean): Boolean;
    function RegDelete(const AKey: string): Boolean;
    function RegKeyExists(const AKey: string): Boolean;
    function ZipFolder(const AFolder, AZipFile: string): Boolean;
    function UnzipTo(const AZipFile, ADestFolder: string): Boolean;
  end;

function CreateProcessRunner(const ALogger: ILogger): IProcessRunner;
begin
  Result := TProcessRunner.Create(ALogger);
end;

constructor TProcessRunner.Create(const ALogger: ILogger);
begin
  inherited Create;
  FLogger := ALogger;
end;

function TProcessRunner.Quote(const S: string): string;
begin
  Result := '"' + StringReplace(S, '"', '\"', [rfReplaceAll]) + '"';
end;

function TProcessRunner.Run(const AExe, AArgs, AWorkDir: string;
  out AOutput: string): Cardinal;
begin
  if Assigned(FLogger) then
    FLogger.Debug('Executando processo: ' + AExe + ' ' + AArgs);
  Result := RunTool(AExe, AArgs, AWorkDir, AOutput);
  if Assigned(FLogger) then
    FLogger.Debug(Format('Processo finalizado com código %d', [Result]));
end;

function TProcessRunner.RunTool(const AExe, AArgs, AWorkDir: string;
  out AOutput: string): Cardinal;
var
  Security: TSecurityAttributes;
  ReadPipe, WritePipe: THandle;
  Startup: TStartupInfo;
  ProcessInfo: TProcessInformation;
  CommandLine: string;
  Buffer: array [0 .. 8191] of Byte;
  ReadCount, Available: DWORD;
  Bytes: TBytes;
begin
  AOutput := '';
  FillChar(Security, SizeOf(Security), 0);
  Security.nLength := SizeOf(Security);
  Security.bInheritHandle := True;
  ReadPipe := 0;
  WritePipe := 0;
  if not CreatePipe(ReadPipe, WritePipe, @Security, 0) then
    RaiseLastOSError;
  try
    if not SetHandleInformation(ReadPipe, HANDLE_FLAG_INHERIT, 0) then
      RaiseLastOSError;
    FillChar(Startup, SizeOf(Startup), 0);
    Startup.cb := SizeOf(Startup);
    Startup.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    Startup.wShowWindow := SW_HIDE;
    Startup.hStdOutput := WritePipe;
    Startup.hStdError := WritePipe;
    Startup.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
    CommandLine := Quote(AExe);
    if AArgs <> '' then
      CommandLine := CommandLine + ' ' + AArgs;
    UniqueString(CommandLine);
    FillChar(ProcessInfo, SizeOf(ProcessInfo), 0);
    if not CreateProcess(nil, PChar(CommandLine), nil, nil, True,
      CREATE_NO_WINDOW, nil, PChar(AWorkDir), Startup, ProcessInfo) then
      RaiseLastOSError;
    CloseHandle(WritePipe);
    WritePipe := 0;
    try
      repeat
        if not PeekNamedPipe(ReadPipe, nil, 0, nil, @Available, nil) then
        begin
          if GetLastError <> ERROR_BROKEN_PIPE then
            RaiseLastOSError;
          Available := 0;
        end;
        if Available > 0 then
        begin
          if Available > SizeOf(Buffer) then
            Available := SizeOf(Buffer);
          if ReadFile(ReadPipe, Buffer[0], Available, ReadCount, nil) and
            (ReadCount > 0) then
          begin
            SetLength(Bytes, ReadCount);
            Move(Buffer[0], Bytes[0], ReadCount);
            AOutput := AOutput + TEncoding.GetEncoding(GetOEMCP)
              .GetString(Bytes);
          end;
        end
        else
          WaitForSingleObject(ProcessInfo.hProcess, 20);
      until (Available = 0) and (WaitForSingleObject(ProcessInfo.hProcess, 0)
        = WAIT_OBJECT_0);
      while ReadFile(ReadPipe, Buffer[0], SizeOf(Buffer), ReadCount, nil) and
        (ReadCount > 0) do
      begin
        SetLength(Bytes, ReadCount);
        Move(Buffer[0], Bytes[0], ReadCount);
        AOutput := AOutput + TEncoding.GetEncoding(GetOEMCP).GetString(Bytes);
      end;
      if not GetExitCodeProcess(ProcessInfo.hProcess, Result) then
        RaiseLastOSError;
    finally
      CloseHandle(ProcessInfo.hThread);
      CloseHandle(ProcessInfo.hProcess);
    end;
  finally
    if WritePipe <> 0 then
      CloseHandle(WritePipe);
    CloseHandle(ReadPipe);
  end;
end;

function TProcessRunner.CopyTree(const ASource, ADest: string; AMirror: Boolean;
  AExcludeDirs, AExcludeFiles: TStrings): Boolean;
var
  Args, Output, Mode: string;
  I: Integer;
  Code: Cardinal;
begin
  Mode := '/E';
  if AMirror then
    Mode := '/MIR';
  Args := Quote(ASource) + ' ' + Quote(ADest) + ' ' + Mode +
    ' /COPY:DAT /DCOPY:T /R:1 /W:1 /MT:16 /NP /NFL /NDL /XJ';
  if Assigned(AExcludeDirs) and (AExcludeDirs.Count > 0) then
  begin
    Args := Args + ' /XD';
    for I := 0 to AExcludeDirs.Count - 1 do
      Args := Args + ' ' + Quote(AExcludeDirs[I]);
  end;
  if Assigned(AExcludeFiles) and (AExcludeFiles.Count > 0) then
  begin
    Args := Args + ' /XF';
    for I := 0 to AExcludeFiles.Count - 1 do
      Args := Args + ' ' + Quote(AExcludeFiles[I]);
  end;
  Code := Run('robocopy.exe', Args, '', Output);
  Result := Code < 8;
  if not Result and Assigned(FLogger) then
    FLogger.Warn('A cópia da pasta falhou: ' + Output);
end;

function TProcessRunner.CopyFile(const ASourceFile, ADestDir: string): Boolean;
var
  Args, Output: string;
  Code: Cardinal;
begin
  Args := Quote(ExtractFilePath(ASourceFile)) + ' ' + Quote(ADestDir) + ' ' +
    Quote(ExtractFileName(ASourceFile)) + ' /COPY:DAT /R:1 /W:1';
  Code := Run('robocopy.exe', Args, '', Output);
  Result := Code < 8;
  if not Result and Assigned(FLogger) then
    FLogger.Warn('A cópia do arquivo falhou: ' + Output);
end;

function TProcessRunner.RegExport(const AKey, AFileName: string): Boolean;
var
  Args, Output, Key: string;
  Code: Cardinal;
begin
  Key := AKey;
  Args := 'export ' + Quote(Key) + ' ' + Quote(AFileName) + ' /y';
  if StartsText('HKLM\', Key) then
    Args := Args + ' /reg:32';
  Code := Run('reg.exe', Args, '', Output);
  Result := Code = 0;
  if not Result and Assigned(FLogger) then
    FLogger.Warn('A exportação do registro falhou: ' + Output);
end;

function TProcessRunner.RegImport(const AFileName: string;
  AHklm32: Boolean): Boolean;
var
  Args, Output: string;
  Code: Cardinal;
begin
  Args := 'import ' + Quote(AFileName);
  if AHklm32 then
    Args := Args + ' /reg:32';
  Code := Run('reg.exe', Args, '', Output);
  Result := Code = 0;
  if not Result and Assigned(FLogger) then
    FLogger.Warn('A importação do registro falhou: ' + Output);
end;

function TProcessRunner.RegDelete(const AKey: string): Boolean;
var
  Output: string;
  Code: Cardinal;
begin
  if not RegKeyExists(AKey) then
  begin
    if Assigned(FLogger) then
      FLogger.Debug('A chave do Registro já não existe: ' + AKey);
    Exit(True);
  end;
  Code := Run('reg.exe', 'delete ' + Quote(AKey) + ' /f', '', Output);
  Result := Code = 0;
  if not Result and Assigned(FLogger) then
    FLogger.Warn('A remoção da chave falhou: ' + Output);
end;

function TProcessRunner.RegKeyExists(const AKey: string): Boolean;
var
  Reg: TRegistry;
  Key: string;
  Root: HKEY;
begin
  Key := AKey;
  Root := 0;
  if StartsText('HKCU\', Key) then
  begin
    Root := HKEY_CURRENT_USER;
    Delete(Key, 1, 5);
  end
  else if StartsText('HKLM\', Key) then
  begin
    Root := HKEY_LOCAL_MACHINE;
    Delete(Key, 1, 5);
  end;
  Result := False;
  if Root = 0 then
  begin
    if Assigned(FLogger) then
      FLogger.Warn('Raiz do Registro inválida: ' + AKey);
    Exit;
  end;
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := Root;
    Result := Reg.OpenKeyReadOnly(Key);
    if Result then
      Reg.CloseKey;
  finally
    Reg.Free;
  end;
  if Assigned(FLogger) then
    FLogger.Debug('Consulta da chave do Registro concluída: ' + AKey +
      ' (existe: ' + BoolToStr(Result, True) + ').');
end;

function TProcessRunner.ZipFolder(const AFolder, AZipFile: string): Boolean;
var
  Parent, Name, Output: string;
  Code: Cardinal;
begin
  Parent := ExtractFilePath(ExcludeTrailingPathDelimiter(AFolder));
  Name := ExtractFileName(ExcludeTrailingPathDelimiter(AFolder));
  Code := Run('tar.exe', '-a -c -f ' + Quote(AZipFile) + ' -C ' + Quote(Parent)
    + ' ' + Quote(Name), '', Output);
  Result := Code = 0;
  if not Result and Assigned(FLogger) then
    FLogger.Warn('A criação do arquivo ZIP falhou: ' + Output);
end;

function TProcessRunner.UnzipTo(const AZipFile, ADestFolder: string): Boolean;
var
  Output: string;
  Code: Cardinal;
begin
  Code := Run('tar.exe', '-x -f ' + Quote(AZipFile) + ' -C ' +
    Quote(ADestFolder), '', Output);
  Result := Code = 0;
  if not Result and Assigned(FLogger) then
    FLogger.Warn('A extração do arquivo falhou: ' + Output);
end;

end.
