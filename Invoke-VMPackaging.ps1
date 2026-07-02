<#
.SYNOPSIS
    Runs Cloudpaging Studio non-interactive packaging inside a Hyper-V VM, using
    a checkpoint to guarantee every run starts from an identical clean state.
.DESCRIPTION
    Two modes:
      -Setup   : one-time baseline creation. Boots the VM, verifies Studio is
                 installed and UAC is disabled inside the guest, then takes a
                 checkpoint to use as the restore point for every future run.
      (default): restores the VM to the baseline checkpoint, boots it, copies
                 the installer + JSON config in, runs studio-nip.ps1 inside the
                 guest via PowerShell Direct, copies the resulting output back
                 to the host, then reverts the VM to baseline again.
.PARAMETER VMName
    Name of the Hyper-V VM. Defaults to "CloudPagingStudio".
.PARAMETER BaselineCheckpoint
    Name of the checkpoint used as the clean restore point. Defaults to "Studio-Baseline".
.PARAMETER Setup
    Run one-time baseline creation instead of a packaging run.
.PARAMETER AppName
    Name used for both the guest-side and host-side per-app subfolder.
.PARAMETER JsonConfigPath
    Host path to the app's JSON packaging config.
.PARAMETER InstallerPath
    Host path to the installer file to package.
.PARAMETER HostOutputRoot
    Host folder that per-app output subfolders are created under. Defaults to
    "C:\Apps\Automated-Packaging\Output".
.PARAMETER GuestNipRoot
    Root folder on the guest that per-app subfolders are created under, and
    where studio-nip.ps1 is expected to already exist. Defaults to "C:\NIP_software".
.PARAMETER SkipRevertAfter
    Leave the VM running after copying output out instead of immediately
    reverting it to baseline. Useful for inspecting a failed/interesting run.
.PARAMETER BootTimeoutSec
    How long to wait for the guest to become reachable via PowerShell Direct
    after starting it. Defaults to 300 seconds.

.EXAMPLE
    .\Invoke-VMPackaging.ps1 -Setup

.EXAMPLE
    .\Invoke-VMPackaging.ps1 -AppName '7-Zip' -JsonConfigPath '.\Samples\7-Zip\7-Zip_Packaging_Config_File.json' -InstallerPath '.\Samples\7-Zip\7-ZIP.exe'
#>

[CmdletBinding(DefaultParameterSetName = "Package")]
param(
    [string]$VMName = "CloudPagingStudio",
    [string]$BaselineCheckpoint = "Studio-Baseline",

    [Parameter(ParameterSetName = "Setup", Mandatory = $true)]
    [switch]$Setup,

    [Parameter(ParameterSetName = "Package", Mandatory = $true)]
    [string]$AppName,
    [Parameter(ParameterSetName = "Package", Mandatory = $true)]
    [string]$JsonConfigPath,
    [Parameter(ParameterSetName = "Package", Mandatory = $true)]
    [string]$InstallerPath,
    [Parameter(ParameterSetName = "Package")]
    [string]$HostOutputRoot = "C:\Apps\Automated-Packaging\Output",
    [Parameter(ParameterSetName = "Package")]
    [switch]$SkipRevertAfter,

    [string]$GuestNipRoot = "C:\NIP_software",
    [int]$BootTimeoutSec = 300
)

function Wait-VMReady {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][int]$TimeoutSec
    )

    Write-Host "Waiting for '$VMName' to become reachable via PowerShell Direct (timeout ${TimeoutSec}s)..."
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $session = New-PSSession -VMName $VMName -Credential $Credential -ErrorAction Stop
            Write-Host "Guest is reachable."
            return $session
        }
        catch {
            Start-Sleep -Seconds 5
        }
    }
    throw "Timed out waiting for '$VMName' to become reachable via PowerShell Direct after ${TimeoutSec}s."
}

function Start-VMAndWait {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][int]$TimeoutSec
    )

    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.State -ne "Running") {
        Write-Host "Starting VM '$VMName'..."
        Start-VM -Name $VMName
    }
    return Wait-VMReady -VMName $VMName -Credential $Credential -TimeoutSec $TimeoutSec
}

function New-GuestPatchedConfig {
    param(
        [Parameter(Mandatory)][string]$SourceJsonPath,
        [Parameter(Mandatory)][string]$GuestInstallerCfgPath,
        [Parameter(Mandatory)][string]$GuestOutputPath,
        [Parameter(Mandatory)][string]$InstallerFileName,
        [Parameter(Mandatory)][string]$ScratchDir
    )

    $json = Get-Content -Path $SourceJsonPath -Raw | ConvertFrom-Json
    $json.CaptureCommands.InstallerPath = Join-Path $GuestInstallerCfgPath $InstallerFileName
    $json.OutputSettings.OutputFolder = "$GuestOutputPath\"

    $patchedPath = Join-Path $ScratchDir "patched_config.json"
    $json | ConvertTo-Json -Depth 20 | Out-File -FilePath $patchedPath -Encoding utf8
    return $patchedPath
}

if ($Setup) {
    $cred = Get-Credential -Message "Guest admin credentials for VM '$VMName'"
    $session = Start-VMAndWait -VMName $VMName -Credential $cred -TimeoutSec $BootTimeoutSec

    try {
        Write-Host "Verifying Cloudpaging Studio and UAC state inside the guest..."
        $check = Invoke-Command -Session $session -ScriptBlock {
            $studioPath = "C:\Program Files\Numecent\Cloudpaging Studio\"
            $studioCmd = $studioPath + "JukeboxStudio.exe"
            if (-NOT (Test-Path -Path $studioCmd)) {
                $studioCmd = $studioPath + "CloudpagingStudio.exe"
            }
            $studioInstalled = Test-Path -Path $studioCmd
            $uacEnabled = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System).EnableLUA
            $nipScriptPresent = Test-Path -Path "C:\NIP_software\studio-nip.ps1"
            [pscustomobject]@{
                StudioInstalled  = $studioInstalled
                UacEnabled       = [bool]$uacEnabled
                NipScriptPresent = $nipScriptPresent
            }
        }

        $problems = @()
        if (-NOT $check.StudioInstalled) { $problems += "Cloudpaging Studio was not found under C:\Program Files\Numecent\Cloudpaging Studio\." }
        if ($check.UacEnabled) { $problems += "UAC is still enabled in the guest." }
        if (-NOT $check.NipScriptPresent) { $problems += "studio-nip.ps1 was not found at C:\NIP_software\studio-nip.ps1 in the guest." }

        if ($problems.Count -gt 0) {
            Write-Warning "Baseline checkpoint NOT created. Fix the following in the guest first (e.g. run CloudpagingStudio-prep.ps1), then re-run -Setup:"
            $problems | ForEach-Object { Write-Warning "  - $_" }
            return
        }

        Write-Host "Guest looks ready. Creating baseline checkpoint '$BaselineCheckpoint'..."
        Checkpoint-VM -Name $VMName -SnapshotName $BaselineCheckpoint
        Write-Host "Baseline checkpoint created. Future packaging runs will restore to this point."
    }
    finally {
        Remove-PSSession $session -ErrorAction SilentlyContinue
    }
    return
}

# Packaging run
if (-NOT (Test-Path -Path $JsonConfigPath)) { throw "JSON config not found: $JsonConfigPath" }
if (-NOT (Test-Path -Path $InstallerPath)) { throw "Installer not found: $InstallerPath" }
if (-NOT (Get-VMSnapshot -VMName $VMName -Name $BaselineCheckpoint -ErrorAction SilentlyContinue)) {
    throw "Baseline checkpoint '$BaselineCheckpoint' not found on VM '$VMName'. Run -Setup first."
}

$cred = Get-Credential -Message "Guest admin credentials for VM '$VMName'"
$scratchDir = Join-Path $env:TEMP "VMPackaging_$AppName_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null

$hostAppOutput = Join-Path $HostOutputRoot $AppName
New-Item -ItemType Directory -Path $hostAppOutput -Force | Out-Null

$session = $null
try {
    Write-Host "Restoring '$VMName' to baseline checkpoint '$BaselineCheckpoint' (any current VM state will be discarded)..."
    Restore-VMSnapshot -VMName $VMName -Name $BaselineCheckpoint -Confirm:$false

    $session = Start-VMAndWait -VMName $VMName -Credential $cred -TimeoutSec $BootTimeoutSec

    $guestAppRoot = "$GuestNipRoot\$AppName"
    $guestInstallerCfg = "$guestAppRoot\Installer_Cfg"
    $guestOutput = "$guestAppRoot\Output"

    Write-Host "Creating guest folders under $guestAppRoot..."
    Invoke-Command -Session $session -ScriptBlock {
        param($installerCfg, $output)
        New-Item -ItemType Directory -Path $installerCfg -Force | Out-Null
        New-Item -ItemType Directory -Path $output -Force | Out-Null
    } -ArgumentList $guestInstallerCfg, $guestOutput

    $installerFileName = Split-Path $InstallerPath -Leaf
    $patchedJson = New-GuestPatchedConfig -SourceJsonPath $JsonConfigPath `
        -GuestInstallerCfgPath $guestInstallerCfg -GuestOutputPath $guestOutput `
        -InstallerFileName $installerFileName -ScratchDir $scratchDir

    Write-Host "Copying installer and config into the guest..."
    Copy-Item -Path $InstallerPath -Destination $guestInstallerCfg -ToSession $session
    Copy-Item -Path $patchedJson -Destination $guestInstallerCfg -ToSession $session
    $guestJsonPath = "$guestInstallerCfg\$(Split-Path $patchedJson -Leaf)"

    Write-Host "Running studio-nip.ps1 inside the guest..."
    Invoke-Command -Session $session -ScriptBlock {
        param($nipScript, $configPath)
        & $nipScript -config_file_path $configPath
    } -ArgumentList "$GuestNipRoot\studio-nip.ps1", $guestJsonPath | ForEach-Object { Write-Host $_ }

    Write-Host "Copying output back to $hostAppOutput..."
    Copy-Item -Path "$guestOutput\*" -Destination $hostAppOutput -Recurse -FromSession $session -Force

    $produced = Get-ChildItem -Path $hostAppOutput -Filter *.stp -ErrorAction SilentlyContinue
    if ($produced) {
        Write-Host "Packaging succeeded: $($produced.FullName -join ', ')"
    }
    else {
        Write-Warning "No .stp file found in $hostAppOutput -- check the studio-nip.ps1 output above for errors."
    }
}
finally {
    if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }

    if (-NOT $SkipRevertAfter) {
        Write-Host "Reverting '$VMName' back to baseline checkpoint '$BaselineCheckpoint'..."
        Restore-VMSnapshot -VMName $VMName -Name $BaselineCheckpoint -Confirm:$false
    }
    else {
        Write-Host "Skipping post-run revert (-SkipRevertAfter). VM '$VMName' left running for inspection."
    }
}
