########################################################################
#  Start-PackagingGui.ps1
#
#  Launcher for the Cloudpaging Automated-Packaging WPF GUI. Loads the
#  required assemblies, dot-sources the Gui\ modules, then loads and
#  shows Gui\MainWindow.xaml via Gui\MainWindow.ps1. Run this directly
#  (or right-click > Run with PowerShell) -- no other setup required
#  beyond what Invoke-VMPackaging.ps1 itself needs (Hyper-V module,
#  a configured VM, etc).
########################################################################

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms

$guiRoot = Join-Path $PSScriptRoot 'Gui'

. (Join-Path $guiRoot 'Modules\ListEditorControl.ps1')
. (Join-Path $guiRoot 'Modules\OutputScanner.ps1')
. (Join-Path $guiRoot 'Modules\PackagingRunner.ps1')
. (Join-Path $guiRoot 'Modules\CredentialHelper.ps1')

. (Join-Path $guiRoot 'MainWindow.ps1')
