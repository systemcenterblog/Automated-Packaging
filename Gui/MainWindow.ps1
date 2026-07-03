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

$script:controls = @{}
foreach ($name in (Select-Xml -Xml $xaml -XPath '//*[@Name]' | ForEach-Object { $_.Node.Name })) {
    $script:controls[$name] = Get-Control -Name $name
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
    Register-ListEditor -ListBox $script:controls["${field}List"] -InputBox $script:controls["${field}Input"] `
        -AddButton $script:controls["${field}AddButton"] -RemoveButton $script:controls["${field}RemoveButton"]
}

# ---- Credential hint ---------------------------------------------------------

$script:controls['CredentialHintText'].Text = Get-CredentialHint -RepoRoot $script:RepoRoot

# ---- VM dropdown ---------------------------------------------------------

function Update-VMList {
    try {
        $vms = Get-VM -ErrorAction Stop | Sort-Object Name | Select-Object -ExpandProperty Name
        $script:controls['VMNameCombo'].Items.Clear()
        foreach ($vm in $vms) { $script:controls['VMNameCombo'].Items.Add($vm) | Out-Null }
        if (-NOT $script:controls['VMNameCombo'].Text) {
            if ($vms -contains 'CloudPagingStudio') {
                $script:controls['VMNameCombo'].Text = 'CloudPagingStudio'
            }
            elseif ($vms.Count -gt 0) {
                $script:controls['VMNameCombo'].SelectedIndex = 0
            }
        }
        $script:controls['VmWarningText'].Visibility = 'Collapsed'
    }
    catch {
        $script:controls['VmWarningText'].Text = "Hyper-V PowerShell module unavailable -- enter the VM name manually. ($($_.Exception.Message))"
        $script:controls['VmWarningText'].Visibility = 'Visible'
        if (-NOT $script:controls['VMNameCombo'].Text) { $script:controls['VMNameCombo'].Text = 'CloudPagingStudio' }
    }
}
# Captured as a scriptblock so it can be called by name from inside .Add_Click({...}) --
# a bare function-name call there isn't guaranteed to resolve depending on how WPF invokes
# that particular event (GetNewClosure() only copies variables, not the Function: drive).
$script:updateVmListFn = ${function:Update-VMList}
$script:controls['RefreshVmsButton'].Add_Click({ & $script:updateVmListFn }.GetNewClosure())
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

$script:controls['BrowseInstallerButton'].Add_Click({
    $path = Select-FileDialog -Filter 'Installers (*.msi;*.exe;*.bat;*.cmd;*.ps1)|*.msi;*.exe;*.bat;*.cmd;*.ps1|All files (*.*)|*.*'
    if ($path) { $script:controls['InstallerPathBox'].Text = $path }
})
$script:controls['BrowseIconButton'].Add_Click({
    $path = Select-FileDialog -Filter 'Icon files (*.ico)|*.ico|All files (*.*)|*.*'
    if ($path) { $script:controls['IconFileBox'].Text = $path }
})
$script:controls['BrowseWorkingFolderButton'].Add_Click({
    $path = Select-FolderDialog
    if ($path) { $script:controls['WorkingFolderBox'].Text = $path }
})
$script:controls['BrowseOutputFolderButton'].Add_Click({
    $path = Select-FolderDialog
    if ($path) { $script:controls['OutputFolderBox'].Text = $path }
})

# ---- Mode toggling ---------------------------------------------------------

$updateFinalizeCheckState = {
    if ($script:controls['ModeCaptureOnlyRadio'].IsChecked) {
        $script:controls['FinalizeIntoSTPCheck'].IsChecked = $false
        $script:controls['FinalizeIntoSTPCheck'].IsEnabled = $false
    }
    else {
        $script:controls['FinalizeIntoSTPCheck'].IsEnabled = $true
    }
}
$script:controls['ModeFullRadio'].Add_Checked($updateFinalizeCheckState)
$script:controls['ModeCaptureOnlyRadio'].Add_Checked($updateFinalizeCheckState)

# ---- Wizard -> CreateJson.ps1 argument mapping ---------------------------------------------------------

function Get-CreateJsonArgsFromWizard {
    $args = @{}

    if ($script:controls['DescriptionBox'].Text) { $args['Description'] = $script:controls['DescriptionBox'].Text }
    if ($script:controls['NameBox'].Text) { $args['Name'] = $script:controls['NameBox'].Text }
    if ($script:controls['IconFileBox'].Text) { $args['IconFile'] = $script:controls['IconFileBox'].Text }
    if ($script:controls['WorkingFolderBox'].Text) { $args['WorkingFolder'] = $script:controls['WorkingFolderBox'].Text }
    if ($script:controls['ArgumentsBox'].Text) { $args['Arguments'] = $script:controls['ArgumentsBox'].Text }
    if ($script:controls['StudioCommandlineBox'].Text) { $args['StudioCommandline'] = $script:controls['StudioCommandlineBox'].Text }
    if ($script:controls['OutputFolderBox'].Text) { $args['outputfolder'] = $script:controls['OutputFolderBox'].Text }
    if ($script:controls['OutputFileNameNoExtBox'].Text) { $args['OutputFileNameNoExt'] = $script:controls['OutputFileNameNoExtBox'].Text }

    $args['Compression'] = $script:controls['CompressionCombo'].Text
    $args['Encryption'] = $script:controls['EncryptionCombo'].Text
    $args['DefaultDispositionLayer'] = $script:controls['DefaultDispositionLayerCombo'].Text
    $args['DefaultServiceVirtualizationAction'] = $script:controls['DefaultServiceVirtualizationActionCombo'].Text

    $timeoutValue = 1
    if ([int]::TryParse($script:controls['CaptureTimeoutSecBox'].Text, [ref]$timeoutValue) -and $timeoutValue -ge 1) {
        $args['CaptureTimeoutSec'] = $timeoutValue
    }

    $args['CaptureAllProcesses'] = [bool]$script:controls['CaptureAllProcessesCheck'].IsChecked
    $args['IncludeSystemInstallationProcesses'] = [bool]$script:controls['IncludeSystemInstallationProcessesCheck'].IsChecked
    $args['IgnoreChangesUnderInstallerPath'] = [bool]$script:controls['IgnoreChangesUnderInstallerPathCheck'].IsChecked
    $args['ReplaceRegistryShortPaths'] = [bool]$script:controls['ReplaceRegistryShortPathsCheck'].IsChecked
    $args['IncludeChildProccesses'] = [bool]$script:controls['IncludeChildProccessesCheck'].IsChecked
    $args['Prerequisites'] = [bool]$script:controls['PrerequisitesCheck'].IsChecked
    $args['FinalizeIntoSTP'] = [bool]$script:controls['FinalizeIntoSTPCheck'].IsChecked

    foreach ($field in $listEditorFields) {
        $items = Get-ListEditorItems -ListBox $script:controls["${field}List"]
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
    $installerPath = $script:controls['InstallerPathBox'].Text
    $appName = $script:controls['AppNameBox'].Text
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
        $script:controls['AdvancedJsonBox'].Text = Get-Content -Path $generatedJsonPath -Raw
        $script:AdvancedJsonEdited = $false
        $script:controls['AdvancedJsonStatusText'].Text = "Generated from current wizard values. Hand-edit below (e.g. Fileaddition/Registrymodify/CustomFileDisposition/CustomRegistryDisposition), then Validate. Editing wizard fields afterward will NOT update this text until you click Revert to Generated."
        $script:controls['MainTabs'].SelectedIndex = 1
    }
    catch {
        [System.Windows.MessageBox]::Show("Failed to generate JSON: $($_.Exception.Message)", 'Advanced JSON') | Out-Null
    }
}

$script:controls['PreviewAdvancedJsonButton'].Add_Click($previewAdvancedJson)

$script:controls['AdvancedJsonBox'].Add_TextChanged({
    if ($script:controls['AdvancedJsonBox'].Text) { $script:AdvancedJsonEdited = $true }
})

$script:controls['ValidateJsonButton'].Add_Click({
    try {
        $null = $script:controls['AdvancedJsonBox'].Text | ConvertFrom-Json
        $script:controls['AdvancedJsonStatusText'].Text = 'JSON is valid.'
        $script:controls['AdvancedJsonStatusText'].Foreground = 'Green'
    }
    catch {
        $script:controls['AdvancedJsonStatusText'].Text = "Invalid JSON: $($_.Exception.Message)"
        $script:controls['AdvancedJsonStatusText'].Foreground = 'Red'
    }
})

$script:controls['RevertJsonButton'].Add_Click({
    & $previewAdvancedJson
    $script:AdvancedJsonEdited = $false
}.GetNewClosure())

# ---- Run execution (Tab 1: Start Run / Cancel) ---------------------------------------------------------

$script:PollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PollTimer.Interval = [TimeSpan]::FromMilliseconds(250)

function Set-RunningUiState {
    param([bool]$Running)
    $script:controls['StartRunButton'].IsEnabled = -NOT $Running
    $script:controls['CancelRunButton'].IsEnabled = $Running
    $script:controls['CollectOutputButton'].IsEnabled = (-NOT $Running) -and $script:controls['PendingReviewGrid'].SelectedItem
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
    $script:controls['RunOutputBox'].Clear()
    $script:controls['StatusText'].Text = 'Running...'
    $script:controls['StatusText'].Foreground = 'Black'
    $script:controls['OpenOutputFolderButton'].IsEnabled = $false
    $script:controls['OpenMergeLogButton'].IsEnabled = $false
    Set-RunningUiState -Running $true

    $script:CurrentJob = Start-PackagingJob -ScriptPath $ScriptPath -Arguments $Arguments
    $script:PollTimer.Start()
}
# Captured as a scriptblock so it can be called by name from event-handler scriptblocks below --
# GetNewClosure() only copies variables into a closure, not the Function: drive (see
# PackagingRunner.ps1's Start-PackagingJob), so a bare `Start-Run` call inside .Add_Click({...})
# can fail to resolve depending on how WPF invokes that particular event.
$script:startRunFn = ${function:Start-Run}

$script:controls['StartRunButton'].Add_Click({
    $appName = $script:controls['AppNameBox'].Text
    $installerPath = $script:controls['InstallerPathBox'].Text
    $vmName = $script:controls['VMNameCombo'].Text

    if (-NOT $appName) {
        [System.Windows.MessageBox]::Show('App Name is required.', 'Start Run') | Out-Null
        return
    }
    if (-NOT $installerPath -or -NOT (Test-Path -Path $installerPath)) {
        [System.Windows.MessageBox]::Show('Select a valid installer file.', 'Start Run') | Out-Null
        return
    }

    $isCaptureOnly = [bool]$script:controls['ModeCaptureOnlyRadio'].IsChecked

    $invokeArgs = @{
        AppName       = $appName
        InstallerPath = $installerPath
        VMName        = $vmName
        HostOutputRoot = $script:HostOutputRoot
    }
    if ($script:controls['BaselineCheckpointBox'].Text) {
        $invokeArgs['BaselineCheckpoint'] = $script:controls['BaselineCheckpointBox'].Text
    }
    if ($isCaptureOnly) { $invokeArgs['CaptureOnly'] = $true }

    if ($script:AdvancedJsonEdited -and $script:controls['AdvancedJsonBox'].Text) {
        try {
            $null = $script:controls['AdvancedJsonBox'].Text | ConvertFrom-Json
        }
        catch {
            [System.Windows.MessageBox]::Show("Advanced JSON is invalid: $($_.Exception.Message)", 'Start Run') | Out-Null
            return
        }
        if (-NOT $script:CurrentScratchDir) { $script:CurrentScratchDir = New-ScratchDir -AppName $appName }
        $jsonPath = Join-Path $script:CurrentScratchDir "$appName.json"
        $script:controls['AdvancedJsonBox'].Text | Set-Content -Path $jsonPath -Encoding utf8
        $invokeArgs['JsonConfigPath'] = $jsonPath
    }
    else {
        $wizardArgs = Get-CreateJsonArgsFromWizard
        foreach ($key in $wizardArgs.Keys) { $invokeArgs[$key] = $wizardArgs[$key] }
    }

    & $script:startRunFn -ScriptPath $script:InvokeVMPackagingScript -Arguments $invokeArgs -AppName $appName -IsCaptureOnly $isCaptureOnly
}.GetNewClosure())

$script:controls['CancelRunButton'].Add_Click({
    if ($script:CurrentJob) {
        $result = [System.Windows.MessageBox]::Show(
            "Cancelling may leave the VM in an inconsistent state -- Invoke-VMPackaging.ps1's revert logic may not run cleanly. Continue?",
            'Cancel Run', 'YesNo', 'Warning')
        if ($result -eq 'Yes') {
            $script:controls['CancelRunButton'].IsEnabled = $false
            $script:controls['StatusText'].Text = 'Cancelling...'
            $script:controls['StatusText'].Foreground = 'DarkOrange'
            Stop-PackagingJob -Job $script:CurrentJob
        }
    }
})

function Update-PendingReviewGrid {
    $items = Get-PendingReviewApps -HostOutputRoot $script:HostOutputRoot
    $script:controls['PendingReviewGrid'].ItemsSource = @($items)
}
# See the comment on $script:startRunFn above -- same reasoning applies here.
$script:updatePendingReviewGridFn = ${function:Update-PendingReviewGrid}

$script:PollTimer.Add_Tick({
  try {
    if (-NOT $script:CurrentJob) { if ($script:PollTimer) { $script:PollTimer.Stop() }; return }

    foreach ($line in (Get-PackagingJobOutput -Job $script:CurrentJob)) {
        $script:controls['RunOutputBox'].AppendText("$line`r`n")
        $script:controls['RunOutputBox'].ScrollToEnd()

        switch -Wildcard ($line) {
            '*Running studio-nip.ps1 inside the guest*' {
                $script:controls['StatusText'].Text = 'Capturing inside guest VM...'
            }
            '*Starting studio-nip.ps1 inside the guest*' {
                $script:controls['StatusText'].Text = 'Starting silent install/capture inside guest VM...'
            }
            '*Copying output back to*' {
                $script:controls['StatusText'].Text = 'Copying output back to host...'
            }
            '*Reverting *back to baseline checkpoint*' {
                $script:controls['StatusText'].Text = 'Reverting VM to baseline...'
            }
        }
    }

    if (Test-PackagingJobComplete -Job $script:CurrentJob) {
        $script:PollTimer.Stop()
        foreach ($line in (Get-PackagingJobOutput -Job $script:CurrentJob)) {
            $script:controls['RunOutputBox'].AppendText("$line`r`n")
        }
        $result = Complete-PackagingJob -Job $script:CurrentJob
        $script:CurrentJob = $null
        Set-RunningUiState -Running $false

        $appName = $script:CurrentRunAppName
        $succeeded = Test-PackagingSucceeded -HostOutputRoot $script:HostOutputRoot -AppName $appName

        if (-NOT $result.Success) {
            $script:controls['StatusText'].Text = "Failed: $($result.ErrorMessage)"
            $script:controls['StatusText'].Foreground = 'Red'
        }
        elseif ($script:CurrentRunIsCaptureOnly) {
            $script:controls['StatusText'].Text = 'Silent install/capture started in the background on the VM. Studio runs headlessly and exits on its own -- it will NOT be open waiting for you. Console/RDP in, wait for it to finish, then manually open the project (.stw) in Cloudpaging Studio to review/Build before using Collect Output. See Pending Review tab.'
            $script:controls['StatusText'].Foreground = 'DarkOrange'
            & $script:updatePendingReviewGridFn
        }
        elseif ($succeeded) {
            $script:controls['StatusText'].Text = 'Succeeded'
            $script:controls['StatusText'].Foreground = 'Green'
        }
        else {
            $script:controls['StatusText'].Text = 'Uncertain -- no .stp found, check output above'
            $script:controls['StatusText'].Foreground = 'DarkOrange'
        }

        $appFolder = Get-AppOutputFolder -HostOutputRoot $script:HostOutputRoot -AppName $appName
        if (Test-Path -Path $appFolder) {
            $script:controls['OpenOutputFolderButton'].IsEnabled = $true
            $script:controls['OpenOutputFolderButton'].Tag = $appFolder
        }
        $logPath = Get-LatestMergeResultsLog -HostOutputRoot $script:HostOutputRoot -AppName $appName
        if ($logPath) {
            $script:controls['OpenMergeLogButton'].IsEnabled = $true
            $script:controls['OpenMergeLogButton'].Tag = $logPath
        }
    }
  }
  catch {
    if ($script:PollTimer) { $script:PollTimer.Stop() }
    $script:controls['StatusText'].Text = "Internal GUI error: $($_.Exception.Message)"
    $script:controls['StatusText'].Foreground = 'Red'
    $script:CurrentJob = $null
    Set-RunningUiState -Running $false
  }
})

$script:controls['OpenOutputFolderButton'].Add_Click({
    if ($script:controls['OpenOutputFolderButton'].Tag) { Invoke-Item -Path $script:controls['OpenOutputFolderButton'].Tag }
})
$script:controls['OpenMergeLogButton'].Add_Click({
    if ($script:controls['OpenMergeLogButton'].Tag) { Invoke-Item -Path $script:controls['OpenMergeLogButton'].Tag }
})

# ---- Pending Review tab ---------------------------------------------------------

$script:controls['RefreshPendingButton'].Add_Click({ & $script:updatePendingReviewGridFn }.GetNewClosure())
$script:controls['PendingReviewGrid'].Add_SelectionChanged({
    $script:controls['CollectOutputButton'].IsEnabled = (-NOT $script:CurrentJob) -and $script:controls['PendingReviewGrid'].SelectedItem
}.GetNewClosure())

$script:controls['CollectOutputButton'].Add_Click({
    $selected = $script:controls['PendingReviewGrid'].SelectedItem
    if (-NOT $selected) { return }

    $script:controls['MainTabs'].SelectedIndex = 0
    $invokeArgs = @{
        AppName        = $selected.AppName
        VMName         = $selected.VMName
        HostOutputRoot = $script:HostOutputRoot
        CollectOutput  = $true
    }
    & $script:startRunFn -ScriptPath $script:InvokeVMPackagingScript -Arguments $invokeArgs -AppName $selected.AppName -IsCaptureOnly $false
}.GetNewClosure())

Update-PendingReviewGrid

# ---- Show window ---------------------------------------------------------

$window.Add_Closed({ $script:PollTimer.Stop() })
$window.ShowDialog() | Out-Null
