; MediaShelf Windows 설치 프로그램 (Inno Setup 6)
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6B0B6F0E-3C1B-4C55-9E5A-6D3E2E1A7F21}
AppName=MediaShelf
AppVersion={#AppVersion}
AppPublisher=MediaShelf
DefaultDirName={autopf}\MediaShelf
DefaultGroupName=MediaShelf
OutputDir=..\dist
OutputBaseFilename=MediaShelf-{#AppVersion}-windows-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern
UninstallDisplayIcon={app}\media_shelf.exe
SetupIconFile=..\windows\runner\resources\app_icon.ico

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\MediaShelf"; Filename: "{app}\media_shelf.exe"
Name: "{group}\{cm:UninstallProgram,MediaShelf}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\MediaShelf"; Filename: "{app}\media_shelf.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\media_shelf.exe"; Description: "{cm:LaunchProgram,MediaShelf}"; Flags: nowait postinstall skipifsilent
