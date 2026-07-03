# Wiki: Packaging 7-Zip

Worked examples of the packaging pipeline (see [CLAUDE.md](CLAUDE.md) for the architecture overview) using 7-Zip as the running example. The installer lives at [Samples/7-Zip/7-ZIP.exe](Samples/7-Zip/7-ZIP.exe); it installs silently with the `/S` switch.

## 1. Generate a JSON config only (`CreateJson.ps1`)

The simplest usage — just point it at the installer and let every other field default:

```powershell
.\CreateJson.ps1 -Filepath '.\Samples\7-Zip\7-ZIP.exe'
```

This writes `7-ZIP.json` next to the installer. `CreateJson.ps1` infers `/qn /norestart`-style defaults only for MSIs — for a plain `.exe` like 7-Zip's, `-Arguments` isn't inferred, so pass it explicitly to get a silent install:

```powershell
.\CreateJson.ps1 -Filepath '.\Samples\7-Zip\7-ZIP.exe' `
    -Name '7-Zip cloudpaged' `
    -Description '7-Zip auto-packaged test' `
    -Arguments '/S'
```

A real JSON produced this way is checked in at [Output/7-Zip-AutoGen/7-Zip-AutoGen.json](Output/7-Zip-AutoGen/7-Zip-AutoGen.json) — worth opening as a concrete reference alongside the annotated schema in [Example_JSON_1.3.json](Example_JSON_1.3.json). Notable bits in it:
- `CaptureCommands.PostInstallActions.Commands` contains the actual silent-install line: `C:\Windows\System32\cmd.exe /c "C:\NIP_software\auto\7-ZIP.exe" /S`
- `CaptureSettings.RegistryExclusions` / `FileExclusions` show the baseline exclusions `CreateJson.ps1` always bakes in (see [CLAUDE.md](CLAUDE.md))
- `OutputSettings.FinalizeIntoSTP: true` means Studio will build the `.stp` directly

### Adding customizations at JSON-generation time

`CreateJson.ps1` accepts arrays/objects for every customization type. Example: exclude 7-Zip's file-manager MRU registry key from capture, add an extra registry value after capture, and pin `7z.dll` to disposition layer 1:

```powershell
.\CreateJson.ps1 -Filepath '.\Samples\7-Zip\7-ZIP.exe' -Arguments '/S' `
    -RegistryExclusions @('HKEY_CURRENT_USER\Software\7-Zip\FM\CopyHistory') `
    -Registrymodify @(@{ Location = 'HKEY_LOCAL_MACHINE\SOFTWARE\7-Zip'; values = @('Associate=dword:00000001') }) `
    -CustomFileDisposition @(@{ Path = 'C:\Program Files\7-Zip\7z.dll'; Layer = 1; Recurse = $false })
```

## 2. Full unattended run (`Invoke-VMPackaging.ps1`, default mode)

One command does silent install → capture → finalize → collect `.stp`, no JSON file needed up front (it's auto-generated via `CreateJson.ps1` under the hood):

```powershell
.\Invoke-VMPackaging.ps1 -AppName '7-Zip' `
    -InstallerPath '.\Samples\7-Zip\7-ZIP.exe' `
    -Arguments '/S' `
    -Description '7-Zip auto-packaged'
```

Output lands in `Output\7-Zip\` — `7-Zip.stp`, a copy of the JSON used, and the capture log. Requires the VM to already have a `Studio-Baseline` checkpoint (`.\Invoke-VMPackaging.ps1 -Setup`, one-time).

To supply a hand-edited JSON instead of auto-generating one:

```powershell
.\Invoke-VMPackaging.ps1 -AppName '7-Zip' `
    -JsonConfigPath '.\Output\7-Zip-AutoGen\7-Zip-AutoGen.json' `
    -InstallerPath '.\Samples\7-Zip\7-ZIP.exe'
```

## 3. Two-phase run with a human review step (`-CaptureOnly` / `-CollectOutput`)

Use this when an engineer needs to eyeball the capture (or add customizations directly in Cloudpaging Studio's GUI) before the package is sealed.

**Phase 1 — capture, then pause:**

```powershell
.\Invoke-VMPackaging.ps1 -CaptureOnly -AppName '7-Zip' `
    -InstallerPath '.\Samples\7-Zip\7-ZIP.exe' `
    -Arguments '/S'
```

This silently installs and captures 7-Zip, but generates the JSON with `FinalizeIntoSTP=false`, so Studio never builds the `.stp`. The VM is left running (not reverted) and the script prints something like:

```text
Capture complete. VM 'CloudPagingStudio' is left running with project '7-Zip cloudpaged' open for review.
  1. Console/RDP into 'CloudPagingStudio'.
  2. Open Cloudpaging Studio and review the captured project.
  3. Add any additional customizations directly in Studio.
  4. Click Build/Finalize to produce the .stp.
  5. Run: .\Invoke-VMPackaging.ps1 -CollectOutput -AppName '7-Zip'
```

**Manual step:** console/RDP into the VM, open Cloudpaging Studio, confirm 7-Zip's files/registry were captured correctly, optionally add dispositions or extra files/keys directly in the Studio UI, then click Build.

**Phase 2 — collect the finished package:**

```powershell
.\Invoke-VMPackaging.ps1 -CollectOutput -AppName '7-Zip'
```

This reconnects to the still-running VM (it does **not** restore the VM first, so the engineer's work in Studio is preserved), copies the finished `.stp` back to `Output\7-Zip\`, marks the saved JSON's `FinalizeIntoSTP` as `true` for the record, then reverts the VM to baseline and removes the `_pending-review.json` state file.

> Note: the JSON copied back after `-CollectOutput` reflects the *capture-time* config only — any customizations made by hand in the Studio GUI are baked into the `.stp` but aren't reflected back into the JSON (Studio doesn't export project edits to this schema).

## 4. Common customizations, cheat-sheet

All of these are `CreateJson.ps1` / `Invoke-VMPackaging.ps1` parameters (the latter forwards them to the former when `-JsonConfigPath` isn't supplied):

| Goal | Parameter |
|---|---|
| Silent install switches | `-Arguments '/S'` |
| Extra file/registry to exclude from capture | `-FileExclusions`, `-RegistryExclusions` |
| Add a file after capture (e.g. a config file) | `-Fileaddition @(@{FileName='7-zip.ini'; FileDestination='C:\Program Files\7-Zip\'; FileContent=@('...')})` |
| Add/modify a registry value after capture | `-Registrymodify @(@{Location='HKEY_LOCAL_MACHINE\SOFTWARE\7-Zip'; values=@('Path=C:\\Program Files\\7-Zip')})` |
| Pin a specific file/folder to a disposition layer | `-CustomFileDisposition @(@{Path='...'; Layer=1; Recurse=$true})` |
| Pin a specific registry key to a disposition layer | `-CustomRegistryDisposition @(@{Location='...'; Layer=1; Recurse=$false})` |
| Exclude a path from the virtualization sandbox | `-SandboxFileExclusions`, `-SandboxRegistryExclusions` |
| Change compression/encryption | `-Compression 'LZMA'`, `-Encryption 'AES-256-Enhanced'` |
| Skip finalizing into `.stp` (leave project open) | `-FinalizeIntoSTP $false` (this is what `-CaptureOnly` sets automatically) |

See [README.md](README.md) for the full JSON schema and [Example_JSON_1.3.json](Example_JSON_1.3.json) for an annotated template covering every field.
