"""flutter create 로 만든 windows/ 를 다듬는다 (CI 에서 실행): 창 제목 · 기본 크기 · 실행 파일 이름 · 파일 정보.

파일 정보의 CompanyName · ProductName 은 데이터 폴더 위치가 된다: %APPDATA%\\ARARIFlex\\ARARIFlex
(0.6 까지는 %APPDATA%\\com.mediashelf\\… 였다. 앱이 처음 켜질 때 예전 폴더를 새 자리로 옮긴다 — lib/services/legacy_data.dart)
"""
import re
from pathlib import Path

NAME = "ARARIFlex"


def sub1(text, pattern, repl, what):
    """꼭 한 번은 바뀌어야 하는 치환 (flutter 의 틀이 바뀌어 못 찾으면 빌드를 멈춘다)"""
    out, n = re.subn(pattern, repl, text, count=1)
    assert n == 1, f"{what} not found"
    return out


main = Path("windows/runner/main.cpp")
s = main.read_text(encoding="utf-8")
s = s.replace("Win32Window::Size size(1280, 720);", "Win32Window::Size size(1600, 960);")
s = sub1(s, r'window\.Create\(L"[^"]*"', f'window.Create(L"{NAME}"', "window title")
main.write_text(s, encoding="utf-8")

rc = Path("windows/runner/Runner.rc")
r = rc.read_text(encoding="utf-8", errors="ignore")
for key in ("CompanyName", "FileDescription", "InternalName", "ProductName"):
    r = sub1(r, rf'VALUE "{key}", "[^"]*"', f'VALUE "{key}", "{NAME}"', key)
r = sub1(r, r'VALUE "OriginalFilename", "[^"]*"', f'VALUE "OriginalFilename", "{NAME}.exe"', "OriginalFilename")
r = re.sub(r'(VALUE "LegalCopyright", "Copyright \(C\) \d+ )[^"]*?(\. All rights reserved\.")', rf"\g<1>{NAME}\g<2>", r, count=1)
rc.write_text(r, encoding="utf-8")
print("windows runner patched")

# 오래된 C++/WinRT 플러그인(webview_windows 등)이 최신 MSVC 에서 막히지 않게
cm = Path("windows/CMakeLists.txt")
c = cm.read_text(encoding="utf-8")
# 실행 파일 이름: arariflex.exe → ARARIFlex.exe (flutter 도구도 이 줄을 읽어 실행 파일을 찾는다)
c = sub1(c, r'set\(BINARY_NAME "[^"]*"\)', f'set(BINARY_NAME "{NAME}")', "BINARY_NAME")
flag = "add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)"
if flag not in c:
    c = re.sub(r"(project\([^)]*\)\n)", r"\1" + flag + "\n", c, count=1)
    assert flag in c, "project() not found in windows/CMakeLists.txt"
cm.write_text(c, encoding="utf-8")
print("binary name + coroutine flag set")
