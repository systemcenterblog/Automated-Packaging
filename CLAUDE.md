# Cloudpaging Automated-Packaging

This repo automates application packaging with Numecent's **Cloudpaging Studio**: it takes a Windows installer, silently installs and captures it inside a disposable Hyper-V VM, and produces a Cloudpaging `.stp` appset — driven end-to-end by a JSON config file and PowerShell.

There is no Python/tools/workflows layer here (despite what an earlier version of this file said) — the whole pipeline is PowerShell + JSON + Hyper-V.

## Pipeline

```text
CreateJson.ps1  ──►  JSON config  ──►  Invoke-VMPackaging.ps1  ──►  studio-nip.ps1 (inside guest VM)  ──►  .stp appset
```

- **[CreateJson.ps1](CreateJson.ps1)** — generates a packaging JSON config from an installer file + optional parameters (silent-install args, file/registry exclusions, custom dispositions, file/registry additions, etc.). Fully parameterized; see its param block for the complete list. Hardcoded baseline exclusions live in the JSON template inside this script — caller-supplied exclusions are appended on top, never replacing them.
- **[Invoke-VMPackaging.ps1](Invoke-VMPackaging.ps1)** — the host-side orchestrator. Restores a Hyper-V VM to a clean baseline checkpoint, boots it, copies the installer + JSON in, runs `studio-nip.ps1` inside the guest via PowerShell Direct, copies the output back to `Output\<AppName>\`, then reverts the VM. Modes:
  - **`-Setup`**: one-time — verifies Studio is installed and UAC is disabled in the guest, then takes the baseline checkpoint.
  - **(default)**: full unattended run — silent install, capture, and finalize into `.stp` in one shot, VM always reverted after.
  - **`-CaptureOnly`** / **`-CollectOutput`**: two-phase run for when a human needs to review/customize the capture before it's finalized. `-CaptureOnly` captures (JSON forces `FinalizeIntoSTP=false`) and leaves the VM running instead of reverting. Studio's `-a` switch is fully non-interactive regardless of `FinalizeIntoSTP` — it captures headlessly, writes a `<ProjectName>.stw` project file to the guest output folder, and exits on its own; it does **not** stay open. `Invoke-VMPackaging.ps1` therefore launches `studio-nip.ps1` as a detached background process in the guest for `-CaptureOnly` (rather than waiting on it synchronously like the default mode does) so the host script isn't blocked on Studio's own internal `Start-Process -Wait`. An engineer then connects, waits for the capture to finish, manually launches Cloudpaging Studio, opens the `.stw`, reviews/customizes, and clicks Build. `-CollectOutput` reconnects to that same VM (without restoring it — that would destroy the engineer's work), collects the finished `.stp`, then reverts. State between the two calls is tracked via `Output\<AppName>\_pending-review.json`.
- **[studio-nip.ps1](studio-nip.ps1)** — runs inside the guest VM (from Numecent, treat as vendored/third-party — don't casually rewrite it). Reads the JSON config, builds a silent-install wrapper batch file and Studio's INI/DAT filter files from it, then drives `JukeboxStudio.exe`/`CloudpagingStudio.exe` non-interactively (`-a`) to install, capture, and (if `OutputSettings.FinalizeIntoSTP` is true) finalize into a `.stp`.
- **[CloudpagingStudio-prep.ps1](CloudpagingStudio-prep.ps1)** — one-time guest environment prep (disables Windows Update, Defender cloud protection, Search, Superfetch, System Restore, scheduled tasks, UAC). Run manually inside the guest before `-Setup`; not called automatically by `Invoke-VMPackaging.ps1`.

## JSON config schema

The full schema (`ProjectSettings`, `CaptureSettings`, `CaptureCommands`, `PostCaptureCommands`, `ModifyAssets`, `VirtualizationSettings`, `SecurityOverrideSettings`, `OutputSettings`) is documented with examples in [README.md](README.md). `Samples/` contains ~150 real-world example configs (one JSON per app) that are useful references for how a given installer type/vendor is typically configured.

## Directory layout

```text
CreateJson.ps1              # Generates a JSON packaging config from an installer + params
Invoke-VMPackaging.ps1      # Host-side orchestrator (Hyper-V + PowerShell Direct)
studio-nip.ps1              # Runs inside the guest VM, drives Cloudpaging Studio non-interactively
CloudpagingStudio-prep.ps1  # One-time guest environment prep (run manually inside guest)
Samples/<App>/*.json        # ~150 example packaging configs, one per application
Example_JSON_1.*.json       # Minimal schema examples referenced by README.md
Output/<AppName>/           # Per-app output: .stp, JSON copy, logs. Gitignored, regenerated per run.
```

No `.env`, `tools/`, or `workflows/` directories exist in this repo — there are no external API integrations here; everything runs against a local Hyper-V VM and the local filesystem.

## Working in this repo

- **`Invoke-VMPackaging.ps1` requires a real Hyper-V VM** with Cloudpaging Studio installed and a `Studio-Baseline` checkpoint (via `-Setup`) to actually run — most changes to it can only be verified end-to-end against that VM, not by static checks alone.
- **`studio-nip.ps1` is vendor-supplied** (Numecent) — prefer changing `CreateJson.ps1`/`Invoke-VMPackaging.ps1` to get the desired JSON/behavior rather than modifying this script, unless there's a genuine bug in it.
- When adding new JSON-config-affecting parameters, add them to **both** `CreateJson.ps1`'s param block/JSON template **and** `Invoke-VMPackaging.ps1`'s `$script:CreateJsonParamNames` passthrough list, or `Invoke-VMPackaging.ps1` won't forward them when auto-generating the JSON.
