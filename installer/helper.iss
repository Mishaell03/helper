#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{08A62AA0-F99A-45D1-8819-A806330DF112}
AppName=Helper
AppVersion={#AppVersion}
AppPublisher=Mishaell03
AppPublisherURL=https://github.com/Mishaell03/helper
DefaultDirName={localappdata}\Programs\Helper
DefaultGroupName=Helper
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=output
OutputBaseFilename=helper-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\windows\runner\resources\app_icon.ico
WizardImageFile=branding\wizard.bmp
WizardSmallImageFile=branding\wizard-small.bmp
UninstallDisplayIcon={app}\helper.exe
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Excludes: "modules\ExcelMigrationEngine\*"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Helper"; Filename: "{app}\helper.exe"; IconFilename: "{app}\helper.exe"
Name: "{userdesktop}\Helper"; Filename: "{app}\helper.exe"; WorkingDir: "{app}"; IconFilename: "{app}\helper.exe"; HotKey: "ctrl+shift+F1"
Name: "{group}\Uninstall Helper"; Filename: "{uninstallexe}"; IconFilename: "{app}\helper.exe"

[Run]
Filename: "{app}\helper.exe"; Description: "Start Helper"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Include manually deployed optional runtime and other files in the app folder.
Type: filesandordirs; Name: "{app}"

[Code]
function SafeAppDirectory(const Directory: String): Boolean;
var
  Path: String;
begin
  Path := RemoveBackslashUnlessRoot(ExpandFileName(Directory));
  Result :=
    (CompareText(Path, ExtractFileDrive(Path) + '\') <> 0) and
    (CompareText(Path, ExpandConstant('{win}')) <> 0) and
    (CompareText(Path, ExpandConstant('{sys}')) <> 0) and
    (CompareText(Path, ExpandConstant('{autopf}')) <> 0) and
    (CompareText(Path, ExpandConstant('{userprofile}')) <> 0) and
    (CompareText(Path, ExpandConstant('{userdesktop}')) <> 0) and
    (CompareText(Path, ExpandConstant('{userdocs}')) <> 0) and
    (CompareText(Path, ExpandConstant('{localappdata}')) <> 0) and
    (CompareText(Path, ExpandConstant('{userappdata}')) <> 0) and
    (CompareText(Path, ExpandConstant('{commonappdata}')) <> 0) and
    (CompareText(Path, ExpandConstant('{tmp}')) <> 0);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not SafeAppDirectory(ExpandConstant('{app}')) then
    Result := 'Выберите отдельную папку для Helper, а не корень диска или системный каталог.';
end;

function InitializeUninstall(): Boolean;
begin
  Result := SafeAppDirectory(ExpandConstant('{app}'));
  if not Result then
    MsgBox('Небезопасный каталог установки. Автоматическое удаление всей папки отменено.',
      mbError, MB_OK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
  Parameters: String;
begin
  if CurUninstallStep = usUninstall then begin
    Parameters := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
      ExpandConstant('{app}\stop_helper.ps1') + '" -InstallDirectory "' +
      ExpandConstant('{app}') + '"';
    if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      RaiseException('Не удалось завершить Helper. Удаление отменено.');
    if ResultCode <> 0 then
      RaiseException('Helper не завершён. Закройте программу и повторите удаление.');
  end;
end;
