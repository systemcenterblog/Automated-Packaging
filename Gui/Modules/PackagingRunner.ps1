########################################################################
#  PackagingRunner.ps1
#
#  Runs a script (Invoke-VMPackaging.ps1) asynchronously in a background
#  PowerShell runspace so the WPF UI thread never blocks, while streaming
#  its merged output/warning/error records back through a thread-safe
#  queue for a DispatcherTimer on the UI thread to drain. Neither
#  CreateJson.ps1 nor Invoke-VMPackaging.ps1 set an exit code, so success/
#  failure is determined by whether EndInvoke throws, not by exit codes.
########################################################################

function ConvertTo-PackagingDisplayText {
    param($Item)

    if ($Item -is [System.Management.Automation.ErrorRecord]) {
        return "ERROR: $($Item.Exception.Message)"
    }
    elseif ($Item -is [System.Management.Automation.WarningRecord]) {
        return "WARNING: $($Item.Message)"
    }
    elseif ($Item -is [System.Management.Automation.InformationRecord]) {
        return "$($Item.MessageData)"
    }
    elseif ($Item -is [System.Management.Automation.VerboseRecord]) {
        return "VERBOSE: $($Item.Message)"
    }
    elseif ($Item -is [System.Management.Automation.DebugRecord]) {
        return "DEBUG: $($Item.Message)"
    }
    else {
        return "$Item"
    }
}

function Start-PackagingJob {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Arguments
    )

    $outputQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $outputCollection = New-Object 'System.Management.Automation.PSDataCollection[psobject]'

    $outputCollection.add_DataAdded({
        param($sender, $e)
        $item = $sender[$e.Index]
        $outputQueue.Enqueue((ConvertTo-PackagingDisplayText -Item $item))
    }.GetNewClosure())

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.AddScript({
        param($ScriptPath, $Arguments)
        & $ScriptPath @Arguments *>&1
    }) | Out-Null
    $ps.AddArgument($ScriptPath) | Out-Null
    $ps.AddArgument($Arguments) | Out-Null

    $inputCollection = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $inputCollection.Complete()
    $asyncResult = $ps.BeginInvoke($inputCollection, $outputCollection)

    return [pscustomobject]@{
        PowerShell       = $ps
        AsyncResult      = $asyncResult
        OutputQueue      = $outputQueue
        OutputCollection = $outputCollection
    }
}

function Get-PackagingJobOutput {
    param(
        [Parameter(Mandatory)]$Job
    )
    $lines = @()
    $line = $null
    while ($Job.OutputQueue.TryDequeue([ref]$line)) {
        $lines += $line
    }
    return $lines
}

function Test-PackagingJobComplete {
    param(
        [Parameter(Mandatory)]$Job
    )
    return $Job.AsyncResult.IsCompleted
}

function Complete-PackagingJob {
    param(
        [Parameter(Mandatory)]$Job
    )
    try {
        $Job.PowerShell.EndInvoke($Job.AsyncResult) | Out-Null
        $result = [pscustomobject]@{ Success = $true; ErrorMessage = $null }
    }
    catch {
        $result = [pscustomobject]@{ Success = $false; ErrorMessage = $_.Exception.Message }
    }
    finally {
        $Job.PowerShell.Dispose()
    }
    return $result
}

function Stop-PackagingJob {
    param(
        [Parameter(Mandatory)]$Job
    )
    try {
        $Job.PowerShell.Stop()
    }
    catch {
        # best-effort cancellation only
    }
}
