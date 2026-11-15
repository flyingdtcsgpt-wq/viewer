# Agent Chat: put text into an IDE window (VS Code, Antigravity, Cursor ... any VS Code family) as if typed.
# ASCII only on purpose: Windows PowerShell 5.1 reads a .ps1 without BOM in the system code page.
# User-facing messages live in typer.js, keyed by the "stage" this script reports.
#
#   1) find the window : walk up from the conversation's process to the IDE (an exe that ships a VS Code
#                        product.json), then pick that IDE's window whose title contains the project folder name
#   2) bring it forward: verify it really became the foreground window. If the screen is locked or the Remote
#                        Desktop session is disconnected this is where we stop (nothing typed)
#   3) focus the chat  : (Claude) <IDE>.exe --open-url -- <scheme>://anthropic.claude-code/open?session=...
#                        the extension reveals that conversation's tab
#   4) paste (Ctrl+V) and press Enter
#
# input : env AC_TYPE_JOB = path of a UTF-8 JSON file
#   { text, folder, pid, uri, paste, submit, settleMs, ideNames[], dryRun }
# output: last line = one JSON object { ok, stage, detail, window, ide, typed, submitted }
#   typed     = text went out to the window
#   submitted = Enter was pressed (false means nothing was sent, so sending another way cannot duplicate)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$typed = $false
$submitted = $false
function Done($ok, $stage, $detail, $extra) {
  $o = [ordered]@{ ok = $ok; stage = $stage; detail = $detail; typed = $script:typed; submitted = $script:submitted }
  if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }
  [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress))
  exit 0
}

try {
  $job = Get-Content -Raw -Encoding UTF8 -LiteralPath $env:AC_TYPE_JOB | ConvertFrom-Json
} catch { Done $false 'job' $_.Exception.Message $null }

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class AcWin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);

  public static List<object[]> Windows() {
    var list = new List<object[]>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      int n = GetWindowTextLength(h);
      if (n == 0) return true;
      var sb = new StringBuilder(n + 2);
      GetWindowText(h, sb, sb.Capacity);
      uint pid; GetWindowThreadProcessId(h, out pid);
      list.Add(new object[] { h, pid, sb.ToString() });
      return true;
    }, IntPtr.Zero);
    return list;
  }
  // A locked screen or a disconnected Remote Desktop session has no input desktop we may open.
  public static bool DesktopReady() {
    IntPtr d = OpenInputDesktop(0, false, 0x0100 /* DESKTOP_SWITCHDESKTOP */);
    if (d == IntPtr.Zero) return false;
    CloseDesktop(d);
    return true;
  }
  public static bool Front(IntPtr h) {
    if (IsIconic(h)) ShowWindow(h, 9 /* SW_RESTORE */);
    if (GetForegroundWindow() == h) return true;
    SetForegroundWindow(h);
    if (GetForegroundWindow() == h) return true;
    // Attach to the current foreground window's input thread for a moment and take over.
    uint tmp; uint fg = GetWindowThreadProcessId(GetForegroundWindow(), out tmp); uint me = GetCurrentThreadId();
    if (fg != 0 && fg != me) {
      AttachThreadInput(me, fg, true);
      BringWindowToTop(h); SetForegroundWindow(h);
      AttachThreadInput(me, fg, false);
      if (GetForegroundWindow() == h) return true;
    }
    // Last resort: a key press that does nothing makes us "the process that received the last input".
    keybd_event(0xFF, 0, 0, UIntPtr.Zero); keybd_event(0xFF, 0, 2, UIntPtr.Zero);
    SetForegroundWindow(h);
    return GetForegroundWindow() == h;
  }
  public static void Key(byte vk) { keybd_event(vk, 0, 0, UIntPtr.Zero); keybd_event(vk, 0, 2, UIntPtr.Zero); }
  public static void Chord(byte mod, byte vk) {
    keybd_event(mod, 0, 0, UIntPtr.Zero); keybd_event(vk, 0, 0, UIntPtr.Zero);
    keybd_event(vk, 0, 2, UIntPtr.Zero); keybd_event(mod, 0, 2, UIntPtr.Zero);
  }
  // Is a person holding Ctrl / Shift / Alt / Win right now?
  public static bool ModifierDown() {
    foreach (int vk in new int[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }) if ((GetAsyncKeyState(vk) & 0x8000) != 0) return true;
    return false;
  }
}
'@

# ---------- 1) IDE process and window ----------
$procs = @{}
foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath) { $procs[[int]$p.ProcessId] = $p }

# product.json of a VS Code family exe, or $null. Old layout: <dir>\resources\app\product.json.
# Newer VS Code keeps resources in a versioned sub-folder: <dir>\<commit>\resources\app\product.json.
$productCache = @{}
function ProductOf($exe) {
  if (-not $exe) { return $null }
  if ($productCache.ContainsKey($exe)) { return $productCache[$exe] }
  $r = $null
  try {
    $dir = Split-Path -Parent $exe
    $f = Join-Path $dir 'resources\app\product.json'
    if (-not (Test-Path -LiteralPath $f)) {
      $f = $null
      $subs = @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction Stop)
      if ($subs.Count -le 60) {
        $found = @($subs | ForEach-Object { Join-Path $_.FullName 'resources\app\product.json' } | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } -Descending)
        if ($found.Count) { $f = $found[0] }
      }
    }
    if ($f) { $r = (Get-Content -Raw -Encoding UTF8 -LiteralPath $f | ConvertFrom-Json) }
  } catch { $r = $null }
  $productCache[$exe] = $r
  return $r
}

$ideExe = $null; $idePids = @(); $product = $null
$names = @($job.ideNames | Where-Object { $_ })
if ($job.pid) {
  # Walk up from the conversation's process. Remember the IDE exe when we meet it and keep climbing while the
  # same exe continues, so we end at the top (main) process, which owns the windows.
  $cur = [int]$job.pid; $guard = 0
  while ($cur -and $procs.ContainsKey($cur) -and $guard -lt 40) {
    $p = $procs[$cur]; $guard++
    $isIde = $false
    if ($names.Count) { $isIde = $names -contains ($p.Name -replace '\.exe$', '') }
    elseif ($p.ExecutablePath) { $isIde = [bool](ProductOf $p.ExecutablePath) }
    if ($isIde) { $ideExe = $p.ExecutablePath; if (-not $ideExe) { $ideExe = $p.Name } }
    elseif ($ideExe) { break }
    $cur = [int]$p.ParentProcessId
  }
}
if ($ideExe) {
  $idePids = @($procs.Values | Where-Object { $_.ExecutablePath -eq $ideExe -or (-not $_.ExecutablePath -and $_.Name -eq $ideExe) } | ForEach-Object { [int]$_.ProcessId })
  $product = ProductOf $ideExe
}

$folder = [string]$job.folder
$wins = [AcWin]::Windows()
$cands = @()
foreach ($w in $wins) {
  $wpid = [int]$w[1]; $title = [string]$w[2]
  if ($idePids.Count) { if ($idePids -notcontains $wpid) { continue } }
  else {
    # The conversation's process is unknown: is the window's owner an IDE?
    if (-not $procs.ContainsKey($wpid)) { continue }
    $wp = $procs[$wpid]
    if ($names.Count) { if ($names -notcontains ($wp.Name -replace '\.exe$', '')) { continue } }
    elseif (-not (ProductOf $wp.ExecutablePath)) { continue }
  }
  $cands += , @($w[0], $wpid, $title)
}
if (-not $cands.Count) { Done $false 'no-window' $null $null }
$match = @($cands | Where-Object { $folder -and ($_[2].ToLower().Contains($folder.ToLower())) })
if ($match.Count -eq 0 -and $cands.Count -eq 1 -and -not $folder) { $match = $cands }
if ($match.Count -eq 0) { Done $false 'no-folder-window' $folder @{ windows = @($cands | ForEach-Object { $_[2] }) } }
if ($match.Count -gt 1) {
  # Prefer a title where the folder name stands alone, like " - folder - ".
  $exact = @($match | Where-Object { $_[2] -match ('(^|[\s\-\u2014\[\(])' + [regex]::Escape($folder) + '($|[\s\-\u2014\]\)])') })
  if ($exact.Count -eq 1) { $match = $exact }
  else { Done $false 'many-windows' $folder @{ windows = @($match | ForEach-Object { $_[2] }) } }
}
$hwnd = [IntPtr]$match[0][0]; $title = [string]$match[0][2]
if (-not $ideExe) { $wp = $procs[[int]$match[0][1]]; $ideExe = $wp.ExecutablePath; $product = ProductOf $ideExe }
$ideName = if ($product -and $product.nameShort) { [string]$product.nameShort } else { [IO.Path]::GetFileNameWithoutExtension([string]$ideExe) }
$info = @{ window = $title; ide = $ideName }

if ($job.dryRun) { Done $true 'found' $null $info }

# ---------- 2) screen state, bring forward ----------
if (-not [AcWin]::DesktopReady()) { Done $false 'desktop' $null $info }
if ([AcWin]::ModifierDown()) { Done $false 'in-use' $null $info }
if (-not [AcWin]::Front($hwnd)) { Done $false 'focus' 'front' $info }
Start-Sleep -Milliseconds 250
if ([AcWin]::GetForegroundWindow() -ne $hwnd) { Done $false 'focus' 'stay' $info }

# ---------- 3) focus that conversation's input ----------
$settle = if ($job.settleMs) { [int]$job.settleMs } else { 1800 }
if ($job.uri) {
  $scheme = if ($product -and $product.urlProtocol) { [string]$product.urlProtocol } else { 'vscode' }
  $uri = $scheme + '://' + [string]$job.uri
  try {
    $env:ELECTRON_RUN_AS_NODE = $null
    if ($ideExe -and (Test-Path -LiteralPath $ideExe)) { Start-Process -FilePath $ideExe -ArgumentList @('--open-url', '--', ('"' + $uri + '"')) | Out-Null }
    else { Start-Process $uri | Out-Null }
  } catch { Done $false 'open' $_.Exception.Message $info }
  Start-Sleep -Milliseconds $settle
  if ([AcWin]::GetForegroundWindow() -ne $hwnd) {
    # The short-lived process that hands the URL over may have taken the foreground; take it back.
    if (-not [AcWin]::Front($hwnd)) { Done $false 'focus' 'after-open' $info }
    Start-Sleep -Milliseconds 200
  }
}

# ---------- 4) paste, Enter ----------
if ($job.paste) {
  $old = $null
  try { $old = Get-Clipboard -Raw } catch { }
  Set-Clipboard -Value ([string]$job.text)
  Start-Sleep -Milliseconds 120
  if ([AcWin]::GetForegroundWindow() -ne $hwnd) { Done $false 'focus' 'before-paste' $info }
  $script:typed = $true
  [AcWin]::Chord(0x11, 0x56)   # Ctrl+V
  Start-Sleep -Milliseconds 500
  if ($null -ne $old) { try { Set-Clipboard -Value $old } catch { } }
}
if ($job.submit) {
  if ([AcWin]::GetForegroundWindow() -ne $hwnd) { Done $false 'focus' 'before-enter' $info }
  $script:typed = $true
  $script:submitted = $true
  [AcWin]::Key(0x0D)           # Enter
  Start-Sleep -Milliseconds 150
}
Done $true 'done' $null $info
