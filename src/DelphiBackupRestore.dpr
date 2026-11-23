program DelphiBackupRestore;

{ Entry point. With command line arguments the tool runs in CLI mode (attached to the
  parent console); without arguments it shows the GUI wizard. The manifest and the
  version resources are compiled by build.bat (src\VersionInfo.rc -> DelphiBackupRestore.res).
  For a console build with reliable exit codes use DelphiBackupRestoreCli.dpr. }

{$R DelphiBackupRestore.res}

uses
  Winapi.Windows,
  System.SysUtils,
  Vcl.Forms,
  Core.Types in 'Core.Types.pas',
  Core.Logger in 'Core.Logger.pas',
  Core.ProcessRunner in 'Core.ProcessRunner.pas',
  Core.SystemUtils in 'Core.SystemUtils.pas',
  Core.VersionCatalog in 'Core.VersionCatalog.pas',
  Core.VersionDetector in 'Core.VersionDetector.pas',
  Core.PathDiscovery in 'Core.PathDiscovery.pas',
  Core.Hash in 'Core.Hash.pas',
  Core.Manifest in 'Core.Manifest.pas',
  Core.BackupEngine in 'Core.BackupEngine.pas',
  Core.CompareEngine in 'Core.CompareEngine.pas',
  Core.RestoreEngine in 'Core.RestoreEngine.pas',
  Core.DllScanner in 'Core.DllScanner.pas',
  Cli.Runner in 'Cli.Runner.pas',
  UI.MainWizard in 'UI.MainWizard.pas';

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
