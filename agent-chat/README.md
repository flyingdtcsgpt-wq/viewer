# Agent Chat

PC 의 VS Code 에서 쓰는 **Claude Code 확장 · Codex 확장** 대화를 휴대폰에서 **채팅창처럼만** 보고, 이어서 일을 시키는 작은 서버.
원격 데스크톱처럼 화면을 통째로 보내지 않고, 대화만 휴대폰 크기에 맞게 보여 준다. 파일은 전부 내 PC 에 그대로 있다.

## 하는 일
- 대화 목록: Claude · Codex 세션을 최근 순으로 (프로젝트 폴더, 제목, 마지막 말, 작업 중 표시)
- 채팅: 내 말 / 답변(마크다운 · 표 · 코드) / 도구 실행(접혀 있음, 눌러서 입력 · 결과 보기, ⚙ 로 숨기기)
- **실시간**: 폰에서 시킨 작업은 PC 처럼 답변이 글자 단위로 흘러나오고, 지금 실행 중인 명령(`실행 중: npm test`)이 보인다.
  PC 의 VS Code 에서 돌리는 작업도 기록 파일에 쓰이는 즉시(0.4초 안) 폰에 나타난다 (이쪽은 글자 단위가 아니라 문단 · 도구 단위).
- 이어서 시키기: 아래 입력창에 쓰고 보내면 같은 세션에 이어서 실행. 작업 중에 또 보내면 **대기**했다가 끝나면 이어서 실행 (최대 5개). **중지** 가능
- 새 대화: ＋ → Claude/Codex, 작업 폴더(최근 쓴 폴더 목록), 권한 고르고 시작
- 권한: Claude `편집 허용 / 자동 / 전부 허용 / 계획만`, Codex `폴더 쓰기 / 읽기만 / 전부 허용`

## 어떻게 동작하나
두 확장은 대화를 PC 에 파일로 남긴다. 이 서버는 그 파일을 읽어 보여 준다.

| | 대화 기록 | 이어서 보낼 때 실행하는 것 |
|---|---|---|
| Claude Code | `~/.claude/projects/<폴더>/<세션id>.jsonl` | `claude -p --resume <세션id> --permission-mode <권한>` |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-…-<세션id>.jsonl` | `codex exec resume <세션id> -` (`-c sandbox_mode=<권한>`) |

- 보낸 말은 표준입력으로 넘겨서 따옴표 · 줄바꿈 · 한글이 깨지지 않는다.
- `claude` / `codex` 프로그램은 PATH → VS Code 확장 폴더(`~/.vscode/extensions/anthropic.claude-code-*`, `openai.chatgpt-*`) 순서로 자동으로 찾는다.
- 확장과 같은 기록 파일을 쓰므로, 휴대폰에서 이어 간 대화는 PC 의 VS Code 에서 그 세션을 다시 열면(대화 기록/히스토리) 그대로 이어진다.
  VS Code 패널이 이미 열려 있으면 바로 새로 고쳐지지는 않으니, 다시 열어야 보인다.
- 같은 세션을 VS Code 에서 돌리는 중에 휴대폰에서도 보내면 둘이 섞인다. 화면 아래에 "PC 에서 작업 중인 것 같습니다" 가 보이면 끝날 때까지 기다린다.

## 설치 (Windows 11 + 안드로이드)
설치 파일 받는 곳: GitHub 저장소 **Actions → agent-chat → 최신 실행 → Artifacts**
(`AgentChat-windows-setup`, `AgentChat-android`). `agent-chat-v0.2.0` 같은 태그를 push 하면 **Releases** 에도 올라간다.

### PC (Windows 11)
1. `AgentChat-x.y.z-windows-setup.exe` 실행 (Node.js 가 안에 들어 있어 따로 설치할 것 없음)
   - 서명이 없는 설치 파일이라 *Windows의 PC 보호* 창이 뜨면 **추가 정보 → 실행**
   - 고를 것: *로그인할 때 자동으로 켜기*, *방화벽 허용(같은 와이파이 · Tailscale 에서만)* 둘 다 그대로 두면 된다
2. 설치가 끝나면 PC 브라우저에 **휴대폰 연결** 화면(QR 코드)이 열린다.
   나중에는 시작 메뉴 → **Agent Chat 휴대폰 연결 (QR)**
3. 시작 메뉴에 **Agent Chat 끄기**, **설정 파일**, **기록 (server.log)** 도 있다. 제거는 Windows 설정 → 앱.
4. 절전 막기: 설정 → 시스템 → 전원 → *화면 및 절전* → 절전 모드 **안 함** (화면은 꺼져도 된다)

### 휴대폰 (안드로이드)
1. `AgentChat-x.y.z-android.apk` 를 휴대폰에서 열어 설치 (*출처를 알 수 없는 앱* 허용)
2. 앱 → **QR 스캔으로 PC 추가** → PC 의 연결 화면 QR 을 찍는다.
   QR 을 찍기 어려우면 **숫자 코드로 PC 추가** → 연결 화면의 *PC 주소*(예: `100.101.5.7`)와 *연결 코드 6자리*를 넣는다
   (코드는 10분 동안 · 한 번만 · 5번 틀리면 폐기). PC 가 여러 대면 계속 추가, 목록 위 **PC** 버튼으로 바꾼다
3. 일을 시키고 앱을 내려놓아도, 작업이 끝나면 **알림**이 온다 (눌러서 그 대화로). 처음 한 번 알림 허용
4. 밖(LTE)에서: PC 와 휴대폰에 Tailscale 설치 · 같은 계정 로그인 → 연결 화면의 **어디서나** QR 로 추가

아이폰 · 다른 기기는 앱 없이 브라우저로: QR 을 찍어 열거나, `http://PC주소:8790` 을 열고 첫 화면에 연결 코드 6자리. 그다음 *공유 → 홈 화면에 추가*.

### 설치 파일 없이 (개발용 · macOS/Linux)
Node.js 18+ 를 깔고 `start.bat` / `./start.sh` 실행. 창 없이 자동 시작은 `autostart-on.bat` / `autostart-off.bat`.

### 폰에서 안 열릴 때
- 설치 때 방화벽 허용을 껐거나 설치 파일 없이 쓴다면, **관리자 권한** 명령 프롬프트에서 한 번:
  `netsh advfirewall firewall add rule name="Agent Chat" dir=in action=allow protocol=TCP localport=8790`
- `server.log`(시작 메뉴 → 기록)의 `claude :` / `codex :` 줄이 *못 찾음* 이면 `config.json` 에 경로를 적는다.
  보통 위치: Claude `C:\Users\<나>\.local\bin\claude.exe` 또는 `C:\Users\<나>\AppData\Roaming\npm\claude.cmd`,
  Codex 는 VS Code 확장 안 `C:\Users\<나>\.vscode\extensions\openai.chatgpt-…\bin\windows-x86_64\codex.exe` (자동으로 찾음)
- Codex 확장을 **WSL 에서 실행** 하도록 설정해 두었다면 기록이 WSL 안(`\\wsl.localhost\Ubuntu\home\<나>\.codex`)에 있다.
  `codexHome` 에 그 경로를 적으면 보기는 된다. 이어서 보내기는 Windows 쪽 codex 로 실행되므로 WSL 모드에서는 쓰지 않는 것이 좋다.

## 밖에서 (LTE · 다른 와이파이) 접속하기
포트포워딩으로 인터넷에 열지 말고 **[Tailscale](https://tailscale.com)** 을 쓴다 (무료).
1. PC 와 휴대폰에 Tailscale 설치, 같은 계정으로 로그인
2. 서버 창에 나오는 `100.x.x.x` 주소로 접속 (`http://100.x.x.x:8790`)

PC 는 켜져 있어야 하고 절전으로 들어가면 안 된다 (Windows 설정 → 전원 → 절전 "안 함").

## 설정 (`~/.agent-chat/config.json`, 처음 실행할 때 생김)
| 항목 | 뜻 |
|---|---|
| `token` | 접속 비밀번호. 바꾸면 휴대폰에서 다시 입력 |
| `port` / `host` | 기본 `8790` / `0.0.0.0` (같은 와이파이 · Tailscale 에서 접속). 이 PC 에서만 쓰려면 `127.0.0.1` |
| `claudeBin` / `codexBin` | 자동으로 못 찾을 때 실행 파일 경로 직접. JSON 이라 `\\` 두 번 (예: `"C:\\Users\\me\\.local\\bin\\claude.exe"`) |
| `claudeHome` / `codexHome` | 기록 폴더가 기본(`~/.claude`, `~/.codex`)이 아닐 때 |
| `claudeArgs` / `codexArgs` | 실행할 때 덧붙일 인자 (예: `["--model", "opus"]`) |
| `projects` | 새 대화 폴더 목록에 항상 보일 폴더 |


## 보안
- 모든 API 는 토큰이 있어야 한다. 틀린 토큰 10번이면 그 주소를 10분 막는다.
- 토큰은 주소의 `#` 뒤에 있어 서버 로그 · 다른 사이트로 넘어가지 않는다. 주소를 남에게 보여 주지 말 것.
- "전부 허용" 권한은 확인 없이 명령을 실행한다. 믿는 폴더에서만.
- PC 의 VS Code 처럼 "이 명령 실행할까요?" 를 폰에서 하나씩 허락하는 기능은 없다. 보낼 때 고른 권한 안에서만 실행되고,
  권한 밖의 일은 Claude 가 "허락이 필요하다" 고 답한다 → 권한을 올려 다시 보내면 된다.

## PC 가 여러 대 · VS Code 창이 여러 개 · Claude 와 Codex 를 같이 쓸 때
- VS Code 창이 몇 개든, 한 창에 Claude · Codex 확장이 같이 있든 상관없다. 기록은 PC 마다 한 곳(`~/.claude`, `~/.codex`)에 모여 목록에 **프로젝트 폴더 이름**과 함께 전부 보인다.
- PC 가 여러 대면 PC 마다 설치하고 앱에 QR 로 각각 추가한다.
- 같은 대화를 PC 와 휴대폰에서 동시에 시키면 섞인다. "PC 에서 작업 중" 이 보이면 끝날 때까지 기다린다.

## 개발
```
npm test        # 기록 해석 · 이어 읽기 · 서버(가짜 claude/codex 로 보내기 · 새 세션 · 실패 표시 · 실시간 · 대기열 · Windows .cmd)
```
GitHub Actions(`agent-chat.yml`)가 Windows · Linux, Node 18 · 22 에서 돌린다. 외부 라이브러리 없음 (QR 그리기만 `public/vendor/qrcode.js`, MIT). `server.js`(HTTP · 인증), `lib/sources.js`(기록 해석), `lib/runner.js`(claude/codex 실행), `public/`(휴대폰 화면 · PC 연결 화면), `windows/`(설치 파일 Inno Setup · 시작/끄기 스크립트), `android/`(앱: WebView + PC 목록 + 작업 끝 알림).

안드로이드 서명: 저장소 Secrets 에 `AGENT_CHAT_KEYSTORE_BASE64` 등(없으면 ARARIFlex 의 `ANDROID_KEYSTORE_*`)이 있으면 그 키로 서명한다. 없으면 debug 키라 새 버전이 기존 앱 위에 설치되지 않을 수 있다(지우고 다시 설치).
