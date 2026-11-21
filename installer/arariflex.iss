; ARARIFlex Windows 설치 프로그램 (Inno Setup 6)
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6B0B6F0E-3C1B-4C55-9E5A-6D3E2E1A7F21}
AppName=ARARIFlex
AppVersion={#AppVersion}
AppPublisher=ARARIFlex
DefaultDirName={autopf}\ARARIFlex
DefaultGroupName=ARARIFlex
OutputDir=..\dist
OutputBaseFilename=ARARIFlex-{#AppVersion}-windows-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern
UninstallDisplayIcon={app}\ARARIFlex.exe
; 설치 전에 오픈소스 구성요소 안내를 보여준다
InfoBeforeFile=..\THIRD_PARTY_NOTICES.txt
SetupIconFile=..\windows\runner\resources\app_icon.ico

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

; 0.6 까지의 실행 파일 이름 (지금은 ARARIFlex.exe). 덮어 깔 때 예전 것이 남지 않게 지운다
[InstallDelete]
Type: files; Name: "{app}\media_shelf.exe"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\ARARIFlex"; Filename: "{app}\ARARIFlex.exe"
Name: "{group}\{cm:UninstallProgram,ARARIFlex}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\ARARIFlex"; Filename: "{app}\ARARIFlex.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\ARARIFlex.exe"; Description: "{cm:LaunchProgram,ARARIFlex}"; Flags: nowait postinstall skipifsilent
