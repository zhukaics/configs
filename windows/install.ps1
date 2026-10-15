#Requires -Version 7.0

$ErrorActionPreference = 'Stop'

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'WinGet is required. Install or update App Installer from the Microsoft Store.'
}

function Backup-File {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $backupPath = "$Path.bak"
    if (Test-Path -LiteralPath $backupPath) {
        $backupPath = "$Path.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    }

    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    Write-Host "Backed up $Path to $backupPath."
}

function Install-WinGetPackage {
    param(
        [Parameter(Mandatory)]
        [string] $Id
    )

    winget list --id $Id --exact --accept-source-agreements --disable-interactivity | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$Id is already installed."
        return
    }

    Write-Host "Installing $Id..."
    winget install `
        --id $Id `
        --exact `
        --source winget `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install $Id (WinGet exit code: $LASTEXITCODE)."
    }
}

Install-WinGetPackage -Id 'Microsoft.VisualStudioCode.Insiders'
Install-WinGetPackage -Id 'Neovim.Neovim'
Install-WinGetPackage -Id 'JanDeDobbeleer.OhMyPosh'
Install-WinGetPackage -Id 'Microsoft.WindowsTerminal'

$ohMyPoshCandidates = @(
    (Get-Command oh-my-posh -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
    (Join-Path $env:LOCALAPPDATA 'Programs\oh-my-posh\bin\oh-my-posh.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\oh-my-posh.exe'),
    (Join-Path $env:ProgramFiles 'oh-my-posh\bin\oh-my-posh.exe')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }

$ohMyPosh = $ohMyPoshCandidates | Select-Object -First 1
if (-not $ohMyPosh) {
    throw 'Oh My Posh was installed, but oh-my-posh.exe could not be found. Restart PowerShell and run this script again.'
}

$nerdFont = 'MesloLGM Nerd Font Mono'
Add-Type -AssemblyName System.Drawing
$installedFonts = [System.Drawing.Text.InstalledFontCollection]::new()
try {
    $fontInstalled = $nerdFont -in $installedFonts.Families.Name
}
finally {
    $installedFonts.Dispose()
}

if (-not $fontInstalled) {
    Write-Host 'Installing Meslo Nerd Font...'
    # A direct archive URL avoids the GitHub API release-discovery request.
    $fontArchiveUrl = 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip'
    & $ohMyPosh font install $fontArchiveUrl
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install Meslo Nerd Font from $fontArchiveUrl (exit code: $LASTEXITCODE). Run oh-my-posh font install '$fontArchiveUrl' --trace for diagnostics."
    }
}

$windowsTerminalSettingsPaths = @(
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
)

New-Item -ItemType Directory -Path (Split-Path -Parent $windowsTerminalSettingsPaths[0]) -Force | Out-Null

foreach ($settingsPath in $windowsTerminalSettingsPaths) {
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $settingsPath) -PathType Container)) {
        continue
    }

    $settings = @{}
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
        if ($null -eq $settings -or $settings -isnot [System.Collections.IDictionary]) {
            throw "Expected a JSON object in Windows Terminal settings at $settingsPath."
        }
        Backup-File -Path $settingsPath
    }

    if (-not $settings.Contains('profiles')) {
        $settings['profiles'] = @{}
    }
    if (-not $settings['profiles'].Contains('defaults')) {
        $settings['profiles']['defaults'] = @{}
    }
    # Remove our per-user font overrides: packaged Terminal can fail to initialize them.
    foreach ($terminalProfile in @($settings['profiles']['defaults']) + @($settings['profiles']['list'])) {
        if ($terminalProfile -and $terminalProfile['font'] -and $terminalProfile['font']['face'] -eq $nerdFont) {
            $terminalProfile['font'].Remove('face')
            if ($terminalProfile['font'].Count -eq 0) {
                $terminalProfile.Remove('font')
            }
        }
    }

    $powerShellProfile = $settings['profiles']['list'] |
        Where-Object {
            $null -ne $_ -and (
                $_['source'] -eq 'Windows.Terminal.PowershellCore' -or
                $_['guid'] -eq '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
            )
        } |
        Select-Object -First 1
    if (-not $powerShellProfile) {
        $powerShellProfile = @{
            guid        = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
            name        = 'PowerShell'
            source      = 'Windows.Terminal.PowershellCore'
            commandline = '"{0}"' -f (Join-Path $PSHOME 'pwsh.exe')
        }
        $settings['profiles']['list'] = @(
            $settings['profiles']['list'] | Where-Object { $null -ne $_ }
        ) + $powerShellProfile
    }
    $powerShellProfile['hidden'] = $false
    $settings['defaultProfile'] = $powerShellProfile['guid']

    # Use the same PowerShell 7 profile for startup and newly opened tabs.
    $settings['firstWindowPreference'] = 'defaultProfile'
    $settings['startupActions'] = 'new-tab -p "{0}"; split-pane -V -s 0.3 -p "{0}"; move-focus left' -f $settings['defaultProfile']

    $settings | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $settingsPath -Encoding utf8
    Write-Host "Configured Windows Terminal with PowerShell 7 and a 70/30 startup layout at $settingsPath."
}

$documentsDirectory = [Environment]::GetFolderPath('MyDocuments')
$powerShellProfilePaths = @(
    (Join-Path $documentsDirectory 'PowerShell\profile.ps1'),
    (Join-Path $documentsDirectory 'WindowsPowerShell\profile.ps1')
)

foreach ($profilePath in $powerShellProfilePaths) {
    $profileContent = ''
    if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
        $profileContent = Get-Content -LiteralPath $profilePath -Raw
    }
    if ($profileContent -match '(?m)^\s*(?:&\s+)?oh-my-posh(?:\.exe)?\s+init\b') {
        Write-Host "Oh My Posh is already configured at $profilePath."
        continue
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $profilePath) -Force | Out-Null
    Backup-File -Path $profilePath
    Set-Content -LiteralPath $profilePath `
        -Value ($profileContent + "`noh-my-posh init pwsh | Invoke-Expression") `
        -Encoding utf8BOM
    Write-Host "Configured Oh My Posh at $profilePath."
}

$codeInsidersCandidates = @(
    (Get-Command code-insiders.cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
    (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd'),
    (Join-Path $env:ProgramFiles 'Microsoft VS Code Insiders\bin\code-insiders.cmd')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }

$codeInsiders = $codeInsidersCandidates | Select-Object -First 1
if (-not $codeInsiders) {
    throw 'VS Code Insiders was installed, but code-insiders.cmd could not be found.'
}

Write-Host 'Installing the VSCodeVim extension...'
& $codeInsiders --install-extension 'vscodevim.vim' --force
if ($LASTEXITCODE -ne 0) {
    throw "Failed to install the VSCodeVim extension (exit code: $LASTEXITCODE)."
}

$vsCodeSettingsDirectory = Join-Path $env:APPDATA 'Code - Insiders\User'
$vsCodeSettingsPath = Join-Path $vsCodeSettingsDirectory 'settings.json'
$vsCodeSettings = [ordered]@{
    'vim.vimrc.enable'            = $false
    'editor.lineNumbers'          = 'on'
    'editor.renderWhitespace'     = 'all'
    'editor.renderControlCharacters' = $true
    'files.encoding'              = 'utf8'
    'workbench.colorTheme'        = 'Solarized Dark'
    'terminal.integrated.fontFamily' = $nerdFont
    '[json]'                      = [ordered]@{
        'editor.insertSpaces' = $true
        'editor.tabSize'      = 2
    }
    '[typescript]'                = [ordered]@{
        'editor.insertSpaces' = $true
        'editor.tabSize'      = 2
    }
}

New-Item -ItemType Directory -Path $vsCodeSettingsDirectory -Force | Out-Null
if (Test-Path -LiteralPath $vsCodeSettingsPath -PathType Leaf) {
    Backup-File -Path $vsCodeSettingsPath

    try {
        $existingVsCodeSettings = Get-Content -LiteralPath $vsCodeSettingsPath -Raw |
            ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "Could not parse existing VS Code Insiders settings at ${vsCodeSettingsPath}: $_"
    }

    foreach ($setting in $vsCodeSettings.GetEnumerator()) {
        $existingVsCodeSettings[$setting.Key] = $setting.Value
    }
    $vsCodeSettings = $existingVsCodeSettings
}

$vsCodeSettings |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $vsCodeSettingsPath -Encoding utf8
Write-Host "Configured VS Code Insiders at $vsCodeSettingsPath."

$neovimConfigDirectory = Join-Path $env:LOCALAPPDATA 'nvim'
$neovimConfigPath = Join-Path $neovimConfigDirectory 'init.vim'
$neovimColorsDirectory = Join-Path $neovimConfigDirectory 'colors'
$solarizedPath = Join-Path $neovimColorsDirectory 'solarized.vim'
$vimrcPath = Join-Path $PSScriptRoot '..\vim\.vimrc'

if (-not (Test-Path -LiteralPath $vimrcPath -PathType Leaf)) {
    throw "Vim configuration not found: $vimrcPath"
}

$vimrcPath = (Resolve-Path -LiteralPath $vimrcPath).Path

New-Item -ItemType Directory -Path $neovimConfigDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $neovimColorsDirectory -Force | Out-Null

Backup-File -Path $neovimConfigPath

Invoke-WebRequest `
    -Uri 'https://raw.githubusercontent.com/altercation/vim-colors-solarized/master/colors/solarized.vim' `
    -OutFile $solarizedPath

$initVim = @(
    '" Generated by configs/windows/install.ps1 - edit vim/.vimrc instead.',
    "execute 'source ' . fnameescape('$($vimrcPath -replace "'", "''")')"
)
Set-Content -LiteralPath $neovimConfigPath -Value $initVim -Encoding utf8
Write-Host "Neovim now sources $vimrcPath from $neovimConfigPath."
