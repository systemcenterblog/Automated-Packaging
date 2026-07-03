########################################################################
#  MainWindow.ps1
#
#  Code-behind for the packaging GUI. Loads MainWindow.xaml, wires up
#  every control, and shells out to CreateJson.ps1 / Invoke-VMPackaging.ps1
#  for all JSON generation and VM orchestration -- no packaging logic is
#  reimplemented here.
########################################################################

$script:RepoRoot = Split-Path $PSScriptRoot -Parent
$script:CreateJsonScript = Join-Path $script:RepoRoot 'CreateJson.ps1'
$script:InvokeVMPackagingScript = Join-Path $script:RepoRoot 'Invoke-VMPackaging.ps1'
$script:HostOutputRoot = Join-Path $script:RepoRoot 'Output'

# Mirrors Invoke-VMPackaging.ps1's $script:CreateJsonParamNames (Invoke-VMPackaging.ps1:214-224).
# If a new param is added there per CLAUDE.md's dual-file+list rule, add a matching wizard
# control and an entry to Get-CreateJsonArgsFromWizard below.
$script:CreateJsonParamNames = @(
    'Description', 'Name', 'IconFile', 'WorkingFolder', 'Arguments', 'StudioCommandline',
    'outputfolder', 'OutputFileNameNoExt', 'Compression', 'Encryption', 'DefaultDispositionLayer',
    'CaptureTimeoutSec', 'CustomCommandlines', 'RegistryExclusions', 'FileExclusions',
    'ProcessesAllowedAccessToLayer4', 'ProcessesDeniedAccessToLayers3and4',
    'SandboxRegistryExclusions', 'SandboxFileExclusions', 'CaptureAllProcesses',
    'IncludeSystemInstallationProcesses', 'IgnoreChangesUnderInstallerPath',
    'ReplaceRegistryShortPaths', 'IncludeChildProccesses', 'Prerequisites',
    'PrerequisiteCommands', 'DefaultServiceVirtualizationAction', 'FinalizeIntoSTP'
)

# ---- Load XAML ---------------------------------------------------------

$xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
[xml]$xaml = Get-Content -Path $xamlPath -Raw
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

function Get-Control {
    param([Parameter(Mandatory)][string]$Name)
    return $window.FindName($Name)
}

$controls = @{}
foreach ($name in (Select-Xml -Xml $xaml -XPath '//*[@Name]' | ForEach-Object { $_.Node.Name })) {
    $controls[$name] = Get-Control -Name $name
}

# ---- State ---------------------------------------------------------

$script:AdvancedJsonEdited = $false
$script:CurrentScratchDir = $null
$script:CurrentJob = $null
$script:CurrentRunAppName = $null
$script:CurrentRunIsCaptureOnly = $false

# ---- List editors ---------------------------------------------------------

$listEditorFields = @(
    'PrerequisiteCommands', 'CustomCommandlines', 'RegistryExclusions', 'FileExclusions',
    'SandboxRegistryExclusions', 'SandboxFileExclusions',
    'ProcessesAllowedAccessToLayer4', 'ProcessesDeniedAccessToLayers3and4'
)
foreach ($field in $listEditorFields) {
    Register-ListEditor -ListBox $controls["${field}List"] -InputBox $controls["${field}Input"] `
        -AddButton $controls["${field}AddButton"] -RemoveButton $controls["${field}RemoveButton"]
}

# ---- Credential hint ---------------------------------------------------------

$controls['CredentialHintText'].Text = Get-CredentialHint -RepoRoot $script:RepoRoot

# ---- VM dropdown ---------------------------------------------------------

function Update-VMList {
    try {
        $vms = Get-VM -ErrorAction Stop | Sort-Object Name | Select-Object -ExpandProperty Name
        $controls['VMNameCombo'].Items.Clear()
        foreach ($vm in $vms) { $controls['VMNameCombo'].Items.Add($vm) | Out-Null }
        if (-NOT $controls['VMNameCombo'].Text) {
            if ($vms -contains 'CloudPagingStudio') {
                $controls['VMNameCombo'].Text = 'CloudPagingStudio'
            }
            elseif ($vms.Count -gt 0) {
                $controls['VMNameCombo'].SelectedIndex = 0
            }
        }
        $controls['VmWarningText'].Visibility = 'Collapsed'
    }
    catch {
        $controls['VmWarningText'].Text = "Hyper-V PowerShell module unavailable -- enter the VM name manually. ($($_.Exception.Message))"
        $controls['VmWarningText'].Visibility = 'Visible'
        if (-NOT $controls['VMNameCombo'].Text) { $controls['VMNameCombo'].Text = 'CloudPagingStudio' }
    }
}
$controls['RefreshVmsButton'].Add_Click({ Update-VMList })
Update-VMList

# ---- File/folder pickers ---------------------------------------------------------

function Select-FileDialog {
    param([string]$Filter = 'All files (*.*)|*.*')
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = $Filter
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    return $null
}

function Select-FolderDialog {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

$controls['BrowseInstallerButton'].Add_Click({
    $path = Select-FileDialog -Filter 'Installers (*.msi;*.exe;*.bat;*.cmd;*.ps1)|*.msi;*.exe;*.bat;*.cmd;*.ps1|All files (*.*)|*.*'
    if ($path) { $controls['InstallerPathBox'].Text = $path }
})
$controls['BrowseIconButton'].Add_Click({
    $path = Select-FileDialog -Filter 'Icon files (*.ico)|*.ico|All files (*.*)|*.*'
    if ($path) { $controls['IconFileBox'].Text = $path }
})
$controls['BrowseWorkingFolderButton'].Add_Click({
    $path = Select-FolderDialog
    if ($path) { $controls['WorkingFolderBox'].Text = $path }
})
$controls['BrowseOutputFolderButton'].Add_Click({
    $path = Select-FolderDialog
    if ($path) { $controls['OutputFolderBox'].Text = $path }
})

# ---- Mode toggling ---------------------------------------------------------

$updateFinalizeCheckState = {
    if ($controls['ModeCaptureOnlyRadio'].IsChecked) {
        $controls['FinalizeIntoSTPCheck'].IsChecked = $false
        $controls['FinalizeIntoSTPCheck'].IsEnabled = $false
    }
    else {
        $controls['FinalizeIntoSTPCheck'].IsEnabled = $true
    }
}
$controls['ModeFullRadio'].Add_Checked($updateFinalizeCheckState)
$controls['ModeCaptureOnlyRadio'].Add_Checked($updateFinalizeCheckState)

# ---- Wizard -> CreateJson.ps1 argument mapping ---------------------------------------------------------

function Get-CreateJsonArgsFromWizard {
    $args = @{}

    if ($controls['DescriptionBox'].Text) { $args['Description'] = $controls['DescriptionBox'].Text }
    if ($controls['NameBox'].Text) { $args['Name'] = $controls['NameBox'].Text }
    if ($controls['IconFileBox'].Text) { $args['IconFile'] = $controls['IconFileBox'].Text }
    if ($controls['WorkingFolderBox'].Text) { $args['WorkingFolder'] = $controls['WorkingFolderBox'].Text }
    if ($controls['ArgumentsBox'].Text) { $args['Arguments'] = $controls['ArgumentsBox'].Text }
    if ($controls['StudioCommandlineBox'].Text) { $args['StudioCommandline'] = $controls['StudioCommandlineBox'].Text }
    if ($controls['OutputFolderBox'].Text) { $args['outputfolder'] = $controls['OutputFolderBox'].Text }
    if ($controls['OutputFileNameNoExtBox'].Text) { $args['OutputFileNameNoExt'] = $controls['OutputFileNameNoExtBox'].Text }

    $args['Compression'] = $controls['CompressionCombo'].Text
    $args['Encryption'] = $controls['EncryptionCombo'].Text
    $args['DefaultDispositionLayer'] = $controls['DefaultDispositionLayerCombo'].Text
    $args['DefaultServiceVirtualizationAction'] = $controls['DefaultServiceVirtualizationActionCombo'].Text

    $timeoutValue = 1
    if ([int]::TryParse($controls['CaptureTimeoutSecBox'].Text, [ref]$timeoutValue) -and $timeoutValue -ge 1) {
        $args['CaptureTimeoutSec'] = $timeoutValue
    }

    $args['CaptureAllProcesses'] = [bool]$controls['CaptureAllProcessesCheck'].IsChecked
    $args['IncludeSystemInstallationProcesses'] = [bool]$controls['IncludeSystemInstallationProcessesCheck'].IsChecked
    $args['IgnoreChangesUnderInstallerPath'] = [bool]$controls['IgnoreChangesUnderInstallerPathCheck'].IsChecked
    $args['ReplaceRegistryShortPaths'] = [bool]$controls['ReplaceRegistryShortPathsCheck'].IsChecked
    $args['IncludeChildProccesses'] = [bool]$controls['IncludeChildProccessesCheck'].IsChecked
    $args['Prerequisites'] = [bool]$controls['PrerequisitesCheck'].IsChecked
    $args['FinalizeIntoSTP'] = [bool]$controls['FinalizeIntoSTPCheck'].IsChecked

    foreach ($field in $listEditorFields) {
        $items = Get-ListEditorItems -ListBox $controls["${field}List"]
        if ($items.Count -gt 0) { $args[$field] = $items }
    }

    return $args
}

# ---- Advanced JSON tab ---------------------------------------------------------

function New-ScratchDir {
    param([Parameter(Mandatory)][string]$AppName)
    $dir = Join-Path $env:TEMP "PackagingGui_${AppName}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

$previewAdvancedJson = {
    $installerPath = $controls['InstallerPathBox'].Text
    $appName = $controls['AppNameBox'].Text
    if (-NOT $installerPath -or -NOT (Test-Path -Path $installerPath)) {
        [System.Windows.MessageBox]::Show('Select a valid installer file first.', 'Advanced JSON') | Out-Null
        return
    }
    if (-NOT $appName) {
        [System.Windows.MessageBox]::Show('Enter an App Name first.', 'Advanced JSON') | Out-Null
        return
    }

    try {
        $script:CurrentScratchDir = New-ScratchDir -AppName $appName
        $installerFileName = Split-Path $installerPath -Leaf
        $scratchInstallerCopy = Join-Path $script:CurrentScratchDir $installerFileName
        Copy-Item -Path $installerPath -Destination $scratchInstallerCopy -Force

        $createJsonArgs = Get-CreateJsonArgsFromWizard
        $createJsonArgs['Filepath'] = $scratchInstallerCopy

        & $script:CreateJsonScript @createJsonArgs

        $generatedJsonPath = Join-Path $script:CurrentScratchDir "$([System.IO.Path]::GetFileNameWithoutExtension($installerFileName)).json"
        if (-NOT (Test-Path -Path $generatedJsonPath)) {
            throw "CreateJson.ps1 completed but did not produce the expected JSON at $generatedJsonPath."
        }
        $controls['AdvancedJsonBox'].Text = Get-Content -Path $generatedJsonPath -Raw
        $script:AdvancedJsonEdited = $false
        $controls['AdvancedJsonStatusText'].Text = "Generated from current wizard values. Hand-edit below (e.g. Fileaddition/Registrymodify/CustomFileDisposition/CustomRegistryDisposition), then Validate. Editing wizard fields afterward will NOT update this text until you click Revert to Generated."
        $controls['MainTabs'].SelectedIndex = 1
    }
    catch {
        [System.Windows.MessageBox]::Show("Failed to generate JSON: $($_.Exception.Message)", 'Advanced JSON') | Out-Null
    }
}

$controls['PreviewAdvancedJsonButton'].Add_Click($previewAdvancedJson)

$controls['AdvancedJsonBox'].Add_TextChanged({
    if ($controls['AdvancedJsonBox'].Text) { $script:AdvancedJsonEdited = $true }
})

$controls['ValidateJsonButton'].Add_Click({
    try {
        $null = $controls['AdvancedJsonBox'].Text | ConvertFrom-Json
        $controls['AdvancedJsonStatusText'].Text = 'JSON is valid.'
        $controls['AdvancedJsonStatusText'].Foreground = 'Green'
    }
    catch {
        $controls['AdvancedJsonStatusText'].Text = "Invalid JSON: $($_.Exception.Message)"
        $controls['AdvancedJsonStatusText'].Foreground = 'Red'
    }
})

$controls['RevertJsonButton'].Add_Click({
    & $previewAdvancedJson
    $script:AdvancedJsonEdited = $false
}.GetNewClosure())

# ---- Run execution (Tab 1: Start Run / Cancel) ---------------------------------------------------------

$script:PollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PollTimer.Interval = [TimeSpan]::FromMilliseconds(250)

function Set-RunningUiState {
    param([bool]$Running)
    $controls['StartRunButton'].IsEnabled = -NOT $Running
    $controls['CancelRunButton'].IsEnabled = $Running
    $controls['CollectOutputButton'].IsEnabled = (-NOT $Running) -and $controls['PendingReviewGrid'].SelectedItem
}

function Start-Run {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Parameter(Mandatory)][string]$AppName,
        [bool]$IsCaptureOnly = $false
    )

    $script:CurrentRunAppName = $AppName
    $script:CurrentRunIsCaptureOnly = $IsCaptureOnly
    $controls['RunOutputBox'].Clear()
    $controls['StatusText'].Text = 'Running...'
    $controls['StatusText'].Foreground = 'Black'
    $controls['OpenOutputFolderButton'].IsEnabled = $false
    $controls['OpenMergeLogButton'].IsEnabled = $false
    Set-RunningUiState -Running $true

    $script:CurrentJob = Start-PackagingJob -ScriptPath $ScriptPath -Arguments $Arguments
    $script:PollTimer.Start()
}

$controls['StartRunButton'].Add_Click({
    $appName = $controls['AppNameBox'].Text
    $installerPath = $controls['InstallerPathBox'].Text
    $vmName = $controls['VMNameCombo'].Text

    if (-NOT $appName) {
        [System.Windows.MessageBox]::Show('App Name is required.', 'Start Run') | Out-Null
        return
    }
    if (-NOT $installerPath -or -NOT (Test-Path -Path $installerPath)) {
        [System.Windows.MessageBox]::Show('Select a valid installer file.', 'Start Run') | Out-Null
        return
    }

    $isCaptureOnly = [bool]$controls['ModeCaptureOnlyRadio'].IsChecked

    $invokeArgs = @{
        AppName       = $appName
        InstallerPath = $installerPath
        VMName        = $vmName
        HostOutputRoot = $script:HostOutputRoot
    }
    if ($controls['BaselineCheckpointBox'].Text) {
        $invokeArgs['BaselineCheckpoint'] = $controls['BaselineCheckpointBox'].Text
    }
    if ($isCaptureOnly) { $invokeArgs['CaptureOnly'] = $true }

    if ($script:AdvancedJsonEdited -and $controls['AdvancedJsonBox'].Text) {
        try {
            $null = $controls['AdvancedJsonBox'].Text | ConvertFrom-Json
        }
        catch {
            [System.Windows.MessageBox]::Show("Advanced JSON is invalid: $($_.Exception.Message)", 'Start Run') | Out-Null
            return
        }
        if (-NOT $script:CurrentScratchDir) { $script:CurrentScratchDir = New-ScratchDir -AppName $appName }
        $jsonPath = Join-Path $script:CurrentScratchDir "$appName.json"
        $controls['AdvancedJsonBox'].Text | Set-Content -Path $jsonPath -Encoding utf8
        $invokeArgs['JsonConfigPath'] = $jsonPath
    }
    else {
        $wizardArgs = Get-CreateJsonArgsFromWizard
        foreach ($key in $wizardArgs.Keys) { $invokeArgs[$key] = $wizardArgs[$key] }
    }

    Start-Run -ScriptPath $script:InvokeVMPackagingScript -Arguments $invokeArgs -AppName $appName -IsCaptureOnly $isCaptureOnly
})

$controls['CancelRunButton'].Add_Click({
    if ($script:CurrentJob) {
        $result = [System.Windows.MessageBox]::Show(
            "Cancelling may leave the VM in an inconsistent state -- Invoke-VMPackaging.ps1's revert logic may not run cleanly. Continue?",
            'Cancel Run', 'YesNo', 'Warning')
        if ($result -eq 'Yes') {
            $controls['CancelRunButton'].IsEnabled = $false
            $controls['StatusText'].Text = 'Cancelling...'
            $controls['StatusText'].Foreground = 'DarkOrange'
            Stop-PackagingJob -Job $script:CurrentJob
        }
    }
})

function Update-PendingReviewGrid {
    $items = Get-PendingReviewApps -HostOutputRoot $script:HostOutputRoot
    $controls['PendingReviewGrid'].ItemsSource = @($items)
}

$script:PollTimer.Add_Tick({
    if (-NOT $script:CurrentJob) { $script:PollTimer.Stop(); return }

    foreach ($line in (Get-PackagingJobOutput -Job $script:CurrentJob)) {
        $controls['RunOutputBox'].AppendText("$line`r`n")
        $controls['RunOutputBox'].ScrollToEnd()

        switch -Wildcard ($line) {
            '*Running studio-nip.ps1 inside the guest*' {
                $controls['StatusText'].Text = 'Capturing inside guest VM...'
            }
            '*Copying output back to*' {
                $controls['StatusText'].Text = 'Copying output back to host...'
            }
            '*Reverting *back to baseline checkpoint*' {
                $controls['StatusText'].Text = 'Reverting VM to baseline...'
            }
        }
    }

    if (Test-PackagingJobComplete -Job $script:CurrentJob) {
        $script:PollTimer.Stop()
        foreach ($line in (Get-PackagingJobOutput -Job $script:CurrentJob)) {
            $controls['RunOutputBox'].AppendText("$line`r`n")
        }
        $result = Complete-PackagingJob -Job $script:CurrentJob
        $script:CurrentJob = $null
        Set-RunningUiState -Running $false

        $appName = $script:CurrentRunAppName
        $succeeded = Test-PackagingSucceeded -HostOutputRoot $script:HostOutputRoot -AppName $appName

        if (-NOT $result.Success) {
            $controls['StatusText'].Text = "Failed: $($result.ErrorMessage)"
            $controls['StatusText'].Foreground = 'Red'
        }
        elseif ($script:CurrentRunIsCaptureOnly) {
            $controls['StatusText'].Text = 'Capture complete -- VM left running for review. See Pending Review tab.'
            $controls['StatusText'].Foreground = 'DarkOrange'
            Update-PendingReviewGrid
        }
        elseif ($succeeded) {
            $controls['StatusText'].Text = 'Succeeded'
            $controls['StatusText'].Foreground = 'Green'
        }
        else {
            $controls['StatusText'].Text = 'Uncertain -- no .stp found, check output above'
            $controls['StatusText'].Foreground = 'DarkOrange'
        }

        $appFolder = Get-AppOutputFolder -HostOutputRoot $script:HostOutputRoot -AppName $appName
        if (Test-Path -Path $appFolder) {
            $controls['OpenOutputFolderButton'].IsEnabled = $true
            $controls['OpenOutputFolderButton'].Tag = $appFolder
        }
        $logPath = Get-LatestMergeResultsLog -HostOutputRoot $script:HostOutputRoot -AppName $appName
        if ($logPath) {
            $controls['OpenMergeLogButton'].IsEnabled = $true
            $controls['OpenMergeLogButton'].Tag = $logPath
        }
    }
})

$controls['OpenOutputFolderButton'].Add_Click({
    if ($controls['OpenOutputFolderButton'].Tag) { Invoke-Item -Path $controls['OpenOutputFolderButton'].Tag }
})
$controls['OpenMergeLogButton'].Add_Click({
    if ($controls['OpenMergeLogButton'].Tag) { Invoke-Item -Path $controls['OpenMergeLogButton'].Tag }
})

# ---- Pending Review tab ---------------------------------------------------------

$controls['RefreshPendingButton'].Add_Click({ Update-PendingReviewGrid })
$controls['PendingReviewGrid'].Add_SelectionChanged({
    $controls['CollectOutputButton'].IsEnabled = (-NOT $script:CurrentJob) -and $controls['PendingReviewGrid'].SelectedItem
})

$controls['CollectOutputButton'].Add_Click({
    $selected = $controls['PendingReviewGrid'].SelectedItem
    if (-NOT $selected) { return }

    $controls['MainTabs'].SelectedIndex = 0
    $invokeArgs = @{
        AppName        = $selected.AppName
        VMName         = $selected.VMName
        HostOutputRoot = $script:HostOutputRoot
        CollectOutput  = $true
    }
    Start-Run -ScriptPath $script:InvokeVMPackagingScript -Arguments $invokeArgs -AppName $selected.AppName -IsCaptureOnly $false
})

Update-PendingReviewGrid

# ---- Show window ---------------------------------------------------------

$window.Add_Closed({ $script:PollTimer.Stop() })
$window.ShowDialog() | Out-Null
