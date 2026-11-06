; Agent Chat Windows 설치 프로그램 (Inno Setup 6)
; CI 가 agent-chat\runtime\node.exe 를 넣은 뒤 ISCC /DAppVersion=x.y.z windows\agent-chat.iss 로 만든다.
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{9E3C2B1A-6F7D-4C2E-8A51-3D7B0C4E9F12}
AppName=Agent Chat
AppVersion={#AppVersion}
AppPublisher=Agent Chat
DefaultDirName={autopf}\Agent Chat
DefaultGroupName=Agent Chat
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=AgentChat-{#AppVersion}-windows-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; 방화벽 규칙을 넣으려면 관리자 권한이 필요하다
PrivilegesRequired=admin
WizardStyle=modern
UninstallDisplayName=Agent Chat
CloseApplications=no

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "autostart"; Description: "Windows 에 로그인할 때 자동으로 켜기 (추천)"
Name: "firewall"; Description: "방화벽 허용: 같은 와이파이 · Tailscale 에서만 접속 (추천)"

[Files]
Source: "..\server.js"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\package.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\run-hidden.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "open-connect.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "stop.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\lib\*"; DestDir: "{app}\lib"; Flags: ignoreversion recursesubdirs
Source: "..\public\*"; DestDir: "{app}\public"; Flags: ignoreversion recursesubdirs
Source: "..\runtime\*"; DestDir: "{app}\runtime"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\Agent Chat 휴대폰 연결 (QR)"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\open-connect.vbs"""; IconFilename: "{sys}\shell32.dll"; IconIndex: 13
Name: "{group}\Agent Chat 끄기"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\stop.vbs"""; IconFilename: "{sys}\shell32.dll"; IconIndex: 27
Name: "{group}\Agent Chat 설정 파일"; Filename: "{sys}\notepad.exe"; Parameters: """{%USERPROFILE}\.agent-chat\config.json"""
Name: "{group}\Agent Chat 기록 (server.log)"; Filename: "{sys}\notepad.exe"; Parameters: """{%USERPROFILE}\.agent-chat\server.log"""
Name: "{group}\{cm:UninstallProgram,Agent Chat}"; Filename: "{uninstallexe}"
Name: "{userstartup}\Agent Chat"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\run-hidden.vbs"""; Tasks: autostart

[Run]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Agent Chat"""; Flags: runhidden; Tasks: firewall
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Agent Chat"" dir=in action=allow program=""{app}\runtime\node.exe"" enable=yes profile=any remoteip=localsubnet,100.64.0.0/10"; Flags: runhidden; Tasks: firewall
Filename: "{sys}\wscript.exe"; Parameters: """{app}\open-connect.vbs"""; Description: "지금 켜고 휴대폰 연결 화면(QR) 열기"; Flags: postinstall nowait runasoriginaluser skipifsilent

[UninstallRun]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\stop.vbs"" /quiet"; Flags: runhidden waituntilterminated; RunOnceId: "StopServer"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Agent Chat"""; Flags: runhidden; RunOnceId: "DelFirewall"

[Code]
// 업데이트할 때 돌고 있는 서버를 먼저 끈다 (node.exe 가 잠겨 있으면 덮어쓸 수 없다)
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  rc: Integer;
  stopper: String;
begin
  stopper := ExpandConstant('{app}\stop.vbs');
  if FileExists(stopper) then
    Exec(ExpandConstant('{sys}\wscript.exe'), '"' + stopper + '" /quiet', '', SW_HIDE, ewWaitUntilTerminated, rc);
  Result := '';
end;
