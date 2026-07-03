########################################################################
#  OutputScanner.ps1
#
#  Read-only helpers for inspecting the Output\<AppName>\ convention
#  produced by Invoke-VMPackaging.ps1: pending-review detection, success
#  (.stp presence) detection, and locating the newest merge-results log.
########################################################################

function Get-PendingReviewApps {
    param(
        [Parameter(Mandatory)][string]$HostOutputRoot
    )

    if (-NOT (Test-Path -Path $HostOutputRoot)) {
        return @()
    }

    $results = @()
    Get-ChildItem -Path $HostOutputRoot -Filter '_pending-review.json' -Recurse -Depth 1 -ErrorAction SilentlyContinue |
        ForEach-Object {
            try {
                $pending = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
                $results += [pscustomobject]@{
                    AppName            = $pending.AppName
                    VMName             = $pending.VMName
                    BaselineCheckpoint = $pending.BaselineCheckpoint
                    Timestamp          = $pending.Timestamp
                    Path               = $_.FullName
                }
            }
            catch {
                Write-Warning "Skipping unreadable pending-review file: $($_.FullName)"
            }
        }
    return $results
}

function Get-AppOutputFolder {
    param(
        [Parameter(Mandatory)][string]$HostOutputRoot,
        [Parameter(Mandatory)][string]$AppName
    )
    return (Join-Path $HostOutputRoot $AppName)
}

function Test-PackagingSucceeded {
    param(
        [Parameter(Mandatory)][string]$HostOutputRoot,
        [Parameter(Mandatory)][string]$AppName
    )
    $appFolder = Get-AppOutputFolder -HostOutputRoot $HostOutputRoot -AppName $AppName
    if (-NOT (Test-Path -Path $appFolder)) { return $false }
    $stp = Get-ChildItem -Path $appFolder -Filter '*.stp' -ErrorAction SilentlyContinue
    return [bool]$stp
}

function Get-LatestMergeResultsLog {
    param(
        [Parameter(Mandatory)][string]$HostOutputRoot,
        [Parameter(Mandatory)][string]$AppName
    )
    $appFolder = Get-AppOutputFolder -HostOutputRoot $HostOutputRoot -AppName $AppName
    if (-NOT (Test-Path -Path $appFolder)) { return $null }
    return Get-ChildItem -Path $appFolder -Filter '*_MERGE_RESULTS_*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
