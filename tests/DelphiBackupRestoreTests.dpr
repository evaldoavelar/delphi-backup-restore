program DelphiBackupRestoreTests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
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
  Tests.Core.Hardening in 'Tests.Core.Hardening.pas';

var
  Runner: ITestRunner;
  Results: IRunResults;
  Logger: ITestLogger;
  NUnitLogger: ITestLogger;

begin
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
