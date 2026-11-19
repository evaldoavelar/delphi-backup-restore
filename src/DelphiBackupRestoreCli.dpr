program DelphiBackupRestoreCli;

{ Console build of the same tool: only the CLI (no GUI), so shells and CI receive
  output and the exit code synchronously. Same commands as DelphiBackupRestore.exe. }

{$APPTYPE CONSOLE}

{$R DelphiBackupRestore.res}

uses
  Winapi.Windows,
  System.SysUtils,
  Core.Types in 'Core.Types.pas',
  Core.Logger in 'Core.Logger.pas',
  Core.ProcessRunner in 'Core.ProcessRunner.pas',
  Core.SystemUtils in 'Core.SystemUtils.pas',
  Core.VersionCatalog in 'Core.VersionCatalog.pas',
  Core.VersionDetector in 'Core.VersionDetector.pas',
  Core.PathDiscovery in 'Core.PathDiscovery.pas',
  Core.Manifest in 'Core.Manifest.pas',
  Core.BackupEngine in 'Core.BackupEngine.pas',
  Core.CompareEngine in 'Core.CompareEngine.pas',
  Core.RestoreEngine in 'Core.RestoreEngine.pas',
  Core.DllScanner in 'Core.DllScanner.pas',
  Cli.Runner in 'Cli.Runner.pas';

begin
  ExitCode := RunCli;
end.
