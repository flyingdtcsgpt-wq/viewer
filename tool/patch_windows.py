"""flutter create 로 만든 windows/runner 를 다듬는다 (CI 에서 실행): 창 제목, 기본 크기."""
from pathlib import Path

main = Path("windows/runner/main.cpp")
s = main.read_text(encoding="utf-8")
s = s.replace("Win32Window::Size size(1280, 720);", "Win32Window::Size size(1600, 960);")
s = s.replace('window.Create(L"media_shelf"', 'window.Create(L"ARARIFlex"')
main.write_text(s, encoding="utf-8")

rc = Path("windows/runner/Runner.rc")
if rc.exists():
    r = rc.read_text(encoding="utf-8", errors="ignore")
    r = r.replace('"FileDescription", "media_shelf"', '"FileDescription", "ARARIFlex"').replace('"ProductName", "media_shelf"', '"ProductName", "ARARIFlex"')
    rc.write_text(r, encoding="utf-8")
print("windows runner patched")

# 오래된 C++/WinRT 플러그인(webview_windows 등)이 최신 MSVC 에서 막히지 않게
cm = Path("windows/CMakeLists.txt")
c = cm.read_text(encoding="utf-8")
flag = "add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)"
if flag not in c:
    import re
    c = re.sub(r"(project\([^)]*\)\n)", r"\1" + flag + "\n", c, count=1)
    assert flag in c, "project() not found in windows/CMakeLists.txt"
    cm.write_text(c, encoding="utf-8")
print("coroutine flag added")
