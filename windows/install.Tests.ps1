BeforeAll {
    $installerPath = Join-Path $PSScriptRoot 'install.ps1'
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $installerPath, [ref] $null, [ref] $parseErrors
    )
    if ($parseErrors) {
        throw ($parseErrors | Out-String)
    }

    # Run only Terminal configuration, never package installation or user profile setup.
    $statements = $ast.EndBlock.Statements
    $start = $statements | Where-Object {
        $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left.Extent.Text -eq '$windowsTerminalSettingsPaths'
    }
    $end = $statements | Where-Object {
        $_ -is [System.Management.Automation.Language.ForEachStatementAst] -and
        $_.Variable.VariablePath.UserPath -eq 'settingsPath'
    }
    if (-not $start -or -not $end) {
        throw 'Could not locate the Terminal configuration section.'
    }
    $script:configureTerminal = [scriptblock]::Create(
        ($statements | Where-Object {
            $_.Extent.StartOffset -ge $start.Extent.StartOffset -and
            $_.Extent.EndOffset -le $end.Extent.EndOffset
        } | ForEach-Object { $_.Extent.Text }) -join "`n"
    )
    $backupFunction = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Backup-File'
    }, $false)
    . ([scriptblock]::Create($backupFunction.Extent.Text))

    $fontInstall = $statements | Where-Object {
        $_ -is [System.Management.Automation.Language.IfStatementAst] -and
        $_.Clauses[0].Item1.Extent.Text -eq '-not $fontInstalled'
    }
    if (-not $fontInstall) {
        throw 'Could not locate the font installation section.'
    }
    $script:installFont = [scriptblock]::Create($fontInstall.Extent.Text)
    function Invoke-TestFontInstaller {
        param($Command, $Action, $Archive)
    }
}

Describe 'Meslo font installation' {
    BeforeEach {
        $ohMyPosh = 'Invoke-TestFontInstaller'
        $fontInstalled = $false
        $savedExitCode = $global:LASTEXITCODE
        Mock Invoke-TestFontInstaller { $global:LASTEXITCODE = 0 }
    }

    AfterEach {
        $global:LASTEXITCODE = $savedExitCode
    }

    It 'installs directly from the official archive without looking up a release by font name' {
        & $installFont

        Should -Invoke Invoke-TestFontInstaller -Times 1 -Exactly -ParameterFilter {
            $Command -eq 'font' -and $Action -eq 'install' -and
            $Archive -eq 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip'
        }
    }

    It 'still stops on installation failure and explains how to get diagnostics' {
        Mock Invoke-TestFontInstaller { $global:LASTEXITCODE = 70 }

        { & $installFont } | Should -Throw '*exit code: 70*--trace*'
    }

    It 'does not reinstall a font that is already present' {
        $fontInstalled = $true

        & $installFont

        Should -Invoke Invoke-TestFontInstaller -Times 0 -Exactly
    }
}

Describe 'Windows Terminal setup' {
    BeforeEach {
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $settingsPath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
        $nerdFont = 'MesloLGM Nerd Font Mono'
    }

    AfterEach {
        $env:LOCALAPPDATA = $originalLocalAppData
    }

    It 'replaces a legacy default while preserving existing profiles and settings' {
        $legacyGuid = '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}'
        $modernGuid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
        $original = @{
            defaultProfile = $legacyGuid
            copyOnSelect = $true
            profiles = @{
                defaults = @{ font = @{ face = $nerdFont; size = 14 } }
                list = @(
                    @{ guid = $legacyGuid; name = 'Windows PowerShell'; commandline = 'powershell.exe' },
                    @{
                        guid = $modernGuid
                        name = 'My renamed PowerShell'
                        source = 'Windows.Terminal.PowershellCore'
                        font = @{ face = $nerdFont; weight = 'semi-bold' }
                    }
                )
            }
        } | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath $settingsPath -Value $original

        & $configureTerminal

        $result = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
        $result.defaultProfile | Should -Be $modernGuid
        $result.startupActions | Should -Be (
            'new-tab -p "{0}"; split-pane -V -s 0.3 -p "{0}"; move-focus left' -f $modernGuid
        )
        $result.profiles.list.Count | Should -Be 2
        $result.profiles.list[0].commandline | Should -Be 'powershell.exe'
        $result.profiles.list[1].name | Should -Be 'My renamed PowerShell'
        $result.profiles.defaults.font.Contains('face') | Should -BeFalse
        $result.profiles.defaults.font.size | Should -Be 14
        $result.profiles.list[1].font.Contains('face') | Should -BeFalse
        $result.profiles.list[1].font.weight | Should -Be 'semi-bold'
        $result.copyOnSelect | Should -BeTrue
        (Get-Content -LiteralPath "$settingsPath.bak" -Raw).TrimEnd() | Should -Be $original
    }

    It 'creates a usable PowerShell profile on first setup and stays idempotent' {
        & $configureTerminal
        & $configureTerminal

        $result = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
        $result.profiles.list.Count | Should -Be 1
        $profile = $result.profiles.list[0]
        $result.defaultProfile | Should -Be $profile.guid
        $profile.commandline | Should -Be ('"{0}"' -f (Join-Path $PSHOME 'pwsh.exe'))
        $profile.hidden | Should -BeFalse
        $result.profiles.defaults.Contains('font') | Should -BeFalse
    }

    It 'removes font-only Meslo overrides without replacing other chosen fonts' {
        @{
            profiles = @{
                defaults = @{ font = @{ face = $nerdFont } }
                list = @(
                    @{ guid = '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}'; font = @{ face = $nerdFont } },
                    @{ guid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'; font = @{ face = 'Consolas'; size = 12 } }
                )
            }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settingsPath

        & $configureTerminal
        & $configureTerminal

        $result = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
        $result.profiles.defaults.Contains('font') | Should -BeFalse
        $result.profiles.list[0].Contains('font') | Should -BeFalse
        $result.profiles.list[1].font.face | Should -Be 'Consolas'
        $result.profiles.list[1].font.size | Should -Be 12
    }

    It 'uses the existing PowerShell source profile even when its GUID and name are customized' {
        $customGuid = '{12345678-1234-1234-1234-123456789abc}'
        @{
            profiles = @{
                list = @(
                    @{ guid = $customGuid; name = 'Custom shell'; source = 'Windows.Terminal.PowershellCore'; hidden = $true }
                )
            }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settingsPath

        & $configureTerminal

        $result = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
        $result.defaultProfile | Should -Be $customGuid
        $result.startupActions | Should -BeLike "*$customGuid*"
        $result.profiles.list.Count | Should -Be 1
        $result.profiles.list[0].hidden | Should -BeFalse
    }
}
