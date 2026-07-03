########################################################################
#  CredentialHelper.ps1
#
#  Informational only: Invoke-VMPackaging.ps1's own Get-VMCredential
#  function already checks for a .env file next to itself and falls
#  back to the native Get-Credential popup, which works fine even when
#  launched from inside this GUI's process. This helper never reads
#  credential values and never writes .env -- it only reports whether
#  a .env file is present so the GUI can set user expectations about
#  whether a credential prompt will appear during a run.
########################################################################

function Get-CredentialHint {
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $envPath = Join-Path $RepoRoot '.env'
    if (Test-Path -Path $envPath) {
        return "Guest credentials found in .env -- no prompt expected during this run."
    }
    return "No .env found -- you may be prompted for guest VM credentials in a separate dialog during this run."
}
