unit Core.ProcessRunner;

interface

uses Core.Types;

function CreateProcessRunner(const ALogger: ILogger): IProcessRunner;
function Quote(const S: string): string;

implementation

uses
  Core.SystemUtils, Core.Logger,
  System.SysUtils, System.Classes, System.StrUtils, System.Win.Registry,
  Winapi.Windows;

type
  TProcessRunner = class(TInterfacedObject, IProcessRunner)
  private
    FLogger: ILogger;
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
  if FLogger = nil then
    FLogger := CreateLogger;
  FLogger.Debug('Criando executor de processos.');
end;

function Quote(const S: string): string;
var
  Value: string;
begin
  Value := StringReplace(S, '"', '\"', [rfReplaceAll]);
  while (Value <> '') and (Value[Length(Value)] = '\') do
  begin
    { Escape the backslash of a drive root so the child receives C:\. }
    if (Length(Value) = 3) and (Value[2] = ':') then
    begin
      Value := Value + '\';
      Break;
    end;
    SetLength(Value, Length(Value) - 1);
  end;
  Result := '"' + Value + '"';
end;

function TProcessRunner.Run(const AExe, AArgs, AWorkDir: string;
  out AOutput: string): Cardinal;
var
  Exe, SystemExe: string;
begin
  { Windows tools (robocopy, reg, tar) always from the system folder: another
    tar.exe/reg.exe in the app or current folder (e.g. Git's GNU tar, which cannot
    read zip files) must never be picked up. A 32-bit process is redirected to
    SysWOW64, which keeps the 32-bit registry view used by the Delphi keys. }
  Exe := AExe;
  if ExtractFilePath(Exe) = '' then
  begin
    SystemExe := IncludeTrailingPathDelimiter(GetSystem32Dir) + Exe;
    if FileExists(SystemExe) then
      Exe := SystemExe;
  end;
  if Assigned(FLogger) then
    FLogger.Debug('Executando processo: ' + Exe + ' ' + AArgs);
  Result := RunTool(Exe, AArgs, AWorkDir, AOutput);
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
  RawOutput: TBytesStream;
  Encoding: TEncoding;
  WorkDir: PChar;
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
    { an empty string is an invalid directory for CreateProcess (error 123): pass nil }
    WorkDir := nil;
    if AWorkDir <> '' then
      WorkDir := PChar(AWorkDir);
    FillChar(ProcessInfo, SizeOf(ProcessInfo), 0);
    if not CreateProcess(nil, PChar(CommandLine), nil, nil, True,
      CREATE_NO_WINDOW, nil, WorkDir, Startup, ProcessInfo) then
      RaiseLastOSError;
    CloseHandle(WritePipe);
    WritePipe := 0;
    RawOutput := TBytesStream.Create;
    try
      repeat
        if not PeekNamedPipe(ReadPipe, nil, 0, nil, @Available, nil) then
        begin
          if GetLastError = ERROR_BROKEN_PIPE then
            Break;
          RaiseLastOSError;
        end;
        if Available = 0 then
        begin
          { A descendant may still hold the pipe after the child exits. }
          if WaitForSingleObject(ProcessInfo.hProcess, 20) = WAIT_OBJECT_0 then
            Sleep(20);
          Continue;
        end;
        if Available > SizeOf(Buffer) then
          Available := SizeOf(Buffer);
        if not ReadFile(ReadPipe, Buffer[0], Available, ReadCount, nil) then
        begin
          if GetLastError = ERROR_BROKEN_PIPE then
            Break;
          RaiseLastOSError;
        end;
        if ReadCount > 0 then
          RawOutput.WriteBuffer(Buffer[0], ReadCount);
      until False;
      { The child can also close stdout before exiting. }
      if WaitForSingleObject(ProcessInfo.hProcess, INFINITE) <> WAIT_OBJECT_0
      then
        RaiseLastOSError;
      if not GetExitCodeProcess(ProcessInfo.hProcess, Result) then
        RaiseLastOSError;
      { decode once, at the end, so multi-chunk output is never split mid-character }
      Encoding := TEncoding.GetEncoding(GetOEMCP);
      try
        AOutput := Encoding.GetString(RawOutput.Bytes, 0, RawOutput.Size);
      finally
        Encoding.Free;
      end;
    finally
      RawOutput.Free;
      CloseHandle(ProcessInfo.hThread);
      CloseHandle(ProcessInfo.hProcess);
    end;
  finally
    if WritePipe <> 0 then
      CloseHandle(WritePipe);
    CloseHandle(ReadPipe);
  end;
end;

function QuoteCopyExclusion(const AMask: string): string;
var
  C: Char;
  Mask: string;
begin
  Mask := ExcludeTrailingPathDelimiter(AMask);
  if (Trim(Mask) = '') or CharInSet(Mask[1], ['/', '-']) then
    raise EDelphiBackupError.Create('Exclusão de cópia inválida: ' + AMask);
  for C in Mask do
    if CharInSet(C, [#0 .. #31, '"']) then
      raise EDelphiBackupError.Create('Exclusão de cópia inválida.');
  Result := '"' + Mask + '"';
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
      Args := Args + ' ' + QuoteCopyExclusion(AExcludeDirs[I]);
  end;
  if Assigned(AExcludeFiles) and (AExcludeFiles.Count > 0) then
  begin
    Args := Args + ' /XF';
    for I := 0 to AExcludeFiles.Count - 1 do
      Args := Args + ' ' + QuoteCopyExclusion(AExcludeFiles[I]);
  end;
  Code := Run('robocopy.exe', Args, '', Output);
  Result := Code < 8;
  if not Result and Assigned(FLogger) then
    FLogger.Warn('A cópia da pasta falhou: ' + Output);
end;

function TProcessRunner.CopyFile(const ASourceFile, ADestDir: string): Boolean;
var
  Args, Output, NativeDir: string;
  Code: Cardinal;
begin
  NativeDir := RealFileSystemPath(GetSystem32Dir);
  { Sysnative is visible only to WOW64 callers. Keep this I/O in-process so
    an external utility's bitness cannot change which file it accesses. }
  if not SameText(NativeDir, GetSystem32Dir) and
    (IsPathInside(ASourceFile, NativeDir) or IsPathInside(ADestDir, NativeDir))
  then
  begin
    FLogger.Debug('Copiando arquivo pelo acesso nativo: ' + ASourceFile);
    Result := ForceDirectories(ADestDir) and
      Winapi.Windows.CopyFile(PChar(ASourceFile),
      PChar(IncludeTrailingPathDelimiter(ADestDir) +
      ExtractFileName(ASourceFile)), False);
    if Result then
      FLogger.Debug('Arquivo copiado para ' + ADestDir)
    else
      FLogger.Warn('Falha ao copiar arquivo para ' + ADestDir + ': ' +
        SysErrorMessage(GetLastError));
    Exit;
  end;
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
  Args, Output: string;
  Code: Cardinal;
begin
  if not RegKeyExists(AKey) then
  begin
    if Assigned(FLogger) then
      FLogger.Debug('A chave do Registro já não existe: ' + AKey);
    Exit(True);
  end;
  Args := 'delete ' + Quote(AKey) + ' /f';
  if StartsText('HKLM', AKey) then
    Args := Args + ' /reg:32';
  Code := Run('reg.exe', Args, '', Output);
  Result := Code = 0;
  if not Result and Assigned(FLogger) then
    FLogger.Warn('A remoção da chave falhou: ' + Output);
end;

function TProcessRunner.RegKeyExists(const AKey: string): Boolean;
var
  Reg: TRegistry;
  Key: string;
  Root: HKEY;
  Access: LongWord;
begin
  Key := AKey;
  Access := KEY_READ;
  Root := 0;
  if StartsText('HKCU\', Key) then
  begin
    Root := HKEY_CURRENT_USER;
    Delete(Key, 1, 5);
  end
  else if StartsText('HKLM\', Key) then
  begin
    Root := HKEY_LOCAL_MACHINE;
    Access := Access or KEY_WOW64_32KEY;
    Delete(Key, 1, 5);
  end;
  Result := False;
  if Root = 0 then
  begin
    if Assigned(FLogger) then
      FLogger.Warn('Raiz do Registro inválida: ' + AKey);
    Exit;
  end;
  Reg := TRegistry.Create(Access);
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
