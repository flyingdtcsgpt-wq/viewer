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

## 보낼 때 모델 · 추론 강도 · 생각
입력창 왼쪽 버튼(예: `편집 허용 · Opus · 높음`)을 누르면 고른다. 새 대화 창에도 같은 줄이 있다.

| | Claude | Codex |
|---|---|---|
| 모델 | 기본 · Fable · Opus · Sonnet · Haiku · 직접 입력 (`--model`) | 기본 · 이 PC 에서 쓴 모델들 · 직접 입력 (`-m`) |
| 추론 강도 | 낮음 · 보통 · 높음 · 매우 높음 · 최대 (`--effort`) | 최소 · 낮음 · 보통 · 높음 · 매우 높음 (`model_reasoning_effort`) |
| 생각 | 기본 · 켜기 · 끄기 | (추론 강도로 조절) |

- "기본" 은 PC 의 Claude · Codex 설정 그대로. 고른 값은 휴대폰에 기억되고 보내는 메시지마다 붙는다 (대기 중인 메시지도 보낼 때 고른 값으로).
- 대화 화면 위에는 그 대화가 **실제로 쓴 모델**이 보인다 (기록 파일에 남은 값).

## VS Code 에 열려 있는 대화는 그 창의 Claude 가 처리한다
- 목록에 **VS Code** 표시가 붙은 대화는 지금 VS Code(또는 터미널)에 열려 있는 것이다. 휴대폰에서 보내면 **새 Claude 를 띄우지 않고 그 창의 Claude 에게 메시지를 넣는다.**
  대화 화면 위에 `● VS Code 연결`, 보낸 말풍선에 `VS Code 로 전달됨` 이 붙는다.
- 어떻게: Claude Code 는 세션마다 소켓(`/tmp/cc-socks/<pid>.sock`, Windows 는 `\\.\pipe\cc-msg-…`)을 열어 두고
  `~/.claude/sessions/<pid>.json` 에 세션 id · 소켓 · 상태(busy/idle)를 적는다. 서버는 그 소켓에 인증 줄과 `{"type":"user",…}` 한 줄을 보낸다.
  Claude Code 가 세션끼리 메시지를 주고받는 공식 통로와 같다.
- 받는 Claude 에게는 "다른 Claude 세션이 보낸 메시지(사용자를 대신해 보냈을 가능성이 높음)" 로 보인다. 그래서 앞에 "사용자가 휴대폰에서 직접 입력한 메시지" 라고 적어 보낸다.
  그래도 받는 Claude 는 비밀 같은 민감한 내용에는 조심할 수 있다. PC 연결 화면에 나오는 안내문을 `~/.claude/CLAUDE.md` 에 **직접** 붙여 넣으면 내 입력처럼 다룬다 (프로그램이 그 파일을 고치지는 않는다).
  휴대폰 화면에는 내 말풍선으로 보인다. 다른 세션이 넣은 메시지는 회색 줄로 보인다.
- 그 창의 백그라운드 작업 · 예약 · 기억이 그대로 이어진다. 세션이 바뀌지 않는다. 모델 · 추론 · 권한은 VS Code 의 설정을 따른다.
- VS Code 를 닫으면(등록이 사라지면) 다음 메시지부터 아래 "한 대화 = 한 Claude 프로세스" 방식으로 돈다.
- 끄려면 `config.json` 에 `"relayToLive": false`.
- Codex 는 이런 통로가 없어 그대로다.

## 한 대화 = 한 Claude 프로세스
- 휴대폰에서 어떤 대화에 처음 보내면 그 대화용 Claude 를 하나 띄우고(`claude -p --input-format stream-json --resume <id>`), **다음 메시지부터는 같은 프로세스에 이어서 넣는다.** 대화 id 도 그대로라 대화가 끊기지 않는다.
- 그래서 휴대폰에서 시킨 백그라운드 작업 · 기억이 메시지 사이에 이어진다. 대화 화면 위에 `● 연결 유지` 가 보이면 켜져 있는 것.
- 30분 동안 조용하면 닫힌다. 다음에 보내면 다시 띄워서 같은 대화를 이어 간다.
- 권한 · 모델 · 추론 · 생각 · 구독/API 를 바꾸면 그 다음 메시지부터 새로 띄운다 (대화 내용은 그대로).
- **중지**는 먼저 "중단" 만 보내서 프로세스를 살려 두고, 5초 안에 안 멈추면 끈다.
- **VS Code 안의 Claude 는 따로다.** VS Code 확장이 띄운 Claude 프로세스에는 바깥 프로그램이 메시지를 넣을 수 없다.
  그래서 VS Code 에서 돌던 작업(그 안의 백그라운드 작업 등)은 휴대폰에서 이어받을 수 없다. 같은 대화를 VS Code 와 휴대폰에서 **동시에** 시키지 말 것.
- Codex 는 아직 메시지마다 `codex exec resume` 을 새로 띄운다 (대화는 같은 기록 파일에 이어짐).

## 남은 사용량 (화면 맨 아래)
목록 · 대화 화면 맨 아래에 구독 요금제의 **남은 사용량**(5시간 · 주간)이 늘 보인다. 초록 → 주황(30% 이하) → 빨강(10% 이하). 누르면 사용한 % 와 **초기화 시각**.

- **Claude**: PC 의 Claude 로그인 정보(`~/.claude/.credentials.json`)로 1분에 한 번 사용량을 조회한다 (Claude Code 의 `/usage` 와 같은 곳, 공식 문서에 없는 주소라 바뀌면 조회가 안 될 수 있음). 휴대폰에서 시킨 작업이 끝날 때 오는 사용량 정보로도 갱신된다.
- **Codex**: Codex 대화 기록에 남는 사용량 중 가장 최근 것 (마지막으로 Codex 를 쓴 때 기준).
- API 키로 돌리는 프로젝트는 요금제 한도가 아니라 쓴 만큼 과금이라 여기에 나오지 않는다.

## 프로젝트마다 구독(OAuth) / API 키
- **API 키 넣기**: PC 에서 *Agent Chat 휴대폰 연결* 화면 → 아래 **API 키** 칸 (이 PC 에서만 열림). 키는 `~/.agent-chat/config.json` 에만 저장된다.
- **고르기**: 휴대폰 대화 화면 위의 **구독 / API** 버튼, 또는 새 대화의 *실행 방식*. 목록에서 API 프로젝트는 보라색 **API** 표시.
- **Claude**: API 로 고르면 그 프로젝트 폴더의 `.claude/settings.local.json` 에 `apiKeyHelper` 를 넣는다
  → **그 폴더의 VS Code 창도** API 키로 돈다 (VS Code 에서는 새 대화부터). 다른 프로젝트는 그대로 구독.
  키는 프로젝트 폴더에 적히지 않고, 실행할 때 PC 설정에서 읽어 온다. 구독으로 되돌리면 넣었던 줄만 지운다 (원래 있던 다른 설정은 그대로).
- **Codex**: 로그인이 PC 에 하나뿐이라 VS Code 창은 나눌 수 없다. **휴대폰에서 시킨 작업만** API 키(`CODEX_API_KEY`)로 돈다.
- 구독 프로젝트에서 휴대폰이 시킨 작업은 `ANTHROPIC_API_KEY` · `CODEX_API_KEY` 를 지우고 실행해서, PC 환경변수에 키가 있어도 구독으로 돈다.
- 키가 틀리면 Claude 는 몇 번 다시 시도한 뒤 오류를 보여 준다 (1~2분).

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
