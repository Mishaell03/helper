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
UninstallDisplayIcon={app}\helper.exe
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Helper"; Filename: "{app}\helper.exe"
Name: "{group}\Uninstall Helper"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\helper.exe"; Description: "Start Helper"; Flags: nowait postinstall skipifsilent
