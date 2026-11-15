# Test stand-in for an IDE window: one text box. On Enter it writes what was typed to a file and closes. (ASCII only)
param([string]$Title, [string]$Out)
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.Form
$f.Text = $Title; $f.Width = 520; $f.Height = 320
$t = New-Object System.Windows.Forms.TextBox
$t.Multiline = $true; $t.AcceptsReturn = $false; $t.Dock = 'Fill'
$f.Controls.Add($t)
$t.Add_KeyDown({
  param($s, $e)
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
    [System.IO.File]::WriteAllText($Out, $t.Text, (New-Object System.Text.UTF8Encoding($false)))
    $e.SuppressKeyPress = $true
    $f.Close()
  }
})
$f.Add_Shown({ $f.Activate(); $t.Focus() })
[System.Windows.Forms.Application]::Run($f)
