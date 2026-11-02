"""flutter create 로 만든 windows/runner 를 다듬는다 (CI 에서 실행): 창 제목, 기본 크기."""
from pathlib import Path

main = Path("windows/runner/main.cpp")
s = main.read_text(encoding="utf-8")
s = s.replace("Win32Window::Size size(1280, 720);", "Win32Window::Size size(1600, 960);")
s = s.replace('window.Create(L"media_shelf"', 'window.Create(L"MediaShelf"')
main.write_text(s, encoding="utf-8")

rc = Path("windows/runner/Runner.rc")
if rc.exists():
    r = rc.read_text(encoding="utf-8", errors="ignore")
    r = r.replace('"FileDescription", "media_shelf"', '"FileDescription", "MediaShelf"').replace('"ProductName", "media_shelf"', '"ProductName", "MediaShelf"')
    rc.write_text(r, encoding="utf-8")
print("windows runner patched")
