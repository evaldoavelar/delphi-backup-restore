unit UI.MainWizard;

{ GUI wizard (no DFM, everything built in code).
  Backup : Modo -> Versoes -> Itens -> Destino -> Execucao
  Restore: Modo -> Origem -> Versoes -> Itens (categorias) -> Execucao
  Compare: Modo -> Origem -> Versoes -> Execucao
  Long running work runs in a TThread subclass; log lines and progress are
  marshalled to the UI thread with TThread.Queue. }

interface

uses
  Winapi.Windows, Winapi.Messages, Winapi.ShellAPI, System.SysUtils,
  System.Classes, System.SyncObjs,
  System.Generics.Collections,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,
  Vcl.CheckLst, Vcl.Dialogs,
  Vcl.Graphics, Core.Types, Core.RestoreEngine;

type
  TWizMode = (wmBackup, wmRestore, wmCompare);
  TWizPage = (wpMode, wpVersions, wpItems, wpPath, wpRun);

  TWorkDone = reference to procedure(const AError: string; APrecheck: Boolean);

  TWizardWorker = class(TThread)
  private
    FWork: TProc;
    FDone: TWorkDone;
  protected
    procedure Execute; override;
  public
    constructor Create(const AWork: TProc; const ADone: TWorkDone);
  end;

  TMainWizard = class(TForm)
  private
    FLogger: ILogger;
    FRunner: IProcessRunner;
    FConfig: TToolConfig;
    FInstalled: TDelphiVersionList;
    FItems: TBackupItemList;
    FItemsKey: string;
    FSelected: TDelphiVersionList; // non-owning, backup only
    FSelBds: TArray<string>;
    FRestore: TRestoreEngine;
    FRestoreSource: string;
    FMode: TWizMode;
    FPage: TWizPage;
    FBusy: Boolean;
    FClosing: Boolean;
    FOpeningSource: Boolean;
    FCloseAfterOpen: Boolean;
    FOpenCancel: TEvent;
    FDllsScanned: Boolean;
    FDestText: string;
    FSourceText: string;
    FVersionIds: TStringList;

    FHeader: TPanel;
    FTitle: TLabel;
    FSubtitle: TLabel;
    FBottom: TPanel;
    FBtnBack: TButton;
    FBtnNext: TButton;
    FBtnClose: TButton;
    FPanels: array [TWizPage] of TPanel;

    FRgMode: TRadioGroup;
    FLblAdmin: TLabel;
    FPnlElevate: TPanel;
    FBtnElevate: TButton;
    FLblVersions: TLabel;
    FLstVersions: TCheckListBox;
    FLblItems: TLabel;
    FLstItems: TCheckListBox;
    FChkDlls: TCheckBox;
    FLblPath: TLabel;
    FEdtPath: TEdit;
    FBtnBrowse: TButton;
    FBtnBrowseZip: TButton;
    FLblOpenStatus: TLabel;
    FOpenProgress: TProgressBar;
    FChkZip: TCheckBox;
    FChkZipStore: TCheckBox;
    FChkKeepFolder: TCheckBox;
    FMemo: TMemo;
    FProgress: TProgressBar;
    FLblStatus: TLabel;

    function S(AValue: Integer): Integer;
    procedure BuildUI;
    function NewPanel: TPanel;
    function NewLabel(AParent: TWinControl; const ACaption: string): TLabel;
    function NewButton(AParent: TWinControl; const ACaption: string;
      AWidth: Integer; AClick: TNotifyEvent): TButton;
    function NewToolbar(AParent: TWinControl;
      AMarkAll, AMarkNone: TNotifyEvent): TPanel;
    procedure BuildModePage;
    procedure BuildVersionsPage;
    procedure BuildItemsPage;
    procedure BuildPathPage;
    procedure BuildRunPage;

    procedure ShowPage(APage: TWizPage);
    function NextPageOf(APage: TWizPage): TWizPage;
    function PrevPageOf(APage: TWizPage): TWizPage;
    procedure UpdateButtons;
    procedure SetBusy(ABusy: Boolean);
    procedure ZipCheckClick(Sender: TObject);
    procedure AppendLog(const AText: string);
    procedure ResetSession;

    procedure FillVersions;
    procedure FillCategories;
    procedure RebuildItemList;
    procedure SyncSelection;
    procedure LoadItemsAsync;
    procedure ScanDllsAsync;
    procedure SetupPathPage;
    procedure SavePathText;
    function ValidateAndLeave(APage: TWizPage): Boolean;
    function OpenSource: Boolean;
    function OpenCancelled: Boolean;
    procedure ShowOpenProgress(ACurrent, ATotal: Integer;
      const AStatus: string);
    procedure QueueOpenProgress(ACurrent, ATotal: Integer;
      const AStatus: string);
    procedure FinishClosingSource(const AError: string; APrecheck: Boolean);
    function CheckedCount(AList: TCheckListBox): Integer;
    function SelectedCategories: TItemCategories;
    function RestoreCategoryOf(AIndex: Integer): TItemCategory;

    procedure StartRun;
    procedure StartBackup;
    procedure StartRestore;
    procedure StartCompare;
    procedure RunDone(const AError: string; APrecheck: Boolean;
      const ASuccessText: string);
    procedure QueueProgress(ACurrent, ATotal: Integer; const AStatus: string);
    procedure OnProgress(ACurrent, ATotal: Integer; const AStep: string);

    procedure BackClick(Sender: TObject);
    procedure NextClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure ModeClick(Sender: TObject);
    procedure ElevateClick(Sender: TObject);
    procedure MarkAllVersions(Sender: TObject);
    procedure MarkNoVersions(Sender: TObject);
    procedure MarkAllItems(Sender: TObject);
    procedure MarkNoItems(Sender: TObject);
    procedure DllsClick(Sender: TObject);
    procedure BrowseFolderClick(Sender: TObject);
    procedure BrowseZipClick(Sender: TObject);
    procedure WizardCloseQuery(Sender: TObject; var CanClose: Boolean);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

implementation

uses
  Core.Logger, Core.ProcessRunner, Core.SystemUtils, Core.VersionDetector,
  System.UITypes, Core.PathDiscovery, Core.BackupEngine, Core.CompareEngine,
  Core.DllScanner, Core.ToolConfig;

const
  CategoryLabels: array [TItemCategory] of string = ('Componentes de terceiros',
    'Configuração da IDE (registro e pastas)', 'Experts e plugins',
    'Boss (pacotes)', 'Extras (arquivo de configuração)',
    'DLLs de terceiros do sistema');

  PageTitles: array [TWizPage] of string = ('O que você deseja fazer?',
    'Versões do Delphi', 'Itens', 'Caminho', 'Execução');

  { TWizardWorker }

constructor TWizardWorker.Create(const AWork: TProc; const ADone: TWorkDone);
begin
  FWork := AWork;
  FDone := ADone;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TWizardWorker.Execute;
var
  Err: string;
  Pre: Boolean;
  Done: TWorkDone;
begin
  Err := '';
  Pre := False;
  try
    FWork();
  except
    on E: EPrecheckError do
    begin
      Err := E.Message;
      Pre := True;
    end;
    on E: Exception do
      Err := E.ClassName + ': ' + E.Message;
  end;
  Done := FDone;
  TThread.Queue(nil, procedure
    begin
      Done(Err, Pre);
    end);
end;

{ TMainWizard }

procedure TMainWizard.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  { Top-level window with its own taskbar button: the form is built in code
    (no DFM) and would otherwise be owned by the hidden TApplication window. }
  Params.WndParent := 0;
  Params.ExStyle := Params.ExStyle or WS_EX_APPWINDOW;
end;

constructor TMainWizard.Create(AOwner: TComponent);
var
  CfgFile: string;
begin
  inherited CreateNew(AOwner);
  FOpenCancel := TEvent.Create(nil, True, False, '');
  FLogger := CreateLogger;
  FRunner := CreateProcessRunner(FLogger);
  FConfig := TToolConfig.Create;
  FInstalled := TDelphiVersionList.Create(True);
  FItems := TBackupItemList.Create(True);
  FSelected := TDelphiVersionList.Create(False);
  FVersionIds := TStringList.Create;
  FMode := wmBackup;
  FPage := wpMode;

  FLogger.AddSink(procedure(ALevel: TLogLevel; const AMessage: string)
    var
      Prefix: string;
    begin
      if ALevel = llDebug then
        Exit;
      Prefix := '';
      if ALevel = llWarn then
        Prefix := 'AVISO: '
      else if ALevel = llError then
        Prefix := 'ERRO: ';
      AppendLog(Prefix + AMessage);
    end);

  CfgFile := ExtractFilePath(ParamStr(0)) + CONFIG_FILE_NAME;
  if FileExists(CfgFile) then
    Core.ToolConfig.LoadToolConfig(CfgFile, FConfig, FLogger);

  Caption := 'Delphi Backup & Restore ' + ToolVersion;
  BorderStyle := bsSingle;
  BorderIcons := [biSystemMenu, biMinimize];
  Position := poScreenCenter;
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  ClientWidth := S(780);
  ClientHeight := S(560);
  if Width > Screen.WorkAreaWidth then
    Width := Screen.WorkAreaWidth;
  if Height > Screen.WorkAreaHeight then
    Height := Screen.WorkAreaHeight;
  OnCloseQuery := WizardCloseQuery;
  BuildUI;
  { after BuildUI: detection logs go to the memo }
  CreateVersionDetector(FLogger).Detect(FInstalled);
  ShowPage(wpMode);
end;

destructor TMainWizard.Destroy;
begin
  FClosing := True;
  FRestore.Free;
  FOpenCancel.Free;
  FVersionIds.Free;
  FSelected.Free;
  FItems.Free;
  FInstalled.Free;
  FConfig.Free;
  inherited;
end;

{ ------------------------------------------------------------ UI building }

function TMainWizard.NewPanel: TPanel;
begin
  Result := TPanel.Create(Self);
  Result.Parent := Self;
  Result.Align := alClient;
  Result.BevelOuter := bvNone;
  Result.Caption := '';
  Result.Visible := False;
end;

function TMainWizard.S(AValue: Integer): Integer;
begin
  Result := MulDiv(AValue, Screen.PixelsPerInch, 96);
end;

function TMainWizard.NewLabel(AParent: TWinControl;
const ACaption: string): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := AParent;
  Result.Align := alTop;
  Result.WordWrap := True;
  Result.AutoSize := True;
  Result.AlignWithMargins := True;
  Result.Margins.Bottom := S(6);
  Result.Caption := ACaption;
end;

function TMainWizard.NewButton(AParent: TWinControl; const ACaption: string;
AWidth: Integer; AClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Width := S(AWidth);
  Result.Height := S(28);
  Result.OnClick := AClick;
end;

function TMainWizard.NewToolbar(AParent: TWinControl;
AMarkAll, AMarkNone: TNotifyEvent): TPanel;
var
  B: TButton;
begin
  Result := TPanel.Create(Self);
  Result.Parent := AParent;
  Result.Align := alBottom;
  Result.Height := S(34);
  Result.BevelOuter := bvNone;
  Result.Caption := '';
  B := NewButton(Result, 'Marcar todos', 110, AMarkAll);
  B.SetBounds(0, S(4), S(110), S(28));
  B := NewButton(Result, 'Desmarcar todos', 120, AMarkNone);
  B.SetBounds(S(118), S(4), S(120), S(28));
end;

procedure TMainWizard.BuildUI;
var
  P: TWizPage;
  Line: TBevel;
begin
  FHeader := TPanel.Create(Self);
  FHeader.Parent := Self;
  FHeader.Align := alTop;
  FHeader.Height := S(56);
  FHeader.BevelOuter := bvNone;
  FHeader.Caption := '';
  FHeader.Color := clWhite;
  FHeader.ParentBackground := False;
  FTitle := TLabel.Create(Self);
  FTitle.Parent := FHeader;
  FTitle.AutoSize := True;
  FTitle.Font.Size := 13;
  FTitle.Font.Style := [fsBold];
  FTitle.Caption := ' ';
  FTitle.SetBounds(S(16), S(8), S(740), FTitle.Height);
  FSubtitle := TLabel.Create(Self);
  FSubtitle.Parent := FHeader;
  FSubtitle.AutoSize := True;
  FSubtitle.Caption := ' ';
  FSubtitle.SetBounds(S(16), FTitle.Top + FTitle.Height + S(2), S(740),
    FSubtitle.Height);
  FHeader.Height := FSubtitle.Top + FSubtitle.Height + S(8);

  FBottom := TPanel.Create(Self);
  FBottom.Parent := Self;
  FBottom.Align := alBottom;
  FBottom.Height := S(48);
  FBottom.BevelOuter := bvNone;
  FBottom.Caption := '';
  Line := TBevel.Create(Self);
  Line.Parent := FBottom;
  Line.Align := alTop;
  Line.Height := S(2);
  Line.Shape := bsTopLine;
  FBtnClose := NewButton(FBottom, 'Fechar', 90, CloseClick);
  FBtnClose.SetBounds(ClientWidth - S(16 + 90), S(10), S(90), S(28));
  FBtnClose.Anchors := [akTop, akRight];
  FBtnNext := NewButton(FBottom, 'Avançar >', 100, NextClick);
  FBtnNext.SetBounds(ClientWidth - S(16 + 90 + 8 + 100), S(10), S(100), S(28));
  FBtnNext.Anchors := [akTop, akRight];
  FBtnNext.Default := True;
  FBtnBack := NewButton(FBottom, '< Voltar', 100, BackClick);
  FBtnBack.SetBounds(ClientWidth - S(16 + 90 + 8 + 100 + 8 + 100), S(10),
    S(100), S(28));
  FBtnBack.Anchors := [akTop, akRight];

  for P := Low(TWizPage) to High(TWizPage) do
  begin
    FPanels[P] := NewPanel;
    FPanels[P].BorderWidth := S(16);
  end;
  BuildModePage;
  BuildVersionsPage;
  BuildItemsPage;
  BuildPathPage;
  BuildRunPage;
end;

procedure TMainWizard.BuildModePage;
begin
  FRgMode := TRadioGroup.Create(Self);
  FRgMode.Parent := FPanels[wpMode];
  FRgMode.Align := alTop;
  FRgMode.Height := S(130);
  FRgMode.Caption := ' Operação ';
  FRgMode.Items.Add('Fazer backup do ambiente Delphi desta máquina');
  FRgMode.Items.Add('Restaurar um backup nesta máquina');
  FRgMode.Items.Add('Comparar um backup com o ambiente atual');
  FRgMode.ItemIndex := 0;
  FRgMode.OnClick := ModeClick;
  NewLabel(FPanels[wpMode],
    'Dica: instale as versões do Delphi (da mais antiga para a mais nova) antes de restaurar. '
    + 'A restauração sobrescreve componentes, configurações da IDE e chaves de registro.');
  FLblAdmin := NewLabel(FPanels[wpMode],
    'Para restaurar é necessário executar como administrador. Este programa não está '
    + 'elevado: reinicie-o como administrador para continuar.');
  FLblAdmin.Font.Style := [fsBold];
  FLblAdmin.Font.Color := clMaroon;
  FLblAdmin.Visible := False;
  FPnlElevate := TPanel.Create(Self);
  FPnlElevate.Parent := FPanels[wpMode];
  FPnlElevate.Align := alTop;
  FPnlElevate.Height := S(40);
  FPnlElevate.BevelOuter := bvNone;
  FPnlElevate.Caption := '';
  FPnlElevate.Visible := False;
  FBtnElevate := NewButton(FPnlElevate, 'Reiniciar como administrador', 210,
    ElevateClick);
  FBtnElevate.SetBounds(0, S(8), S(210), S(28));
end;

procedure TMainWizard.BuildVersionsPage;
begin
  FLblVersions := NewLabel(FPanels[wpVersions], '');
  NewToolbar(FPanels[wpVersions], MarkAllVersions, MarkNoVersions);
  FLstVersions := TCheckListBox.Create(Self);
  FLstVersions.Parent := FPanels[wpVersions];
  FLstVersions.Align := alClient;
end;

procedure TMainWizard.BuildItemsPage;
begin
  FLblItems := NewLabel(FPanels[wpItems], '');
  FChkDlls := TCheckBox.Create(Self);
  FChkDlls.Parent := FPanels[wpItems];
  FChkDlls.Align := alBottom;
  FChkDlls.Caption :=
    'Procurar DLLs de terceiros (System32/SysWOW64 e dependências) — pode demorar';
  FChkDlls.Checked := False;
  FChkDlls.OnClick := DllsClick;
  NewToolbar(FPanels[wpItems], MarkAllItems, MarkNoItems);
  FLstItems := TCheckListBox.Create(Self);
  FLstItems.Parent := FPanels[wpItems];
  FLstItems.Align := alClient;
end;

procedure TMainWizard.BuildPathPage;
var
  Row: TPanel;
begin
  FLblPath := NewLabel(FPanels[wpPath], '');
  Row := TPanel.Create(Self);
  Row.Parent := FPanels[wpPath];
  Row.Align := alTop;
  Row.Height := S(30);
  Row.BevelOuter := bvNone;
  Row.Caption := '';
  FBtnBrowse := NewButton(Row, 'Pasta...', 90, BrowseFolderClick);
  FBtnBrowse.Align := alRight;
  FBtnBrowse.AlignWithMargins := True;
  FBtnBrowse.Margins.Left := S(6);
  FBtnBrowse.Margins.Top := 0;
  FBtnBrowse.Margins.Bottom := 0;
  FBtnBrowseZip := NewButton(Row, 'Arquivo .zip...', 110, BrowseZipClick);
  FBtnBrowseZip.Align := alRight;
  FBtnBrowseZip.AlignWithMargins := True;
  FBtnBrowseZip.Margins.Left := S(6);
  FBtnBrowseZip.Margins.Top := 0;
  FBtnBrowseZip.Margins.Bottom := 0;
  FEdtPath := TEdit.Create(Self);
  FEdtPath.Parent := Row;
  FEdtPath.Align := alClient;
  FChkZip := TCheckBox.Create(Self);
  FChkZip.Parent := FPanels[wpPath];
  FChkZip.Align := alTop;
  FChkZip.AlignWithMargins := True;
  FChkZip.Margins.Top := S(8);
  FChkZip.Caption := 'Compactar o backup em um arquivo .zip';
  FChkZip.Checked := True;
  FChkZipStore := TCheckBox.Create(Self);
  FChkZipStore.Parent := FPanels[wpPath];
  FChkZipStore.Align := alTop;
  FChkZipStore.AlignWithMargins := True;
  FChkZipStore.Margins.Top := S(4);
  FChkZipStore.Margins.Left := S(20);
  FChkZipStore.Top := FChkZip.Top + FChkZip.Height + S(1);
  FChkZipStore.Caption := 'Sem compressão (mais rápido, arquivo maior)';
  FChkZipStore.Checked := FConfig.ZipStore;
  FChkKeepFolder := TCheckBox.Create(Self);
  FChkKeepFolder.Parent := FPanels[wpPath];
  FChkKeepFolder.Align := alTop;
  FChkKeepFolder.AlignWithMargins := True;
  FChkKeepFolder.Margins.Top := S(4);
  FChkKeepFolder.Margins.Left := S(20);
  FChkKeepFolder.Top := FChkZipStore.Top + FChkZipStore.Height + S(1);
  FChkKeepFolder.Caption :=
    'Manter também a pasta (por padrão ela é removida depois de conferir o .zip)';
  FChkKeepFolder.Checked := False;
  FChkZip.OnClick := ZipCheckClick;
  FLblOpenStatus := NewLabel(FPanels[wpPath], '');
  FLblOpenStatus.Top := Row.Top + Row.Height + S(10);
  FLblOpenStatus.Margins.Top := S(10);
  FLblOpenStatus.Visible := False;
  FOpenProgress := TProgressBar.Create(Self);
  FOpenProgress.Parent := FPanels[wpPath];
  FOpenProgress.Align := alTop;
  FOpenProgress.Top := FLblOpenStatus.Top + FLblOpenStatus.Height + S(1);
  FOpenProgress.Height := S(18);
  FOpenProgress.Visible := False;
end;

procedure TMainWizard.BuildRunPage;
begin
  FLblStatus := NewLabel(FPanels[wpRun], '');
  FProgress := TProgressBar.Create(Self);
  FProgress.Parent := FPanels[wpRun];
  FProgress.Align := alBottom;
  FProgress.Height := S(18);
  FMemo := TMemo.Create(Self);
  FMemo.Parent := FPanels[wpRun];
  FMemo.Align := alClient;
  FMemo.ReadOnly := True;
  FMemo.ScrollBars := ssVertical;
  FMemo.Font.Name := 'Consolas';
  FMemo.Font.Size := 9;
end;

{ ------------------------------------------------------------- Navigation }

function TMainWizard.NextPageOf(APage: TWizPage): TWizPage;
begin
  Result := wpRun;
  case APage of
    wpMode:
      if FMode = wmBackup then
        Result := wpVersions
      else
        Result := wpPath;
    wpVersions:
      if FMode = wmCompare then
        Result := wpRun
      else
        Result := wpItems;
    wpItems:
      if FMode = wmBackup then
        Result := wpPath
      else
        Result := wpRun;
    wpPath:
      if FMode = wmBackup then
        Result := wpRun
      else
        Result := wpVersions;
  end;
end;

function TMainWizard.PrevPageOf(APage: TWizPage): TWizPage;
begin
  Result := wpMode;
  case APage of
    wpVersions:
      if FMode = wmBackup then
        Result := wpMode
      else
        Result := wpPath;
    wpItems:
      Result := wpVersions;
    wpPath:
      if FMode = wmBackup then
        Result := wpItems
      else
        Result := wpMode;
    wpRun:
      case FMode of
        wmBackup:
          Result := wpPath;
        wmRestore:
          Result := wpItems;
        wmCompare:
          Result := wpVersions;
      end;
  end;
end;

procedure TMainWizard.ShowPage(APage: TWizPage);
var
  P: TWizPage;
begin
  FPage := APage;
  for P := Low(TWizPage) to High(TWizPage) do
    FPanels[P].Visible := P = APage;
  FTitle.Caption := PageTitles[APage];
  case APage of
    wpMode:
      FSubtitle.Caption := 'Escolha a operação e clique em Avançar.';
    wpVersions:
      begin
        if FMode = wmBackup then
        begin
          FSubtitle.Caption :=
            'Selecione as versões instaladas que entram no backup.';
          FLblVersions.Caption := 'Versões do Delphi instaladas nesta máquina:';
        end
        else
        begin
          FSubtitle.Caption :=
            'Selecione as versões do backup que serão usadas.';
          FLblVersions.Caption :=
            'Versões presentes no backup (versões não instaladas só podem ser comparadas):';
        end;
        FillVersions;
      end;
    wpItems:
      begin
        if FMode = wmBackup then
        begin
          FSubtitle.Caption := 'Marque o que deve entrar no backup.';
          FLblItems.Caption := 'Itens encontrados (agrupados por categoria):';
          FChkDlls.Visible := True;
          LoadItemsAsync;
        end
        else
        begin
          FSubtitle.Caption :=
            'Escolha as categorias a restaurar. Tudo que existir nelas será sobrescrito.';
          FLblItems.Caption := 'Categorias do backup:';
          FChkDlls.Visible := False;
          FillCategories;
        end;
      end;
    wpPath:
      SetupPathPage;
    wpRun:
      begin
        FSubtitle.Caption := '';
        StartRun;
      end;
  end;
  UpdateButtons;
end;

procedure TMainWizard.UpdateButtons;
begin
  FBtnBack.Visible := FPage <> wpMode;
  FBtnBack.Enabled := not FBusy;
  FBtnNext.Visible := FPage <> wpRun;
  FBtnNext.Enabled := not FBusy and not((FPage = wpMode) and (FMode = wmRestore)
    and not IsRunningAsAdmin);
  FLblAdmin.Visible := (FMode = wmRestore) and not IsRunningAsAdmin;
  FPnlElevate.Visible := FLblAdmin.Visible;
  if NextPageOf(FPage) = wpRun then
    FBtnNext.Caption := 'Executar'
  else
    FBtnNext.Caption := 'Avançar >';
  FBtnClose.Enabled := not FBusy or (FOpeningSource and not FCloseAfterOpen);
  FEdtPath.Enabled := not FOpeningSource;
  FBtnBrowse.Enabled := not FOpeningSource;
  FBtnBrowseZip.Enabled := not FOpeningSource;
  FRgMode.Enabled := not FBusy;
end;

procedure TMainWizard.SetBusy(ABusy: Boolean);
begin
  FBusy := ABusy;
  if ABusy then
  begin
    Screen.Cursor := crAppStart;
    FProgress.Style := pbstMarquee;
  end
  else
  begin
    Screen.Cursor := crDefault;
    FProgress.Style := pbstNormal;
  end;
  UpdateButtons;
end;

procedure TMainWizard.ZipCheckClick(Sender: TObject);
begin
  FChkZipStore.Enabled := FChkZip.Checked;
  FChkKeepFolder.Enabled := FChkZip.Checked;
end;

procedure TMainWizard.AppendLog(const AText: string);
var
  Msg: string;
begin
  Msg := AText;
  TThread.Queue(nil, procedure
    begin
      { the memo does not exist before BuildUI; on the main thread Queue runs the
        procedure immediately }
      if not FClosing and (FMemo <> nil) then
        FMemo.Lines.Add(Msg);
    end);
end;

procedure TMainWizard.ResetSession;
begin
  FreeAndNil(FRestore);
  FRestoreSource := '';
  FItems.Clear;
  FItemsKey := '';
  FDllsScanned := False;
  FChkDlls.Checked := False;
  FSelected.Clear;
  SetLength(FSelBds, 0);
  FLstItems.Items.Clear;
  FLstVersions.Items.Clear;
end;

function TMainWizard.CheckedCount(AList: TCheckListBox): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to AList.Items.Count - 1 do
    if (not AList.Header[I]) and AList.Checked[I] then
      Inc(Result);
end;

function TMainWizard.ValidateAndLeave(APage: TWizPage): Boolean;
var
  I: Integer;
  V: TDelphiVersion;
begin
  Result := False;
  case APage of
    wpMode:
      begin
        FMode := TWizMode(FRgMode.ItemIndex);
        if (FMode = wmBackup) and (FInstalled.Count = 0) then
        begin
          MessageDlg('Nenhuma versão do Delphi foi encontrada nesta máquina.',
            mtError, [mbOK], 0);
          Exit;
        end;
        ResetSession;
      end;
    wpVersions:
      begin
        if CheckedCount(FLstVersions) = 0 then
        begin
          MessageDlg('Selecione ao menos uma versão.', mtWarning, [mbOK], 0);
          Exit;
        end;
        SetLength(FSelBds, 0);
        FSelected.Clear;
        for I := 0 to FLstVersions.Items.Count - 1 do
          if FLstVersions.Checked[I] then
          begin
            SetLength(FSelBds, Length(FSelBds) + 1);
            FSelBds[High(FSelBds)] := FVersionIds[I];
            V := FInstalled.FindByBds(FVersionIds[I]);
            if V <> nil then
              FSelected.Add(V);
          end;
      end;
    wpItems:
      if FMode = wmBackup then
      begin
        SyncSelection;
        if CheckedCount(FLstItems) = 0 then
        begin
          MessageDlg('Selecione ao menos um item para o backup.', mtWarning,
            [mbOK], 0);
          Exit;
        end;
      end
      else if CheckedCount(FLstItems) = 0 then
      begin
        MessageDlg('Selecione ao menos uma categoria.', mtWarning, [mbOK], 0);
        Exit;
      end;
    wpPath:
      begin
        SavePathText;
        if FMode = wmBackup then
        begin
          if Trim(FDestText) = '' then
          begin
            MessageDlg('Informe a pasta de destino.', mtWarning, [mbOK], 0);
            Exit;
          end;
        end
        else if not OpenSource then
          Exit;
      end;
  end;
  Result := True;
end;

procedure TMainWizard.BackClick(Sender: TObject);
begin
  if FBusy then
    Exit;
  ShowPage(PrevPageOf(FPage));
end;

procedure TMainWizard.NextClick(Sender: TObject);
begin
  if FBusy then
    Exit;
  if ValidateAndLeave(FPage) then
    ShowPage(NextPageOf(FPage));
end;

procedure TMainWizard.CloseClick(Sender: TObject);
begin
  Close;
end;

procedure TMainWizard.WizardCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := not FBusy;
  if FOpeningSource then
  begin
    FCloseAfterOpen := True;
    FOpenCancel.SetEvent;
    ShowOpenProgress(0, 0,
      'Cancelando abertura e limpando arquivos temporários...');
    UpdateButtons;
    Exit;
  end;
  if not CanClose then
    MessageDlg('Aguarde o término da operação em andamento.', mtInformation,
      [mbOK], 0);
end;

procedure TMainWizard.ElevateClick(Sender: TObject);
var
  Info: TShellExecuteInfo;
begin
  FLogger.Info('Reiniciando como administrador');
  FillChar(Info, SizeOf(Info), 0);
  Info.cbSize := SizeOf(Info);
  Info.fMask := SEE_MASK_NOASYNC;
  Info.Wnd := Handle;
  Info.lpVerb := 'runas';
  Info.lpFile := PChar(ParamStr(0));
  Info.nShow := SW_SHOWNORMAL;
  if ShellExecuteEx(@Info) then
    Close
  else if GetLastError = ERROR_CANCELLED then
    MessageDlg
      ('A elevação foi cancelada. O programa continua sem privilégios de administrador.',
      mtWarning, [mbOK], 0)
  else
    MessageDlg('Não foi possível reiniciar como administrador: ' +
      SysErrorMessage(GetLastError), mtError, [mbOK], 0);
end;

procedure TMainWizard.ModeClick(Sender: TObject);
begin
  FMode := TWizMode(FRgMode.ItemIndex);
  UpdateButtons;
end;

{ ---------------------------------------------------------- List handling }

procedure TMainWizard.FillVersions;
var
  V: TDelphiVersion;
  MV: TManifestVersion;
  Inst: TDelphiVersion;
  Idx: Integer;
  Txt: string;
begin
  FLstVersions.Items.BeginUpdate;
  try
    FLstVersions.Items.Clear;
    FVersionIds.Clear;
    if FMode = wmBackup then
    begin
      for V in FInstalled do
      begin
        Idx := FLstVersions.Items.Add(V.DisplayName);
        FLstVersions.Checked[Idx] := True;
        FVersionIds.Add(V.BdsVersion);
      end;
    end
    else if FRestore <> nil then
      for MV in FRestore.Manifest.Versions do
      begin
        Inst := FInstalled.FindByBds(MV.BdsVersion);
        Txt := MV.ProductName;
        if Txt = '' then
          Txt := 'Delphi';
        Txt := Txt + ' (BDS ' + MV.BdsVersion + ')';
        if Inst = nil then
          Txt := Txt + '  - NÃO instalada nesta máquina'
        else
          Txt := Txt + '  - instalada';
        Idx := FLstVersions.Items.Add(Txt);
        FLstVersions.Checked[Idx] := (Inst <> nil) or (FMode = wmCompare);
        FVersionIds.Add(MV.BdsVersion);
      end;
  finally
    FLstVersions.Items.EndUpdate;
  end;
end;

procedure TMainWizard.FillCategories;
var
  C: TItemCategory;
  MI: TManifestItem;
  Counts: array [TItemCategory] of Integer;
  Idx, I: Integer;
  Used: Boolean;
begin
  for C := Low(TItemCategory) to High(TItemCategory) do
    Counts[C] := 0;
  if FRestore <> nil then
    for MI in FRestore.Manifest.Items do
    begin
      Used := MI.Item.Versions.Count = 0;
      for I := 0 to High(FSelBds) do
        if MI.Item.Versions.IndexOf(FSelBds[I]) >= 0 then
          Used := True;
      if Used then
        Inc(Counts[MI.Item.Category]);
    end;
  FLstItems.Items.BeginUpdate;
  try
    FLstItems.Items.Clear;
    for C := Low(TItemCategory) to High(TItemCategory) do
      if Counts[C] > 0 then
      begin
        Idx := FLstItems.Items.AddObject(Format('%s (%d itens)',
          [CategoryLabels[C], Counts[C]]), TObject(NativeInt(Ord(C))));
        FLstItems.Checked[Idx] := True;
      end;
  finally
    FLstItems.Items.EndUpdate;
  end;
end;

function TMainWizard.RestoreCategoryOf(AIndex: Integer): TItemCategory;
begin
  Result := TItemCategory(NativeInt(FLstItems.Items.Objects[AIndex]));
end;

function TMainWizard.SelectedCategories: TItemCategories;
var
  I: Integer;
begin
  Result := [];
  for I := 0 to FLstItems.Items.Count - 1 do
    if FLstItems.Checked[I] then
      Include(Result, RestoreCategoryOf(I));
end;

procedure TMainWizard.SyncSelection;
var
  I: Integer;
  Obj: TObject;
begin
  for I := 0 to FLstItems.Items.Count - 1 do
  begin
    Obj := FLstItems.Items.Objects[I];
    if Obj is TBackupItem then
      TBackupItem(Obj).Selected := FLstItems.Checked[I];
  end;
end;

procedure TMainWizard.RebuildItemList;
var
  C: TItemCategory;
  It: TBackupItem;
  Idx: Integer;
  Txt: string;
  HasAny: Boolean;
begin
  FLstItems.Items.BeginUpdate;
  try
    FLstItems.Items.Clear;
    for C := Low(TItemCategory) to High(TItemCategory) do
    begin
      if (C = icSystemDll) and not FChkDlls.Checked then
        Continue;
      HasAny := False;
      for It in FItems do
        if It.Category = C then
        begin
          HasAny := True;
          Break;
        end;
      if not HasAny then
        Continue;
      Idx := FLstItems.Items.AddObject(CategoryLabels[C], nil);
      FLstItems.Header[Idx] := True;
      for It in FItems do
        if It.Category = C then
        begin
          if It.Kind = ikDll then
          begin
            Txt := It.SourcePath;
            if It.Company <> '' then
              Txt := Txt + '  -  ' + It.Company;
            if It.FileVersion <> '' then
              Txt := Txt + ' ' + It.FileVersion;
            if It.ReinstalledByIde then
              Txt := Txt + '  (reinstala com a IDE)';
          end
          else if It.Description <> '' then
            Txt := It.Description + '  -  ' + It.SourcePath
          else
            Txt := It.SourcePath;
          Idx := FLstItems.Items.AddObject(Txt, It);
          FLstItems.Checked[Idx] := It.Selected;
        end;
    end;
  finally
    FLstItems.Items.EndUpdate;
  end;
end;

procedure TMainWizard.LoadItemsAsync;
var
  Key: string;
  NewItems: TBackupItemList;
  Versions: TDelphiVersionList;
begin
  Key := VersionsToText(FSelBds);
  if (Key = FItemsKey) and (FItems.Count > 0) then
  begin
    RebuildItemList;
    Exit;
  end;
  FItemsKey := Key;
  FDllsScanned := False;
  FChkDlls.Checked := False;
  FLstItems.Items.Clear;
  FMemo.Lines.Clear;
  NewItems := TBackupItemList.Create(True);
  Versions := TDelphiVersionList.Create(False);
  FSelected.Clear;
  FLblItems.Caption := 'Procurando itens do ambiente, aguarde...';
  SetBusy(True);
  TWizardWorker.Create(procedure
    var
      V: TDelphiVersion;
      S: string;
    begin
      for S in FSelBds do
      begin
        V := FInstalled.FindByBds(S);
        if V <> nil then
          Versions.Add(V);
      end;
      CreatePathDiscovery(FLogger).Discover(Versions, FConfig, NewItems);
    end, procedure(const AError: string; APrecheck: Boolean)
    var
      S: string;
      V: TDelphiVersion;
    begin
      Versions.Free;
      SetBusy(False);
      if FClosing then
      begin
        NewItems.Free;
        Exit;
      end;
      FItems.Free;
      FItems := NewItems;
      for S in FSelBds do
      begin
        V := FInstalled.FindByBds(S);
        if V <> nil then
          FSelected.Add(V);
      end;
      FLblItems.Caption := 'Itens encontrados (agrupados por categoria):';
      if AError <> '' then
      begin
        FItemsKey := '';
        MessageDlg('Falha ao descobrir os itens: ' + AError, mtError,
          [mbOK], 0);
      end;
      RebuildItemList;
    end);
end;

procedure TMainWizard.ScanDllsAsync;
var
  Dlls: TBackupItemList;
begin
  Dlls := TBackupItemList.Create(True);
  FLblItems.Caption := 'Procurando DLLs de terceiros, aguarde...';
  SyncSelection;
  SetBusy(True);
  TWizardWorker.Create(procedure
    begin
      CreateDllScanner(FLogger).Scan(FSelected, FItems, Dlls);
    end, procedure(const AError: string; APrecheck: Boolean)
    var
      I: Integer;
      It: TBackupItem;
    begin
      SetBusy(False);
      if FClosing then
      begin
        Dlls.Free;
        Exit;
      end;
      FLblItems.Caption := 'Itens encontrados (agrupados por categoria):';
      if AError <> '' then
        MessageDlg('Falha ao procurar DLLs: ' + AError, mtError, [mbOK], 0)
      else
      begin
        for I := Dlls.Count - 1 downto 0 do
        begin
          It := Dlls[I];
          Dlls.Extract(It);
          It.Selected := False;
          FItems.Add(It);
        end;
        FDllsScanned := True;
      end;
      Dlls.Free;
      RebuildItemList;
    end);
end;

procedure TMainWizard.DllsClick(Sender: TObject);
var
  It: TBackupItem;
begin
  if FBusy then
    Exit;
  if FChkDlls.Checked then
  begin
    if FDllsScanned then
      RebuildItemList
    else
      ScanDllsAsync;
  end
  else
  begin
    SyncSelection;
    for It in FItems do
      if It.Kind = ikDll then
        It.Selected := False;
    RebuildItemList;
  end;
end;

procedure TMainWizard.MarkAllVersions(Sender: TObject);
begin
  FLstVersions.CheckAll(cbChecked, False, False);
end;

procedure TMainWizard.MarkNoVersions(Sender: TObject);
begin
  FLstVersions.CheckAll(cbUnchecked, False, False);
end;

procedure TMainWizard.MarkAllItems(Sender: TObject);
var
  I: Integer;
begin
  for I := 0 to FLstItems.Items.Count - 1 do
    if not FLstItems.Header[I] then
      FLstItems.Checked[I] := True;
end;

procedure TMainWizard.MarkNoItems(Sender: TObject);
var
  I: Integer;
begin
  for I := 0 to FLstItems.Items.Count - 1 do
    if not FLstItems.Header[I] then
      FLstItems.Checked[I] := False;
end;

{ -------------------------------------------------------------- Path page }

procedure TMainWizard.SetupPathPage;
begin
  if FMode = wmBackup then
  begin
    FSubtitle.Caption := 'Escolha onde o backup será gravado.';
    FLblPath.Caption :=
      'Pasta de destino (será criada a subpasta DelphiEnv_<máquina>_<data>):';
    if FDestText = '' then
      FDestText := GetDocumentsDir + '\DelphiBackups';
    FEdtPath.Text := FDestText;
    FBtnBrowse.Caption := 'Procurar...';
    FBtnBrowseZip.Visible := False;
    FChkZip.Visible := True;
    FChkZipStore.Visible := True;
    FChkKeepFolder.Visible := True;
    ZipCheckClick(FChkZip);
  end
  else
  begin
    FSubtitle.Caption := 'Escolha o backup (pasta ou arquivo .zip).';
    FLblPath.Caption :=
      'Backup a usar (pasta com manifest.json ou arquivo .zip):';
    FEdtPath.Text := FSourceText;
    FBtnBrowse.Caption := 'Pasta...';
    FBtnBrowseZip.Caption := 'Arquivo .zip...';
    FBtnBrowseZip.Visible := True;
    FChkZip.Visible := False;
    FChkZipStore.Visible := False;
    FChkKeepFolder.Visible := False;
  end;
end;

procedure TMainWizard.SavePathText;
begin
  if FMode = wmBackup then
    FDestText := Trim(FEdtPath.Text)
  else
    FSourceText := Trim(FEdtPath.Text);
end;

procedure TMainWizard.BrowseFolderClick(Sender: TObject);
var
  Dlg: TFileOpenDialog;
begin
  Dlg := TFileOpenDialog.Create(Self);
  try
    Dlg.Options := [fdoPickFolders, fdoPathMustExist];
    if (FEdtPath.Text <> '') and DirectoryExists(FEdtPath.Text) then
      Dlg.DefaultFolder := FEdtPath.Text;
    if Dlg.Execute then
      FEdtPath.Text := Dlg.FileName;
  finally
    Dlg.Free;
  end;
end;

procedure TMainWizard.BrowseZipClick(Sender: TObject);
var
  Dlg: TOpenDialog;
begin
  Dlg := TOpenDialog.Create(Self);
  try
    Dlg.Filter := 'Backup compactado (*.zip)|*.zip|Todos os arquivos|*.*';
    Dlg.Options := [ofFileMustExist, ofPathMustExist];
    if Dlg.Execute then
      FEdtPath.Text := Dlg.FileName;
  finally
    Dlg.Free;
  end;
end;

function TMainWizard.OpenSource: Boolean;
var
  Engine, Previous: TRestoreEngine;
  Source: string;
begin
  Result := False;
  if FSourceText = '' then
  begin
    MessageDlg('Informe uma pasta de backup ou arquivo .zip existente.',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  if (FRestore <> nil) and SameText(FRestoreSource, FSourceText) then
    Exit(True);
  Source := FSourceText;
  Previous := FRestore;
  FRestore := nil;
  FRestoreSource := '';
  Engine := nil;
  FOpenCancel.ResetEvent;
  FOpeningSource := True;
  SetBusy(True);
  ShowOpenProgress(0, 0, 'Abrindo backup...');
  TWizardWorker.Create(procedure
    var
      Opened: Boolean;
    begin
      Previous.Free;
      if OpenCancelled then
        Exit;
      Engine := TRestoreEngine.Create(FLogger, CreateProcessRunner(FLogger,
        OpenCancelled));
      Opened := False;
      try
        Engine.Open(Source, QueueOpenProgress);
        Opened := True;
      finally
        if not Opened or OpenCancelled then
          FreeAndNil(Engine);
      end;
    end, procedure(const AError: string; APrecheck: Boolean)
    begin
      if FCloseAfterOpen then
      begin
        { Close may have been requested after the worker queued its result. }
        if Engine <> nil then
          TWizardWorker.Create(procedure
            begin
              FreeAndNil(Engine);
            end, FinishClosingSource)
        else
          FinishClosingSource('', False);
        Exit;
      end;
      FOpeningSource := False;
      FLblOpenStatus.Visible := False;
      FOpenProgress.Visible := False;
      SetBusy(False);
      if AError <> '' then
        MessageDlg('Não foi possível abrir o backup: ' + AError, mtError,
          [mbOK], 0)
      else
      begin
        FRestore := Engine;
        FRestoreSource := Source;
        ShowPage(NextPageOf(wpPath));
      end;
    end);
end;

function TMainWizard.OpenCancelled: Boolean;
begin
  Result := FOpenCancel.WaitFor(0) = wrSignaled;
end;

procedure TMainWizard.ShowOpenProgress(ACurrent, ATotal: Integer;
const AStatus: string);
begin
  FLblOpenStatus.Caption := AStatus;
  FLblOpenStatus.Visible := True;
  if ATotal > 0 then
  begin
    FOpenProgress.Style := pbstNormal;
    FOpenProgress.Max := ATotal;
    FOpenProgress.Position := ACurrent;
  end
  else
    FOpenProgress.Style := pbstMarquee;
  FOpenProgress.Visible := True;
end;

procedure TMainWizard.QueueOpenProgress(ACurrent, ATotal: Integer;
const AStatus: string);
var
  Status: string;
begin
  if OpenCancelled then
    Abort;
  Status := AStatus;
  TThread.Queue(nil, procedure
    begin
      if not FCloseAfterOpen then
        ShowOpenProgress(ACurrent, ATotal, Status);
    end);
end;

procedure TMainWizard.FinishClosingSource(const AError: string;
APrecheck: Boolean);
begin
  if AError <> '' then
    FLogger.Warn(AError);
  FOpeningSource := False;
  SetBusy(False);
  Close;
end;

{ --------------------------------------------------------------- Execution }

procedure TMainWizard.OnProgress(ACurrent, ATotal: Integer;
const AStep: string);
begin
  QueueProgress(ACurrent, ATotal, Format('[%d/%d] %s',
    [ACurrent, ATotal, AStep]));
end;

procedure TMainWizard.QueueProgress(ACurrent, ATotal: Integer;
const AStatus: string);
var
  Status: string;
begin
  { called from the worker thread }
  Status := AStatus;
  TThread.Queue(nil, procedure
    begin
      if FClosing then
        Exit;
      if ATotal > 0 then
      begin
        FProgress.Style := pbstNormal;
        FProgress.Max := ATotal;
        FProgress.Position := ACurrent;
      end
      else
        FProgress.Style := pbstMarquee;
      FLblStatus.Caption := Status;
    end);
end;

procedure TMainWizard.RunDone(const AError: string; APrecheck: Boolean;
const ASuccessText: string);
begin
  SetBusy(False);
  if FClosing then
    Exit;
  if AError <> '' then
  begin
    FMemo.Lines.Add('');
    if APrecheck then
    begin
      FMemo.Lines.Add('PRÉ-REQUISITO NÃO ATENDIDO: ' + AError);
      MessageDlg(AError, mtWarning, [mbOK], 0);
    end
    else
    begin
      FMemo.Lines.Add('FALHA: ' + AError);
      MessageDlg('A operação falhou: ' + AError, mtError, [mbOK], 0);
    end;
    FLblStatus.Caption := 'Falhou.';
  end
  else
  begin
    FMemo.Lines.Add('');
    FMemo.Lines.Add(ASuccessText);
    FLblStatus.Caption := 'Concluído.';
    FProgress.Position := FProgress.Max;
  end;
end;

procedure TMainWizard.StartRun;
begin
  FMemo.Lines.Clear;
  FProgress.Position := 0;
  FLblStatus.Caption := '';
  case FMode of
    wmBackup:
      StartBackup;
    wmRestore:
      StartRestore;
    wmCompare:
      StartCompare;
  end;
end;

procedure TMainWizard.StartBackup;
var
  Options: TBackupOptions;
  OutPath: string;
begin
  SyncSelection;
  FSubtitle.Caption := 'Criando o backup...';
  Options.Versions := FSelBds;
  Options.Destination := FDestText;
  Options.CreateZip := FChkZip.Checked;
  Options.ZipStore := Options.CreateZip and FChkZipStore.Checked;
  Options.KeepFolder := FChkZip.Checked and FChkKeepFolder.Checked;
  Options.ScanDlls := FChkDlls.Checked;
  Options.Categories := DefaultBackupCategories;
  if FChkDlls.Checked then
    Include(Options.Categories, icSystemDll);
  OutPath := '';
  SetBusy(True);
  TWizardWorker.Create(procedure
    var
      Engine: TBackupEngine;
    begin
      Engine := TBackupEngine.Create(FLogger, FRunner);
      try
        OutPath := Engine.Execute(Options, FSelected, FItems, FConfig,
          OnProgress, QueueProgress);
      finally
        Engine.Free;
      end;
    end, procedure(const AError: string; APrecheck: Boolean)
    begin
      FSubtitle.Caption := '';
      RunDone(AError, APrecheck, 'Backup concluído: ' + OutPath);
    end);
end;

procedure TMainWizard.StartRestore;
var
  Options: TRestoreOptions;
  Plan: TObjectList<TRestorePlanStep>;
  Step: TRestorePlanStep;
  Line, SecurityExportDir: string;
begin
  FSubtitle.Caption := 'Revise o plano de restauração.';
  Options.Source := FRestoreSource;
  Options.Versions := FSelBds;
  Options.Categories := SelectedCategories;
  try
    FRestore.Precheck(Options, FInstalled);
  except
    on E: EPrecheckError do
    begin
      FMemo.Lines.Add('PRÉ-REQUISITO NÃO ATENDIDO: ' + E.Message);
      FLblStatus.Caption := 'Restauração não pode ser executada.';
      MessageDlg(E.Message, mtWarning, [mbOK], 0);
      Exit;
    end;
    on E: Exception do
    begin
      FMemo.Lines.Add('FALHA: ' + E.Message);
      MessageDlg('Falha na verificação prévia: ' + E.Message, mtError,
        [mbOK], 0);
      Exit;
    end;
  end;
  FMemo.Lines.Add('Plano de restauração:');
  Plan := FRestore.BuildPlan(Options);
  try
    for Step in Plan do
    begin
      Line := Step.Description;
      if Step.BdsVersion <> '' then
        Line := '[' + Step.BdsVersion + '] ' + Line;
      FMemo.Lines.Add('  - ' + Line);
    end;
  finally
    Plan.Free;
  end;
  FMemo.Lines.Add('');
  if MessageDlg
    ('A restauração vai SOBRESCREVER componentes, configurações e chaves de registro '
    + 'das versões selecionadas nesta máquina. Esta ação não pode ser desfeita automaticamente.'
    + sLineBreak + sLineBreak + 'Deseja continuar?', mtConfirmation,
    [mbYes, mbNo], 0) <> mrYes then
  begin
    FMemo.Lines.Add('Restauração cancelada pelo usuário.');
    FLblStatus.Caption := 'Cancelado.';
    FSubtitle.Caption := '';
    Exit;
  end;
  FSubtitle.Caption := 'Restaurando...';
  SetBusy(True);
  TWizardWorker.Create(procedure
    begin
      FRestore.Execute(Options, FInstalled, OnProgress);
      SecurityExportDir := FRestore.SecurityExportDir;
    end, procedure(const AError: string; APrecheck: Boolean)
    begin
      FSubtitle.Caption := '';
      RunDone(AError, APrecheck,
        'Restauração concluída. Abra a IDE para conferir o ambiente.' +
        sLineBreak + 'Exportações de segurança mantidas em ' +
        SecurityExportDir);
    end);
end;

procedure TMainWizard.StartCompare;
var
  Options: TCompareOptions;
  Diffs, Total, TolerantFiles: Integer;
begin
  FSubtitle.Caption := 'Comparando...';
  Options.Source := FRestoreSource;
  Options.Versions := FSelBds;
  Diffs := 0;
  Total := 0;
  TolerantFiles := 0;
  SetBusy(True);
  TWizardWorker.Create(procedure
    var
      Engine: TCompareEngine;
      Res: TCompareResult;
      E: TDiffEntry;
    begin
      Engine := TCompareEngine.Create(FLogger, FRunner);
      try
        Res := Engine.Execute(Options, FInstalled, FConfig, QueueProgress);
        try
          TolerantFiles := Res.TolerantFileCount;
          for E in Res.Entries do
          begin
            AppendLog(FormatCompareEntry(E));
            Inc(Total);
            if E.Kind <> dkInfo then
              Inc(Diffs);
          end;
        finally
          Res.Free;
        end;
      finally
        Engine.Free;
      end;
    end, procedure(const AError: string; APrecheck: Boolean)
    var
      Msg: string;
    begin
      FSubtitle.Caption := '';
      if Diffs > 0 then
        Msg := Format('Comparação concluída: %d diferença(s) em %d entrada(s).',
          [Diffs, Total])
      else
        Msg := 'Comparação concluída: nenhuma diferença encontrada.';
      if TolerantFiles > 0 then
        Msg := Msg + sLineBreak + TolerantFileSummary(TolerantFiles);
      RunDone(AError, APrecheck, Msg);
    end);
end;

end.
