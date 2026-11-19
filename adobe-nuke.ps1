<#
.SYNOPSIS
    adobe-nuke: removes Adobe software and everything it leaves behind on Windows.

.DESCRIPTION
    Cleans out:
      - services, scheduled tasks and running processes
      - Explorer shell extensions (the DLLs that keep Adobe folders locked)
      - program and data folders for every user profile
      - Start menu / desktop shortcuts, the "Adobe PDF" printer, its port, driver
        and port monitor
      - registry: uninstall entries, Windows Installer registrations and component
        records, COM classes, type libraries, AppIDs, file type associations,
        context menu / icon overlay hooks, App Paths, autostart values,
        HKLM\SOFTWARE\Adobe and HKCU\Software\Adobe
      - Windows Firewall rules for Adobe programs
      - caches: Adobe packages in C:\Windows\Installer, temp files, prefetch

    With -UninstallFirst the official Adobe uninstallers run first (MSI products
    silently), and the force cleanup then removes whatever they leave behind.

    Locked files are handled in stages, so a reboot is rarely needed. Files that
    are still in use at the end are moved to a quarantine folder on the same
    drive and deleted at the next restart.

    Every registry key is exported to a backup folder in Documents before it is
    changed, and a full log is written there too.

    EVERYTHING from Adobe is removed, including Acrobat Reader. The user's
    "Creative Cloud Files" sync folder is never touched.

    Project page: https://github.com/KMzoo/adobe-nuke

.PARAMETER DryRun
    Show what would be removed without changing anything. -WhatIf is an alias
    for this switch.

.PARAMETER Force
    Skip the confirmation prompts.

.PARAMETER UninstallFirst
    Run the official Adobe uninstallers before the force cleanup. MSI products
    (Acrobat, Reader) uninstall silently; Creative Cloud apps may open their own
    uninstaller window.

.PARAMETER SkipRegistry
    Leave the registry and firewall rules alone.

.PARAMETER SkipCache
    Leave the Windows Installer cache, temp files and prefetch alone.

.PARAMETER IncludeDocuments
    Also delete the "Adobe" folder in each user's Documents folder. It holds
    settings and presets, but can also hold your own presets, libraries and
    auto-saved projects, so it is left alone unless you ask for it.

.EXAMPLE
    irm https://raw.githubusercontent.com/KMzoo/adobe-nuke/main/adobe-nuke.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/KMzoo/adobe-nuke/main/adobe-nuke.ps1))) -DryRun

.EXAMPLE
    .\adobe-nuke.ps1 -UninstallFirst

.NOTES
    Requires Windows 10/11 and Windows PowerShell 5.1 or PowerShell 7.
    Asks for administrator rights automatically.
#>
param(
    [Alias('WhatIf')][switch]$DryRun,
    [switch]$Force,
    [switch]$UninstallFirst,
    [switch]$SkipRegistry,
    [switch]$SkipCache,
    [switch]$IncludeDocuments,
    [switch]$PauseAtEnd
)

$ScriptVersion = '1.2.6'
$ScriptUrl = 'https://raw.githubusercontent.com/KMzoo/adobe-nuke/main/adobe-nuke.ps1'
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# ===========================================================================
# Output helpers
# ===========================================================================
$script:Errors = 0
$script:RebootNeeded = $false
$script:WorkDir = $null

function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Item([string]$Text, [string]$Color = 'Gray') { Write-Host "   $Text" -ForegroundColor $Color }
function Write-Done([string]$Text)  { Write-Item "OK      $Text" 'Green' }
function Write-Fail([string]$Text)  { Write-Item "FAILED  $Text" 'Red'; $script:Errors++ }
function Write-Would([string]$Text) { Write-Item "WOULD   $Text" 'DarkYellow' }

# Ends the run without "exit", which would close the whole window when the script
# was started with "irm ... | iex". Caught at the very bottom of the file.
function Exit-Script {
    if ($script:WorkDir) { try { Stop-Transcript | Out-Null } catch { } }
    if ($PauseAtEnd) { Read-Host 'Press Enter to close' | Out-Null }
    throw [System.OperationCanceledException]::new('adobe-nuke finished')
}

# Relaunches the script as administrator. From a file: runs the file again.
# From "irm | iex" (no file): downloads the script again in the elevated window.
function Request-Elevation {
    Write-Host 'Requesting administrator rights...' -ForegroundColor Yellow
    $exe = (Get-Process -Id $PID).Path
    $switches = @('-PauseAtEnd')
    foreach ($sw in 'DryRun', 'Force', 'UninstallFirst', 'SkipRegistry', 'SkipCache', 'IncludeDocuments') {
        if ((Get-Variable -Name $sw -ValueOnly -ErrorAction SilentlyContinue)) { $switches += "-$sw" }
    }
    if ($PSCommandPath) {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") + $switches
    } else {
        $cmd = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; " +
               "& ([scriptblock]::Create((Invoke-RestMethod '$ScriptUrl'))) $($switches -join ' ')"
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
    }
    try {
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList $argList -ErrorAction Stop
        Write-Host 'Continuing in the new administrator window.' -ForegroundColor Gray
    } catch {
        Write-Host 'Administrator rights are required. Nothing was changed.' -ForegroundColor Red
    }
}

function Confirm-Continue([string]$Question) {
    if ($DryRun -or $Force) { return $true }
    $answer = Read-Host "$Question (y/n)"
    return ($answer -match '^\s*[yYjJkKoOsS]')
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

# A path, command line or registry value that points into Adobe's files
function Test-AdobePath([string]$Path) {
    return ($Path -and $Path -match '\\Adobe(\\|$)|\\Adobe[^\\]*\\|CoreSync|AdobeGC|\\Acrobat')
}

# ===========================================================================
# Native helpers
# ===========================================================================
# MoveFileEx with MOVEFILE_DELAY_UNTIL_REBOOT. PowerShell turns $null into ""
# when calling .NET string parameters, so [NullString]::Value is required.
if (-not ('AdobeRemover.Native' -as [type])) {
    Add-Type -Namespace AdobeRemover -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
'@
}

function Register-DeleteOnReboot([string]$Path) {
    $ok = [AdobeRemover.Native]::MoveFileEx($Path, [NullString]::Value, 4)
    if ($ok) { $script:RebootNeeded = $true }
    return $ok
}

# takeown /D expects a localized "yes" letter (Y, J, O, S, K...). Probe for it.
function Get-TakeownYesLetter {
    $probe = Join-Path $env:TEMP ('adobe-nuke-probe-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $probe 'sub') -Force | Out-Null
    $found = $null
    foreach ($c in 'Y', 'J', 'O', 'S', 'K', 'T', 'A') {
        & takeown.exe /f $probe /r /d $c 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $found = $c; break }
    }
    Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
    return $found
}

# MSI product code <-> packed registry form. The transform is its own inverse.
# {AC76BA86-7AD7-1033-7B44-AC0F074E4100} <-> 68AB67CA7DA73301B744CAF070E41400
function ConvertTo-PackedGuid([string]$Guid) {
    $g = $Guid.Trim('{', '}').Replace('-', '')
    if ($g -notmatch '^[0-9A-Fa-f]{32}$') { return $null }
    $p  = -join ($g.Substring(0, 8).ToCharArray()[7..0])
    $p += -join ($g.Substring(8, 4).ToCharArray()[3..0])
    $p += -join ($g.Substring(12, 4).ToCharArray()[3..0])
    for ($i = 16; $i -lt 32; $i += 2) { $p += $g[$i + 1]; $p += $g[$i] }
    return $p.ToUpper()
}

function ConvertFrom-PackedGuid([string]$Packed) {
    $g = ConvertTo-PackedGuid $Packed
    if (-not $g) { return $null }
    return '{' + $g.Substring(0, 8) + '-' + $g.Substring(8, 4) + '-' + $g.Substring(12, 4) + '-' +
           $g.Substring(16, 4) + '-' + $g.Substring(20, 12) + '}'
}

# ===========================================================================
# Registry helpers (.NET API: much faster than the registry provider for scans)
# ===========================================================================
$RegHives = @{ HKLM = [Microsoft.Win32.Registry]::LocalMachine; HKCU = [Microsoft.Win32.Registry]::CurrentUser }
$RegHiveNames = @{ HKLM = 'HKEY_LOCAL_MACHINE'; HKCU = 'HKEY_CURRENT_USER' }

function Open-RegKey([string]$Hive, [string]$Path, [bool]$Writable = $false) {
    try { return $RegHives[$Hive].OpenSubKey($Path, $Writable) } catch { return $null }
}

function Get-RegString([string]$Hive, [string]$Path, [string]$Name = '') {
    $k = Open-RegKey $Hive $Path
    if (-not $k) { return $null }
    try { return [string]$k.GetValue($Name) } catch { return $null } finally { $k.Close() }
}

function Get-RegSubKeys([string]$Hive, [string]$Path) {
    $k = Open-RegKey $Hive $Path
    if (-not $k) { return @() }
    try { return $k.GetSubKeyNames() } catch { return @() } finally { $k.Close() }
}

function Get-RegValueNames([string]$Hive, [string]$Path) {
    $k = Open-RegKey $Hive $Path
    if (-not $k) { return @() }
    try { return $k.GetValueNames() } catch { return @() } finally { $k.Close() }
}

$script:RegTargets = New-Object System.Collections.Generic.List[object]
$script:RegTargetIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

function Add-RegTarget([string]$Category, [string]$Hive, [string]$Path, [string]$ValueName, [switch]$IsValue) {
    if (-not $IsValue) {
        $k = Open-RegKey $Hive $Path
        if (-not $k) { return }
        $k.Close()
    }
    $id = "$Hive|$Path|$([bool]$IsValue)|$ValueName"
    if (-not $script:RegTargetIds.Add($id)) { return }
    $script:RegTargets.Add([pscustomobject]@{
        Category  = $Category
        Hive      = $Hive
        Path      = $Path
        ValueName = $ValueName
        IsValue   = [bool]$IsValue
        Name      = "$($RegHiveNames[$Hive])\$Path"
    })
}

$script:ExportedKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:RegLogLines = New-Object System.Collections.Generic.List[string]
$script:DryRunLines = New-Object System.Collections.Generic.List[string]

function ConvertTo-RegHex([byte[]]$Bytes) {
    if (-not $Bytes -or $Bytes.Length -eq 0) { return '' }
    return (($Bytes | ForEach-Object { $_.ToString('x2') }) -join ',')
}

function ConvertTo-RegString([string]$Text) { return $Text.Replace('\', '\\').Replace('"', '\"') }

# Builds .reg file text for a key (recursively) or for a single value. Written in
# .NET instead of calling reg.exe once per key, which matters with thousands of keys.
function Get-RegExportText([string]$Hive, [string]$Path, [string]$ValueName, [switch]$ValueOnly) {
    $k = Open-RegKey $Hive $Path
    if (-not $k) { return '' }
    $sb = New-Object System.Text.StringBuilder
    try {
        [void]$sb.AppendLine("[$($RegHiveNames[$Hive])\$Path]")
        $names = if ($ValueOnly) { @($ValueName) } else { $k.GetValueNames() }
        foreach ($n in $names) {
            try {
                $kind = $k.GetValueKind($n)
                $raw = $k.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            } catch { continue }
            $label = if ($n) { '"' + (ConvertTo-RegString $n) + '"' } else { '@' }
            $line = $null
            switch ($kind.ToString()) {
                'String'       {
                    # reg.exe import drops quoted strings that contain a line break
                    if ([string]$raw -match '[\r\n]') { $line = "$label=hex(1):" + (ConvertTo-RegHex ([Text.Encoding]::Unicode.GetBytes([string]$raw + [char]0))) }
                    else { $line = "$label=`"" + (ConvertTo-RegString ([string]$raw)) + '"' }
                }
                'DWord'        { $line = "$label=dword:" + [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$raw), 0).ToString('x8') }
                'QWord'        { $line = "$label=hex(b):" + (ConvertTo-RegHex ([BitConverter]::GetBytes([int64]$raw))) }
                'ExpandString' { $line = "$label=hex(2):" + (ConvertTo-RegHex ([Text.Encoding]::Unicode.GetBytes([string]$raw + [char]0))) }
                'MultiString'  {
                    $multi = if (@($raw).Count) { (@($raw) -join [char]0) + [char]0 + [char]0 } else { [string][char]0 }
                    $line = "$label=hex(7):" + (ConvertTo-RegHex ([Text.Encoding]::Unicode.GetBytes($multi)))
                }
                'Binary'       { $line = "$label=hex:" + (ConvertTo-RegHex ([byte[]]$raw)) }
                'None'         { $line = "$label=hex(0):" + (ConvertTo-RegHex ([byte[]]$raw)) }
            }
            if ($line) { [void]$sb.AppendLine($line) }
        }
        [void]$sb.AppendLine()
        if (-not $ValueOnly) {
            foreach ($sub in $k.GetSubKeyNames()) { [void]$sb.Append((Get-RegExportText $Hive "$Path\$sub")) }
        }
    } finally { $k.Close() }
    return $sb.ToString()
}

# Appends the key (or one value) to registry-backup\<category>.reg
function Backup-RegistryTarget($T) {
    $id = "$($T.Name)|$($T.IsValue)|$($T.ValueName)"
    if ($script:ExportedKeys.Contains($id)) { return $true }
    $safe = ($T.Category -replace '[^A-Za-z0-9 ]', '').Trim()
    $file = Join-Path $script:RegBackupDir "$safe.reg"
    try {
        if (-not (Test-Path -LiteralPath $file)) {
            [IO.File]::WriteAllText($file, "Windows Registry Editor Version 5.00`r`n`r`n", [Text.Encoding]::Unicode)
        }
        $text = if ($T.IsValue) { Get-RegExportText $T.Hive $T.Path $T.ValueName -ValueOnly } else { Get-RegExportText $T.Hive $T.Path }
        [IO.File]::AppendAllText($file, $text, [Text.Encoding]::Unicode)
        [void]$script:ExportedKeys.Add($id)
        return $true
    } catch { return $false }
}

function Invoke-RegTarget($T) {
    $what = if ($T.IsValue) { "$($T.Name) [$(if ($T.ValueName) { $T.ValueName } else { '(default)' })]" } else { $T.Name }
    $k = Open-RegKey $T.Hive $T.Path
    if (-not $k) { return $true }   # already gone (e.g. parent deleted earlier)
    $k.Close()
    if (-not (Backup-RegistryTarget $T)) {
        $script:RegLogLines.Add("BACKUP FAILED, KEPT  $what")
        return $false
    }
    try {
        if ($T.IsValue) {
            $w = Open-RegKey $T.Hive $T.Path $true
            if ($w) { $w.DeleteValue($T.ValueName, $false); $w.Close() }
        } else {
            $RegHives[$T.Hive].DeleteSubKeyTree($T.Path, $false)
        }
        $script:RegLogLines.Add("deleted  $what")
        return $true
    } catch {
        $script:RegLogLines.Add("FAILED   $what : $($_.Exception.Message)")
        return $false
    }
}

# ===========================================================================
# Folder removal
# ===========================================================================
function Remove-FolderHard([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }

    # 1. Ownership and permissions
    if ($script:YesLetter) { & takeown.exe /f $Path /r /a /d $script:YesLetter 2>&1 | Out-Null }
    else                   { & takeown.exe /f $Path /a 2>&1 | Out-Null }
    & icacls.exe $Path /grant '*S-1-5-32-544:F' /t /c /q 2>&1 | Out-Null   # Administrators, by SID
    Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.Attributes = 'Normal' } catch { }
    }

    # 2. Normal delete
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue

    # 3. Long paths: mirror an empty folder over it
    if (Test-Path -LiteralPath $Path) {
        $empty = Join-Path $env:TEMP ('adobe-nuke-empty-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        & robocopy.exe $empty $Path /MIR /R:0 /W:0 /NFL /NDL /NJH /NJS /NP 2>&1 | Out-Null
        Remove-Item -LiteralPath $empty -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 4. Files still in use: move to quarantine on the same drive, delete at reboot
    if (Test-Path -LiteralPath $Path) {
        $root = [IO.Path]::GetPathRoot($Path)
        $quarantine = Join-Path $root "adobe-nuke-quarantine-$script:Stamp"
        New-Item -ItemType Directory -Path $quarantine -Force | Out-Null
        Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
            $dest = Join-Path $quarantine ([guid]::NewGuid().ToString('N').Substring(0, 8) + '_' + $_.Name)
            try {
                [IO.File]::Move($_.FullName, $dest)
                [void](Register-DeleteOnReboot $dest)
            } catch {
                [void](Register-DeleteOnReboot $_.FullName)
            }
        }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Get-ChildItem -LiteralPath $quarantine -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $quarantine -Force -ErrorAction SilentlyContinue
        } else {
            [void](Register-DeleteOnReboot $quarantine)
        }
    }

    # 5. Whatever is left
    if (Test-Path -LiteralPath $Path) {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -Directory -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object { [void](Register-DeleteOnReboot $_.FullName) }
        if (Register-DeleteOnReboot $Path) { Write-Item "REBOOT  $Path (in use, deleted at next restart)" 'Yellow' }
        else { Write-Fail $Path }
    } else {
        Write-Done "deleted $Path"
    }
}

# ===========================================================================
# Uninstall entries (used by -UninstallFirst and the registry cleanup)
# ===========================================================================
function Get-AdobeUninstallEntries {
    $roots = 'HKLM|SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
             'HKLM|SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
             'HKCU|Software\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($r in $roots) {
        $hive, $base = $r.Split('|')
        foreach ($sub in Get-RegSubKeys $hive $base) {
            $path = "$base\$sub"
            if ((Get-RegString $hive $path 'Publisher') -notmatch '^Adobe') { continue }
            $uninst = Get-RegString $hive $path 'UninstallString'
            [pscustomobject]@{
                Hive                 = $hive
                Path                 = $path
                Id                   = $sub
                DisplayName          = Get-RegString $hive $path 'DisplayName'
                UninstallString      = $uninst
                QuietUninstallString = Get-RegString $hive $path 'QuietUninstallString'
                IsMsi                = ($sub -match '^\{[0-9A-Fa-f\-]{36}\}$') -and
                                       (((Get-RegString $hive $path 'WindowsInstaller') -eq '1') -or ($uninst -match 'msiexec'))
            }
        }
    }
}

# ===========================================================================
# Main
# ===========================================================================
function Invoke-AdobeNuke {

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Request-Elevation
    Exit-Script
}

Write-Host ''
Write-Host "adobe-nuke $ScriptVersion" -ForegroundColor White
if ($DryRun) { Write-Host 'DRY RUN: nothing will be changed.' -ForegroundColor DarkYellow }

$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if (-not $DryRun) {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if (-not $docs -or -not (Test-Path -LiteralPath $docs)) { $docs = $env:USERPROFILE }
    $script:WorkDir = Join-Path $docs "adobe-nuke-$script:Stamp"
    $script:RegBackupDir = Join-Path $script:WorkDir 'registry-backup'
    $script:RegLog = Join-Path $script:WorkDir 'registry-changes.txt'
    New-Item -ItemType Directory -Path $script:RegBackupDir -Force | Out-Null
    try { Start-Transcript -Path (Join-Path $script:WorkDir 'log.txt') -ErrorAction Stop | Out-Null } catch { }
}

function Stop-Cancelled {
    Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Gray
    if ($script:WorkDir) {
        try { Stop-Transcript | Out-Null } catch { }
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        $script:WorkDir = $null
    }
    Exit-Script
}

# ===========================================================================
# Optional: official uninstallers first
# ===========================================================================
if ($UninstallFirst) {
    Write-Step 'Official uninstallers'
    $entries = @(Get-AdobeUninstallEntries | Where-Object { $_.UninstallString -or $_.QuietUninstallString })
    # The Creative Cloud desktop app goes last: the app uninstallers depend on it
    $entries = @($entries | Sort-Object { if ($_.DisplayName -match '^Adobe Creative Cloud$|^Creative Cloud') { 1 } else { 0 } })

    if (-not $entries.Count) {
        Write-Item 'No installed Adobe programs found.'
    } else {
        foreach ($e in $entries) { Write-Item ("{0}  ({1})" -f $e.DisplayName, $(if ($e.IsMsi) { 'silent' } else { 'may open a window' })) }
        if (-not (Confirm-Continue 'Run these uninstallers now?')) { Stop-Cancelled }

        foreach ($e in $entries) {
            if ($DryRun) { Write-Would "uninstall $($e.DisplayName)"; continue }
            if ($e.IsMsi) {
                Write-Item "Uninstalling $($e.DisplayName)..."
                $p = Start-Process msiexec.exe -ArgumentList "/x $($e.Id) /qn /norestart" -PassThru -Wait
                switch ($p.ExitCode) {
                    0       { Write-Done $e.DisplayName }
                    3010    { Write-Done "$($e.DisplayName) (restart required)"; $script:RebootNeeded = $true }
                    1605    { Write-Item "SKIP    $($e.DisplayName) (not actually installed)" }
                    1614    { Write-Item "SKIP    $($e.DisplayName) (already uninstalled)" }
                    default { Write-Item "FAILED  $($e.DisplayName) (msiexec $($p.ExitCode)), the cleanup will remove it" 'Yellow' }
                }
            } else {
                $cmd = if ($e.QuietUninstallString) { $e.QuietUninstallString } else { $e.UninstallString }
                Write-Item "Uninstalling $($e.DisplayName) (follow the window if one opens)..."
                $p = Start-Process cmd.exe -ArgumentList ('/d /s /c "' + $cmd + '"') -PassThru
                if ($p.WaitForExit(1800000)) { Write-Done $e.DisplayName }
                else { Write-Item "TIMEOUT $($e.DisplayName) still running after 30 min, continuing" 'Yellow' }
            }
        }
        if (-not $DryRun) { Start-Sleep -Seconds 5 }
    }
}

# ===========================================================================
# Discovery
# ===========================================================================
Write-Host ''
Write-Host 'Scanning (the registry scan can take a minute)...' -ForegroundColor Gray

$profiles = @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
    Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path -LiteralPath $_.LocalPath) } |
    Select-Object -ExpandProperty LocalPath)
if ($profiles.Count -eq 0) { $profiles = @($env:USERPROFILE) }

# ---- Folders
$candidates = New-Object System.Collections.Generic.List[string]
foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) | Where-Object { $_ }) {
    $candidates.Add((Join-Path $base 'Adobe'))
    $candidates.Add((Join-Path $base 'Common Files\Adobe'))
}
$candidates.Add((Join-Path $env:ProgramData 'Adobe'))
foreach ($p in $profiles) {
    $candidates.Add((Join-Path $p 'AppData\Roaming\Adobe'))
    $candidates.Add((Join-Path $p 'AppData\Local\Adobe'))
    $candidates.Add((Join-Path $p 'AppData\LocalLow\Adobe'))
    if ($IncludeDocuments) { $candidates.Add((Join-Path $p 'Documents\Adobe')) }
}
if ($IncludeDocuments) {
    # The current user's Documents folder may be redirected (OneDrive, another drive)
    $myDocs = [Environment]::GetFolderPath('MyDocuments')
    if ($myDocs) { $candidates.Add((Join-Path $myDocs 'Adobe')) }
}
$folders = @($candidates | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })

# ---- Services
$services = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match '^(AGSService|AGMService|AdobeARMservice|AdobeUpdateService)$' -or
    $_.DisplayName -match '^Adobe' -or
    (Test-AdobePath $_.PathName)
})

# ---- Scheduled tasks
$tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskName -match 'Adobe|Acrobat|CCXProcess' -or
    $_.TaskPath -match 'Adobe' -or
    @($_.Actions | Where-Object { $_.PSObject.Properties['Execute'] -and (Test-AdobePath $_.Execute) }).Count -gt 0
})

# ---- Processes
$processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and (Test-AdobePath $_.Path) })

# ---- Adobe DLLs loaded into other processes (Explorer shell extensions, Office add-ins)
$dllList = New-Object System.Collections.Generic.List[string]
foreach ($proc in Get-Process -ErrorAction SilentlyContinue) {
    if (Test-AdobePath $proc.Path) { continue }   # stopped anyway
    try { foreach ($m in $proc.Modules) { if (Test-AdobePath $m.FileName) { $dllList.Add($m.FileName) } } } catch { }
}
foreach ($f in $folders) {
    Get-ChildItem -LiteralPath $f -Recurse -Force -File -Include '*Shell*Ext*.dll', 'CoreSync*.dll', '*ContextMenu*.dll' -ErrorAction SilentlyContinue |
        ForEach-Object { $dllList.Add($_.FullName) }
}
$shellDlls = @($dllList | Where-Object { $_ -like '*.dll' } | Select-Object -Unique)

# ---- Shortcuts
$wsh = New-Object -ComObject WScript.Shell
$shortcutRoots = @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'), (Join-Path $env:PUBLIC 'Desktop'))
foreach ($p in $profiles) {
    $shortcutRoots += (Join-Path $p 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs')
    $shortcutRoots += (Join-Path $p 'Desktop')
}
$shortcutRoots = @($shortcutRoots | Where-Object { Test-Path -LiteralPath $_ })
$shortcuts = @(foreach ($r in $shortcutRoots) {
    Get-ChildItem -LiteralPath $r -Recurse -Force -Filter '*.lnk' -ErrorAction SilentlyContinue | Where-Object {
        $target = $null
        try { $target = $wsh.CreateShortcut($_.FullName).TargetPath } catch { }
        (Test-AdobePath $target) -or ($_.Name -match '^(Adobe |Acrobat)')
    }
})

# ---- Adobe PDF printer: printer, port, driver, port monitor
$printers = @(); $printerDrivers = @(); $printerPorts = @()
if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
    $printers = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Adobe PDF' -or $_.DriverName -match '^Adobe' })
    $printerDrivers = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Adobe' })
    $printerPorts = @(Get-PrinterPort -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match 'Adobe PDF' -or [string]$_.Description -match 'Adobe' -or [string]$_.PortMonitor -match 'Adobe'
    })
}
$monBase = 'SYSTEM\CurrentControlSet\Control\Print\Monitors'
$printMonitors = @(foreach ($m in Get-RegSubKeys 'HKLM' $monBase) {
    if ($m -match '^Adobe') {
        [pscustomobject]@{ Name = $m; Path = "$monBase\$m"; Driver = (Get-RegString 'HKLM' "$monBase\$m" 'Driver') }
    }
})
$pdfParts = $printers.Count + $printerPorts.Count + $printerDrivers.Count + $printMonitors.Count

# ---- Windows Installer: Adobe MSI products (installed or orphaned)
$uninstallEntries = @(Get-AdobeUninstallEntries)
$udProducts = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
$udPatches  = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Patches'
$packedCodes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($e in $uninstallEntries) {
    $pc = ConvertTo-PackedGuid $e.Id
    if ($pc) { [void]$packedCodes.Add($pc) }
}
foreach ($pc in Get-RegSubKeys 'HKLM' 'SOFTWARE\Classes\Installer\Products') {
    if ((Get-RegString 'HKLM' "SOFTWARE\Classes\Installer\Products\$pc" 'ProductName') -match '^Adobe|Acrobat') { [void]$packedCodes.Add($pc) }
}
foreach ($pc in Get-RegSubKeys 'HKLM' $udProducts) {
    if ((Get-RegString 'HKLM' "$udProducts\$pc\InstallProperties" 'Publisher') -match '^Adobe') { [void]$packedCodes.Add($pc) }
}

# ---- Caches
$cacheFiles = New-Object System.Collections.Generic.List[string]
$cacheDirs = New-Object System.Collections.Generic.List[string]
if (-not $SkipCache) {
    $installerDir = Join-Path $env:windir 'Installer'
    $msiSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    # Cached packages registered to Adobe products
    foreach ($pc in $packedCodes) {
        $lp = Get-RegString 'HKLM' "$udProducts\$pc\InstallProperties" 'LocalPackage'
        if ($lp) { [void]$msiSet.Add($lp) }
        foreach ($patch in Get-RegSubKeys 'HKLM' "$udProducts\$pc\Patches") {
            $pl = Get-RegString 'HKLM' "$udPatches\$patch" 'LocalPackage'
            if ($pl) { [void]$msiSet.Add($pl) }
        }
        $guid = ConvertFrom-PackedGuid $pc
        if ($guid) {
            $iconDir = Join-Path $installerDir $guid
            if (Test-Path -LiteralPath $iconDir) { $cacheDirs.Add($iconDir) }
        }
    }

    # Orphaned Adobe packages: read the author from each package's summary info
    try {
        $msi = New-Object -ComObject WindowsInstaller.Installer
        Get-ChildItem -Path (Join-Path $installerDir '*') -Include '*.msi', '*.msp' -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $si = $msi.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $msi, @($_.FullName, 0))
                $author  = [string]$si.GetType().InvokeMember('Property', 'GetProperty', $null, $si, @(4))
                $subject = [string]$si.GetType().InvokeMember('Property', 'GetProperty', $null, $si, @(3))
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($si)
                if ($author -match 'Adobe' -or $subject -match '^Adobe|Acrobat') { [void]$msiSet.Add($_.FullName) }
            } catch { }
        }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($msi)
    } catch { }

    foreach ($m in $msiSet) {
        # Only ever delete from the Installer cache folder itself
        if ($m.StartsWith($installerDir + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $m)) { $cacheFiles.Add($m) }
    }

    # Temp files
    $tempDirs = @(Join-Path $env:windir 'Temp')
    foreach ($p in $profiles) { $tempDirs += (Join-Path $p 'AppData\Local\Temp') }
    foreach ($t in ($tempDirs | Where-Object { Test-Path -LiteralPath $_ })) {
        Get-ChildItem -LiteralPath $t -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(Adobe|Acro|CreativeCloud|Creative Cloud|CoreSync|CCX|PDApp|AAMUpdater|AdobeGC|CEP)' } |
            ForEach-Object { if ($_.PSIsContainer) { $cacheDirs.Add($_.FullName) } else { $cacheFiles.Add($_.FullName) } }
    }

    # Prefetch
    $prefetch = Join-Path $env:windir 'Prefetch'
    Get-ChildItem -LiteralPath $prefetch -Filter '*.pf' -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(ADOBE|ACRO|CREATIVE CLOUD|CCXPROCESS|CCLIBRARY|CORESYNC|AGSSERVICE|AGMSERVICE|ARMSVC|PHOTOSHOP|ILLUSTRATOR|AFTERFX|INDESIGN|LIGHTROOM|AUDITION|ANIMATE|DREAMWEAVER|PDAPP)' } |
        ForEach-Object { $cacheFiles.Add($_.FullName) }
}
$cacheBytes = 0
foreach ($c in $cacheFiles) { try { $cacheBytes += (Get-Item -LiteralPath $c -Force).Length } catch { } }
foreach ($d in $cacheDirs) {
    try { $cacheBytes += (Get-ChildItem -LiteralPath $d -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } catch { }
}

# ---- Registry
$fwRules = @()
if (-not $SkipRegistry) {
    # Uninstall entries
    foreach ($e in $uninstallEntries) { Add-RegTarget 'Uninstall entries' $e.Hive $e.Path }

    # Windows Installer component records: one value (and sometimes a subkey) per
    # product using the component. Orphaned Adobe product codes are recognised from
    # component paths, but only if that product is no longer registered or is
    # registered as an Adobe product. This is the slowest scan (100k+ keys).
    $compBase = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components'
    $compCodes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($pc in $packedCodes) { [void]$compCodes.Add($pc) }
    $notAdobe = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $zeroCode = '0' * 32
    $compData = New-Object System.Collections.Generic.List[object]
    foreach ($ck in Get-RegSubKeys 'HKLM' $compBase) {
        $k = Open-RegKey 'HKLM' "$compBase\$ck"
        if (-not $k) { continue }
        try {
            $names = $k.GetValueNames()
            $zeroAdobe = $false
            foreach ($n in $names) {
                if (-not $n -or $compCodes.Contains($n) -or $notAdobe.Contains($n)) { continue }
                if (Test-AdobePath ([string]$k.GetValue($n))) {
                    # The all-zero code marks a permanent component of ANY product. It is
                    # not a product, so it is judged per value and never learned as a code.
                    if ($n -eq $zeroCode) { $zeroAdobe = $true; continue }
                    $pn = Get-RegString 'HKLM' "SOFTWARE\Classes\Installer\Products\$n" 'ProductName'
                    if (-not $pn -or $pn -match '^Adobe|Acrobat') { [void]$compCodes.Add($n) } else { [void]$notAdobe.Add($n) }
                }
            }
            $compData.Add([pscustomobject]@{ Key = $ck; Names = $names; Subs = $k.GetSubKeyNames(); ZeroAdobe = $zeroAdobe })
        } catch { } finally { $k.Close() }
    }
    foreach ($c in $compData) {
        $hits = @($c.Names | Where-Object { $_ -and ($compCodes.Contains($_) -or ($c.ZeroAdobe -and $_ -eq $zeroCode)) })
        $hitSubs = @($c.Subs | Where-Object { $compCodes.Contains($_) })
        if (-not ($hits.Count + $hitSubs.Count)) { continue }
        $others = @($c.Names | Where-Object { $_ -and $hits -notcontains $_ })
        $otherSubs = @($c.Subs | Where-Object { -not $compCodes.Contains($_) })
        if (-not ($others.Count + $otherSubs.Count)) {
            Add-RegTarget 'Installer components' 'HKLM' "$compBase\$($c.Key)"
        } else {
            foreach ($h in $hits) { Add-RegTarget 'Installer components' 'HKLM' "$compBase\$($c.Key)" $h -IsValue }
            foreach ($hs in $hitSubs) { Add-RegTarget 'Installer components' 'HKLM' "$compBase\$($c.Key)\$hs" }
        }
    }
    $compData = $null
    foreach ($pc in $compCodes) { [void]$packedCodes.Add($pc) }

    # Windows Installer registration
    foreach ($pc in $packedCodes) {
        Add-RegTarget 'Windows Installer' 'HKLM' "SOFTWARE\Classes\Installer\Products\$pc"
        Add-RegTarget 'Windows Installer' 'HKLM' "SOFTWARE\Classes\Installer\Features\$pc"
        foreach ($patch in Get-RegSubKeys 'HKLM' "$udProducts\$pc\Patches") { Add-RegTarget 'Windows Installer' 'HKLM' "$udPatches\$patch" }
        Add-RegTarget 'Windows Installer' 'HKLM' "$udProducts\$pc"
    }
    $ucBase = 'SOFTWARE\Classes\Installer\UpgradeCodes'
    foreach ($uc in Get-RegSubKeys 'HKLM' $ucBase) {
        $names = @(Get-RegValueNames 'HKLM' "$ucBase\$uc" | Where-Object { $_ })
        $hits = @($names | Where-Object { $packedCodes.Contains($_) })
        if ($hits.Count -and $hits.Count -eq $names.Count) { Add-RegTarget 'Windows Installer' 'HKLM' "$ucBase\$uc" }
        else { foreach ($h in $hits) { Add-RegTarget 'Windows Installer' 'HKLM' "$ucBase\$uc" $h -IsValue } }
    }

    # Adobe's own keys
    Add-RegTarget 'Adobe keys' 'HKLM' 'SOFTWARE\Adobe'
    Add-RegTarget 'Adobe keys' 'HKLM' 'SOFTWARE\WOW6432Node\Adobe'
    Add-RegTarget 'Adobe keys' 'HKCU' 'Software\Adobe'

    # COM classes pointing into Adobe files
    $badClsids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $badAppIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($spec in 'HKLM|SOFTWARE\Classes\CLSID', 'HKLM|SOFTWARE\Classes\WOW6432Node\CLSID', 'HKCU|Software\Classes\CLSID') {
        $hive, $base = $spec.Split('|')
        foreach ($c in Get-RegSubKeys $hive $base) {
            foreach ($srv in 'InprocServer32', 'LocalServer32') {
                if (Test-AdobePath (Get-RegString $hive "$base\$c\$srv")) {
                    [void]$badClsids.Add($c)
                    $appId = Get-RegString $hive "$base\$c" 'AppID'
                    if ($appId) { [void]$badAppIds.Add($appId) }
                    Add-RegTarget 'COM classes' $hive "$base\$c"
                    break
                }
            }
        }
    }

    # Type libraries registered from Adobe files
    foreach ($spec in 'HKLM|SOFTWARE\Classes\TypeLib', 'HKLM|SOFTWARE\Classes\WOW6432Node\TypeLib', 'HKCU|Software\Classes\TypeLib') {
        $hive, $base = $spec.Split('|')
        foreach ($tl in Get-RegSubKeys $hive $base) {
            $hit = $false
            foreach ($ver in Get-RegSubKeys $hive "$base\$tl") {
                foreach ($lcid in Get-RegSubKeys $hive "$base\$tl\$ver") {
                    if ($lcid -notmatch '^[0-9A-Fa-f]+$') { continue }   # skip FLAGS and HELPDIR
                    foreach ($plat in 'win32', 'win64', 'arm64') {
                        if (Test-AdobePath (Get-RegString $hive "$base\$tl\$ver\$lcid\$plat")) { $hit = $true; break }
                    }
                    if ($hit) { break }
                }
                if ($hit) { break }
            }
            if ($hit) { Add-RegTarget 'Type libraries' $hive "$base\$tl" }
        }
    }

    # AppIDs: referenced by Adobe COM classes, or named after Adobe programs (AcroDistX...)
    $appIdName = '^(Acro(?!nis)|Adobe|CoreSync|Creative ?Cloud)'
    foreach ($spec in 'HKLM|SOFTWARE\Classes\AppID', 'HKLM|SOFTWARE\Classes\WOW6432Node\AppID') {
        $hive, $base = $spec.Split('|')
        foreach ($a in Get-RegSubKeys $hive $base) {
            if ($a.StartsWith('{')) {
                $def = Get-RegString $hive "$base\$a"
                if ($badAppIds.Contains($a) -or ($def -and $def -match $appIdName)) { Add-RegTarget 'AppIDs' $hive "$base\$a" }
            } elseif ($a -match '\.exe$') {
                $ref = Get-RegString $hive "$base\$a" 'AppID'
                if ($a -match $appIdName -or ($ref -and $badAppIds.Contains($ref))) { Add-RegTarget 'AppIDs' $hive "$base\$a" }
            }
        }
    }

    # File types (ProgIDs) opened by Adobe programs
    $protectedClasses = '^(\*|Directory|Folder|Drive|AllFilesystemObjects|DesktopBackground|Unknown|CLSID|Interface|TypeLib|AppID|Installer|WOW6432Node|Applications)$'
    $badProgIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $classRoots = 'HKLM|SOFTWARE\Classes', 'HKCU|Software\Classes'
    foreach ($spec in $classRoots) {
        $hive, $base = $spec.Split('|')
        foreach ($n in Get-RegSubKeys $hive $base) {
            if ($n.StartsWith('.') -or $n -match $protectedClasses) { continue }
            $cmd = Get-RegString $hive "$base\$n\shell\open\command"
            $clsid = Get-RegString $hive "$base\$n\CLSID"
            if ((Test-AdobePath $cmd) -or ($clsid -and $badClsids.Contains($clsid))) {
                [void]$badProgIds.Add($n)
                Add-RegTarget 'File types' $hive "$base\$n"
            }
        }
        foreach ($n in Get-RegSubKeys $hive "$base\Applications") {
            if (Test-AdobePath (Get-RegString $hive "$base\Applications\$n\shell\open\command")) {
                Add-RegTarget 'File types' $hive "$base\Applications\$n"
            }
        }
    }
    # Extensions pointing at those ProgIDs (the extension key itself is kept)
    foreach ($spec in $classRoots) {
        $hive, $base = $spec.Split('|')
        foreach ($n in (Get-RegSubKeys $hive $base | Where-Object { $_.StartsWith('.') })) {
            $def = Get-RegString $hive "$base\$n"
            if ($def -and $badProgIds.Contains($def)) { Add-RegTarget 'File types' $hive "$base\$n" '' -IsValue }
            foreach ($v in Get-RegValueNames $hive "$base\$n\OpenWithProgids") {
                if ($v -and $badProgIds.Contains($v)) { Add-RegTarget 'File types' $hive "$base\$n\OpenWithProgids" $v -IsValue }
            }
        }
    }
    $fe = 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
    foreach ($ext in Get-RegSubKeys 'HKCU' $fe) {
        foreach ($v in Get-RegValueNames 'HKCU' "$fe\$ext\OpenWithProgids") {
            if ($v -and $badProgIds.Contains($v)) { Add-RegTarget 'File types' 'HKCU' "$fe\$ext\OpenWithProgids" $v -IsValue }
        }
    }

    # Explorer hooks: context menus, drag-drop, property sheets, overlays, BHOs
    $hookName = 'Adobe|Acrobat|CoreSync|CCLibrary|Creative Cloud'
    foreach ($cls in '*', 'Directory', 'Directory\Background', 'Folder', 'AllFilesystemObjects', 'Drive', 'lnkfile') {
        foreach ($h in 'ContextMenuHandlers', 'DragDropHandlers', 'PropertySheetHandlers', 'CopyHookHandlers') {
            $p = "SOFTWARE\Classes\$cls\shellex\$h"
            foreach ($s in Get-RegSubKeys 'HKLM' $p) {
                $d = Get-RegString 'HKLM' "$p\$s"
                if ($badClsids.Contains($s) -or ($d -and $badClsids.Contains($d)) -or $s -match $hookName) { Add-RegTarget 'Explorer hooks' 'HKLM' "$p\$s" }
            }
        }
    }
    foreach ($cv in 'SOFTWARE\Microsoft\Windows\CurrentVersion', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion') {
        $p = "$cv\Explorer\ShellIconOverlayIdentifiers"
        foreach ($s in Get-RegSubKeys 'HKLM' $p) {
            $d = Get-RegString 'HKLM' "$p\$s"
            if (($d -and $badClsids.Contains($d)) -or $s -match $hookName) { Add-RegTarget 'Explorer hooks' 'HKLM' "$p\$s" }
        }
        $p = "$cv\Explorer\Browser Helper Objects"
        foreach ($s in Get-RegSubKeys 'HKLM' $p) { if ($badClsids.Contains($s)) { Add-RegTarget 'Explorer hooks' 'HKLM' "$p\$s" } }
        $p = "$cv\Shell Extensions\Approved"
        foreach ($v in Get-RegValueNames 'HKLM' $p) { if ($v -and $badClsids.Contains($v)) { Add-RegTarget 'Explorer hooks' 'HKLM' $p $v -IsValue } }

        # App Paths
        $p = "$cv\App Paths"
        foreach ($s in Get-RegSubKeys 'HKLM' $p) { if (Test-AdobePath (Get-RegString 'HKLM' "$p\$s")) { Add-RegTarget 'App Paths' 'HKLM' "$p\$s" } }
    }

    # Autostart
    foreach ($spec in 'HKLM|SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                      'HKLM|SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
                      'HKCU|Software\Microsoft\Windows\CurrentVersion\Run') {
        $hive, $p = $spec.Split('|')
        foreach ($v in Get-RegValueNames $hive $p) {
            if ($v -and (Test-AdobePath (Get-RegString $hive $p $v))) { Add-RegTarget 'Autostart' $hive $p $v -IsValue }
        }
    }

    # Firewall rules
    if (Get-Command Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue) {
        $fwRules = @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
            Where-Object { Test-AdobePath $_.Program } |
            Get-NetFirewallRule -ErrorAction SilentlyContinue)
    }
}

# ===========================================================================
# Plan
# ===========================================================================
$total = $folders.Count + $services.Count + $tasks.Count + $processes.Count + $shellDlls.Count + $shortcuts.Count +
         $pdfParts + $script:RegTargets.Count + $fwRules.Count + $cacheFiles.Count + $cacheDirs.Count

if ($total -eq 0) {
    Write-Host ''
    Write-Host 'No Adobe leftovers found.' -ForegroundColor Green
    if ($script:WorkDir) {
        try { Stop-Transcript | Out-Null } catch { }
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        $script:WorkDir = $null
    }
    Exit-Script
}

Write-Step 'Found'
$stillInstalled = @($uninstallEntries | Where-Object { $_.DisplayName })
if ($stillInstalled.Count) {
    Write-Item 'Registered as installed (will be removed by force):' 'Yellow'
    foreach ($e in $stillInstalled) { Write-Item "  $($e.DisplayName)" 'Yellow' }
}
Write-Item ("Services:              {0}" -f $services.Count)
Write-Item ("Scheduled tasks:       {0}" -f $tasks.Count)
Write-Item ("Processes:             {0}" -f $processes.Count)
Write-Item ("Shell extensions:      {0}" -f $shellDlls.Count)
Write-Item ("Shortcuts:             {0}" -f $shortcuts.Count)
Write-Item ("Adobe PDF printer:     {0} printer, {1} port, {2} driver, {3} monitor" -f $printers.Count, $printerPorts.Count, $printerDrivers.Count, $printMonitors.Count)
if (-not $SkipCache) {
    Write-Item ("Cache files / folders: {0} / {1}  ({2})" -f $cacheFiles.Count, $cacheDirs.Count, (Format-Size $cacheBytes))
}
if (-not $SkipRegistry) {
    Write-Item ("Firewall rules:        {0}" -f $fwRules.Count)
    Write-Item ("Registry entries:      {0}" -f $script:RegTargets.Count)
    foreach ($g in ($script:RegTargets | Group-Object Category)) { Write-Item ("  {0,-20} {1}" -f $g.Name, $g.Count) 'DarkGray' }
}
Write-Item 'Folders:'
foreach ($f in $folders) { Write-Item "  $f" }
if (-not $folders.Count) { Write-Item '  none' }

if (-not $DryRun -and -not $Force) {
    Write-Host ''
    Write-Host 'This removes ALL Adobe software, including Acrobat Reader.' -ForegroundColor Yellow
    Write-Host 'Your "Creative Cloud Files" folder is not touched.' -ForegroundColor Yellow
    if (-not (Confirm-Continue 'Continue?')) { Stop-Cancelled }
}

# ===========================================================================
# 1. Services
# ===========================================================================
Write-Step 'Services'
foreach ($s in $services) {
    if ($DryRun) { Write-Would "stop and delete service $($s.Name)"; continue }
    Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
    Set-Service -Name $s.Name -StartupType Disabled -ErrorAction SilentlyContinue
    if ($s.ProcessId) { Stop-Process -Id $s.ProcessId -Force -ErrorAction SilentlyContinue }
    & sc.exe delete $s.Name 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1072) { Write-Done "service $($s.Name)" }   # 1072 = marked for deletion
    else { Write-Fail "service $($s.Name) (sc.exe exit $LASTEXITCODE)" }
}
if (-not $services.Count) { Write-Item 'none' }

# ===========================================================================
# 2. Scheduled tasks
# ===========================================================================
Write-Step 'Scheduled tasks'
foreach ($t in $tasks) {
    if ($DryRun) { Write-Would "delete task $($t.TaskPath)$($t.TaskName)"; continue }
    try {
        Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
        Write-Done "task $($t.TaskName)"
    } catch { Write-Fail "task $($t.TaskName): $($_.Exception.Message)" }
}
if (-not $tasks.Count) { Write-Item 'none' }

# ===========================================================================
# 3. Processes
# ===========================================================================
Write-Step 'Processes'
foreach ($p in $processes) {
    if ($DryRun) { Write-Would "stop $($p.ProcessName) ($($p.Id))"; continue }
    try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; Write-Done "$($p.ProcessName) ($($p.Id))" }
    catch { if (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) { Write-Fail "$($p.ProcessName): $($_.Exception.Message)" } }
}
if (-not $processes.Count) { Write-Item 'none' }

# ===========================================================================
# 4. Shell extensions + Explorer restart
# ===========================================================================
Write-Step 'Shell extensions'
foreach ($dll in $shellDlls) {
    if ($DryRun) { Write-Would "unregister $dll"; continue }
    & regsvr32.exe /u /s $dll 2>&1 | Out-Null
    Write-Done "unregistered $dll"
}
if (-not $shellDlls.Count) { Write-Item 'none' }
elseif (-not $DryRun) {
    Write-Item 'Restarting Explorer (the taskbar will blink)...'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Start-Sleep -Seconds 2
}

# ===========================================================================
# 5. Printer
# ===========================================================================
if ($pdfParts) {
    Write-Step 'Adobe PDF printer'
    foreach ($pr in $printers) {
        if ($DryRun) { Write-Would "remove printer $($pr.Name)"; continue }
        try { Remove-Printer -Name $pr.Name -ErrorAction Stop; Write-Done "printer $($pr.Name)" }
        catch { Write-Fail "printer $($pr.Name): $($_.Exception.Message)" }
    }
    # Ports of the Adobe port monitor cannot be removed one by one: they disappear
    # with the monitor. A failure here is only final if the port is still there
    # after the monitor has been removed.
    $pendingPorts = @()
    foreach ($pp in $printerPorts) {
        if ($DryRun) { Write-Would "remove port $($pp.Name)"; continue }
        try { Remove-PrinterPort -Name $pp.Name -ErrorAction Stop; Write-Done "port $($pp.Name)" }
        catch {
            if ($printMonitors.Count) { $pendingPorts += [pscustomobject]@{ Name = $pp.Name; Message = $_.Exception.Message } }
            else { Write-Fail "port $($pp.Name): $($_.Exception.Message)" }
        }
    }
    foreach ($d in $printerDrivers) {
        if ($DryRun) { Write-Would "remove driver $($d.Name)"; continue }
        try { Remove-PrinterDriver -Name $d.Name -ErrorAction Stop; Write-Done "driver $($d.Name)" }
        catch { Write-Fail "driver $($d.Name): $($_.Exception.Message)" }
    }
    if ($printMonitors.Count) {
        if ($DryRun) {
            foreach ($m in $printMonitors) { Write-Would "remove port monitor $($m.Name)" }
        } else {
            # A port monitor is loaded by the spooler, so it is removed with the spooler stopped
            Write-Item 'Stopping the print spooler for a moment...'
            Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
            foreach ($m in $printMonitors) {
                $t = [pscustomobject]@{ Category = 'Print monitors'; Hive = 'HKLM'; Path = $m.Path; ValueName = ''; IsValue = $false
                                        Name = "HKEY_LOCAL_MACHINE\$($m.Path)" }
                if (Invoke-RegTarget $t) { Write-Done "port monitor $($m.Name)" } else { Write-Fail "port monitor $($m.Name)" }
                if ($m.Driver -and $m.Driver -match 'Adobe|Acro') {
                    $dll = Join-Path ([Environment]::SystemDirectory) (Split-Path $m.Driver -Leaf)
                    if (Test-Path -LiteralPath $dll) {
                        try { Remove-Item -LiteralPath $dll -Force -ErrorAction Stop; Write-Done "deleted $dll" }
                        catch { if (Register-DeleteOnReboot $dll) { Write-Item "REBOOT  $dll" 'Yellow' } }
                    }
                }
            }
            Start-Service -Name Spooler -ErrorAction SilentlyContinue
            if ($pendingPorts.Count) {
                $portsNow = $null
                try { $portsNow = @(Get-PrinterPort -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { }
                foreach ($pp in $pendingPorts) {
                    if ($null -ne $portsNow -and $portsNow -notcontains $pp.Name) { Write-Done "port $($pp.Name) (removed with its port monitor)" }
                    else { Write-Fail "port $($pp.Name): $($pp.Message)" }
                }
            }
        }
    }
}

# ===========================================================================
# 6. Folders
# ===========================================================================
Write-Step 'Folders'
if (-not $DryRun -and $folders.Count) { $script:YesLetter = Get-TakeownYesLetter }
foreach ($f in $folders) {
    if ($DryRun) { Write-Would "delete $f"; continue }
    Remove-FolderHard $f
}
if (-not $folders.Count) { Write-Item 'none' }

# ===========================================================================
# 7. Shortcuts
# ===========================================================================
Write-Step 'Shortcuts'
foreach ($s in $shortcuts) {
    if ($DryRun) { Write-Would "delete $($s.FullName)"; continue }
    try { Remove-Item -LiteralPath $s.FullName -Force -ErrorAction Stop; Write-Done $s.FullName }
    catch { Write-Fail "$($s.FullName): $($_.Exception.Message)" }
}
if (-not $DryRun) {
    foreach ($r in $shortcutRoots) {
        Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(Adobe|Acrobat)' -and -not (Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -File -ErrorAction SilentlyContinue) } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
if (-not $shortcuts.Count) { Write-Item 'none' }

# ===========================================================================
# 8. Caches
# ===========================================================================
if (-not $SkipCache) {
    Write-Step 'Caches'
    if ($DryRun) {
        foreach ($c in $cacheFiles) { Write-Would "delete $c" }
        foreach ($d in $cacheDirs)  { Write-Would "delete $d" }
    } else {
        $okCount = 0; $laterCount = 0
        foreach ($c in $cacheFiles) {
            try { Remove-Item -LiteralPath $c -Force -ErrorAction Stop; $okCount++ }
            catch { if (Register-DeleteOnReboot $c) { $laterCount++ } }
        }
        foreach ($d in $cacheDirs) {
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $d) { if (Register-DeleteOnReboot $d) { $laterCount++ } } else { $okCount++ }
        }
        Write-Done ("{0} items removed, {1} freed" -f $okCount, (Format-Size $cacheBytes))
        if ($laterCount) { Write-Item "REBOOT  $laterCount items in use, deleted at next restart" 'Yellow' }
    }
    if (-not ($cacheFiles.Count + $cacheDirs.Count)) { Write-Item 'none' }
}

# ===========================================================================
# 9. Firewall + registry
# ===========================================================================
if (-not $SkipRegistry) {
    Write-Step 'Firewall rules'
    foreach ($r in $fwRules) {
        if ($DryRun) { Write-Would "remove rule '$($r.DisplayName)'"; continue }
        try { Remove-NetFirewallRule -Name $r.Name -ErrorAction Stop; Write-Done "rule '$($r.DisplayName)'" }
        catch { Write-Fail "rule '$($r.DisplayName)': $($_.Exception.Message)" }
    }
    if (-not $fwRules.Count) { Write-Item 'none' }

    Write-Step 'Registry'
    if (-not $script:RegTargets.Count) { Write-Item 'none' }
    foreach ($g in ($script:RegTargets | Group-Object Category)) {
        if ($DryRun) {
            $shown = 0
            foreach ($t in $g.Group) {
                $label = if ($t.IsValue) { "$($t.Name) [$(if ($t.ValueName) { $t.ValueName } else { '(default)' })]" } else { $t.Name }
                $script:DryRunLines.Add("$($g.Name)`t$label")
                if ($shown -lt 10) { Write-Would "delete $label"; $shown++ }
            }
            if ($g.Count -gt 10) { Write-Item ("        ... and {0} more {1}" -f ($g.Count - 10), $g.Name) 'DarkYellow' }
            continue
        }
        $ok = 0; $bad = 0
        foreach ($t in $g.Group) { if (Invoke-RegTarget $t) { $ok++ } else { $bad++ } }
        if ($bad) { Write-Fail ("{0}: {1} removed, {2} failed (see registry-changes.txt)" -f $g.Name, $ok, $bad) }
        else      { Write-Done ("{0}: {1} removed" -f $g.Name, $ok) }
    }
}

# ===========================================================================
# Summary
# ===========================================================================
Write-Host ''
if ($DryRun) {
    if ($script:DryRunLines.Count) {
        # The name must not start with "adobe": the temp cleanup would list it.
        $listFile = Join-Path $env:TEMP 'dryrun-adobe-nuke-registry.txt'
        [IO.File]::WriteAllLines($listFile, $script:DryRunLines)
        Write-Host "Full list of registry entries: $listFile" -ForegroundColor DarkYellow
    }
    Write-Host 'Dry run finished. Run again without -DryRun to remove everything listed above.' -ForegroundColor DarkYellow
} else {
    $left = @($folders | Where-Object { Test-Path -LiteralPath $_ })
    if ($script:Errors -eq 0 -and $left.Count -eq 0 -and -not $script:RebootNeeded) {
        Write-Host 'Done. All Adobe leftovers were removed.' -ForegroundColor Green
    } elseif ($script:RebootNeeded) {
        Write-Host 'Done. A few files were still in use: restart Windows to finish.' -ForegroundColor Yellow
    } else {
        Write-Host "Finished with $($script:Errors) error(s). See the log for details." -ForegroundColor Yellow
    }
    if ($script:RegLogLines.Count) { [IO.File]::WriteAllLines($script:RegLog, $script:RegLogLines) }
    Write-Host "Log and registry backup: $script:WorkDir" -ForegroundColor Gray
    Write-Host 'To undo registry changes, double-click the matching .reg file in registry-backup.' -ForegroundColor Gray
}

Exit-Script
}

try { Invoke-AdobeNuke } catch [System.OperationCanceledException] { }
