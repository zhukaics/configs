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

    $start = $statements | Where-Object {
        $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left.Extent.Text -eq '$vsCodeSettingsDirectory'
    }
    $end = $statements | Where-Object {
        $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left.Extent.Text -eq '$neovimConfigDirectory'
    }
    if (-not $start -or -not $end) {
        throw 'Could not locate the VS Code settings section.'
    }
    $script:configureVsCode = [scriptblock]::Create(
        ($statements | Where-Object {
            $_.Extent.StartOffset -ge $start.Extent.StartOffset -and
            $_.Extent.EndOffset -le $end.Extent.StartOffset
        } | ForEach-Object { $_.Extent.Text }) -join "`n"
    )

    $start = $statements | Where-Object {
        $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left.Extent.Text -eq '$promptConfigPath'
    }
    $end = $statements | Where-Object {
        $_ -is [System.Management.Automation.Language.ForEachStatementAst] -and
        $_.Variable.VariablePath.UserPath -eq 'profilePath'
    }
    if (-not $start -or -not $end) {
        throw 'Could not locate the PowerShell prompt configuration section.'
    }
    $script:configurePrompt = [scriptblock]::Create(
        "param([string] `$PSScriptRoot)`n" + (($statements | Where-Object {
            $_.Extent.StartOffset -ge $start.Extent.StartOffset -and
            $_.Extent.EndOffset -le $end.Extent.EndOffset
        } | ForEach-Object { $_.Extent.Text }) -join "`n")
    )
    $script:promptConfigSourcePath = Join-Path $PSScriptRoot 'prompt.omp.json'
}

Describe 'Font-independent PowerShell prompt' {
    BeforeEach {
        $root = Join-Path $TestDrive ("config's " + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $root | Out-Null
        Copy-Item -LiteralPath $promptConfigSourcePath -Destination $root
        $powerShellProfilePaths = @(
            (Join-Path $root 'PowerShell\profile.ps1'),
            (Join-Path $root 'WindowsPowerShell\profile.ps1')
        )
    }

    It 'configures both fresh profiles with a correctly quoted local theme path' {
        & $configurePrompt $root

        foreach ($path in $powerShellProfilePaths) {
            $errors = $null
            $profile = [System.Management.Automation.Language.Parser]::ParseFile(
                $path, [ref] $null, [ref] $errors
            )
            $errors | Should -BeNullOrEmpty
            $init = $profile.Find({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'oh-my-posh'
            }, $true)
            $init.CommandElements[4].Value | Should -Be (Join-Path $root 'prompt.omp.json')
        }
    }

    It 'migrates the old default initialization without changing other profile commands or duplicating init' {
        $path = $powerShellProfilePaths[0]
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        $original = "Write-Host 'before'`r`noh-my-posh init pwsh | Invoke-Expression`r`nWrite-Host 'after'"
        Set-Content -LiteralPath $path -Value $original

        & $configurePrompt $root
        & $configurePrompt $root

        $result = Get-Content -LiteralPath $path -Raw
        $result | Should -Match "^Write-Host 'before'"
        $result | Should -Match "Write-Host 'after'"
        $result | Should -Match 'init pwsh --config'
        ([regex]::Matches($result, 'oh-my-posh init')).Count | Should -Be 1
        (Get-Content -LiteralPath "$path.bak" -Raw).TrimEnd() | Should -Be $original
    }

    It 'preserves an explicitly customized Oh My Posh initialization' {
        $path = $powerShellProfilePaths[0]
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        $original = "oh-my-posh init pwsh --config 'custom.omp.json' | Invoke-Expression"
        Set-Content -LiteralPath $path -Value $original

        & $configurePrompt $root

        (Get-Content -LiteralPath $path -Raw).TrimEnd() | Should -Be $original
        Test-Path -LiteralPath "$path.bak" | Should -BeFalse
    }

    It 'fails before modifying profiles when the local theme is missing' {
        Remove-Item -LiteralPath (Join-Path $root 'prompt.omp.json')

        { & $configurePrompt $root } | Should -Throw '*configuration not found*'
        foreach ($path in $powerShellProfilePaths) {
            Test-Path -LiteralPath $path | Should -BeFalse
        }
    }
}

Describe 'VS Code default fonts' {
    BeforeEach {
        $originalAppData = $env:APPDATA
        $env:APPDATA = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $settingsPath = Join-Path $env:APPDATA 'Code - Insiders\User\settings.json'
    }

    AfterEach {
        $env:APPDATA = $originalAppData
    }

    It 'does not override the font on a fresh setup' {
        & $configureVsCode

        $result = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
        $result.Contains('terminal.integrated.fontFamily') | Should -BeFalse
    }

    It 'removes the old generated font override while preserving unrelated settings' {
        New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
        @{
            'terminal.integrated.fontFamily' = 'MesloLGM Nerd Font Mono'
            'editor.fontSize' = 16
        } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath

        & $configureVsCode
        & $configureVsCode

        $result = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
        $result.Contains('terminal.integrated.fontFamily') | Should -BeFalse
        $result['editor.fontSize'] | Should -Be 16
        Test-Path -LiteralPath "$settingsPath.bak" | Should -BeTrue
    }

    It 'does not remove a different font chosen by the user' {
        New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
        @{ 'terminal.integrated.fontFamily' = 'Consolas' } |
            ConvertTo-Json | Set-Content -LiteralPath $settingsPath

        & $configureVsCode

        $result = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
        $result['terminal.integrated.fontFamily'] | Should -Be 'Consolas'
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
