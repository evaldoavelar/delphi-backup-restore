program DelphiBackupRestore;

{ Entry point. With command line arguments the tool runs in CLI mode (attached to the
  parent console); without arguments it shows the GUI wizard. The manifest and the
  version resources are compiled by build.bat (src\DelphiBackupRestore.rc). }

uses
  Winapi.Windows,
  System.SysUtils,
  Vcl.Forms,
  Core.Types,
  Core.Logger,
  Core.ProcessRunner,
  Core.SystemUtils,
  Core.VersionCatalog,
  Core.VersionDetector,
  Core.PathDiscovery,
  Core.Manifest,
  Core.BackupEngine,
  Core.CompareEngine,
  Core.RestoreEngine,
  Core.DllScanner,
  Cli.Runner,
  UI.MainWizard;

var
  Wizard: TMainWizard;

begin
  if ParamCount > 0 then
  begin
    if not AttachConsole(ATTACH_PARENT_PROCESS) then
      AllocConsole;
    ExitCode := RunCli;
  end
  else
  begin
    Application.Initialize;
    Application.MainFormOnTaskbar := True;
    Application.CreateForm(TMainWizard, Wizard);
    Application.Run;
  end;
end.
