program DelphiBackupRestoreTests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Winapi.Windows,
  DUnitX.TestFramework,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  Tests.Core.Types in 'Tests.Core.Types.pas',
  Tests.Core.VersionCatalog in 'Tests.Core.VersionCatalog.pas',
  Tests.Core.PathDiscovery in 'Tests.Core.PathDiscovery.pas',
  Tests.Core.SystemUtils in 'Tests.Core.SystemUtils.pas',
  Tests.Core.RestoreEngine in 'Tests.Core.RestoreEngine.pas',
  Tests.Core.RestoreSafety in 'Tests.Core.RestoreSafety.pas',
  Tests.Core.Manifest in 'Tests.Core.Manifest.pas',
  Tests.Core.CompareEngine in 'Tests.Core.CompareEngine.pas',
  Tests.Core.Safety in 'Tests.Core.Safety.pas',
  Tests.Core.Hardening in 'Tests.Core.Hardening.pas',
  Tests.Core.Round3 in 'Tests.Core.Round3.pas',
  Tests.Core.Zip in 'Tests.Core.Zip.pas';

var
  Runner: ITestRunner;
  Results: IRunResults;
  Logger: ITestLogger;
  NUnitLogger: ITestLogger;

procedure WriteZipPipeFrames;
const
  FirstChunk: array [0 .. 4] of Byte = (51, 55, 37, 13, $61);
  SecondChunk: array [0 .. 0] of Byte = ($C3);
  LastChunk: array [0 .. 12] of Byte = ($A7, $C3, $A3, $6F, 13, 10, $C3, $BA,
    $6C, $74, $69, $6D, $61);
var
  Output: THandle;
  Written: DWORD;
  Started: UInt64;
begin
  Output := GetStdHandle(STD_OUTPUT_HANDLE);
  WriteFile(Output, FirstChunk, SizeOf(FirstChunk), Written, nil);
  WriteFile(Output, SecondChunk, SizeOf(SecondChunk), Written, nil);
  Started := GetTickCount64;
  while not FileExists('pipe-ready') do
  begin
    if GetTickCount64 - Started >= 5000 then
    begin
      ExitCode := 1;
      Exit;
    end;
    Sleep(20);
  end;
  WriteFile(Output, LastChunk, SizeOf(LastChunk), Written, nil);
end;

begin
  if (ParamCount = 1) and (ParamStr(1) = '--zip-pipe-child') then
  begin
    WriteZipPipeFrames;
    Exit;
  end;
  if (ParamCount = 1) and (ParamStr(1) = '--round3-pipe-child') then
  begin
    Sleep(250);
    Writeln('grandchild output');
    Exit;
  end;
  try
    TDUnitX.CheckCommandLine;
    Runner := TDUnitX.CreateRunner;
    Runner.UseRTTI := True;

    Logger := TDUnitXConsoleLogger.Create(True);
    Runner.AddLogger(Logger);

    NUnitLogger := TDUnitXXMLNUnitFileLogger.Create
      (TDUnitX.Options.XMLOutputFile);
    Runner.AddLogger(NUnitLogger);

    Results := Runner.Execute;
    if not Results.AllPassed then
      System.ExitCode := Results.FailureCount + Results.ErrorCount
    else
      System.ExitCode := 0;
  except
    on E: Exception do
    begin
      System.Writeln(E.ClassName, ': ', E.Message);
      System.ExitCode := 1;
    end;
  end;

end.
