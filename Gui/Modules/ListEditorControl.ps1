########################################################################
#  ListEditorControl.ps1
#
#  Reusable wiring for a "list editor" widget: a ListBox + an input
#  TextBox + Add/Remove buttons, used for every simple string[] field
#  in the wizard (exclusions, custom commandlines, process lists, etc).
#  The XAML only needs to declare the four named controls; this module
#  wires their events and provides get/set helpers for the resulting
#  string[] value.
########################################################################

function Register-ListEditor {
    param(
        [Parameter(Mandatory)][System.Windows.Controls.ListBox]$ListBox,
        [Parameter(Mandatory)][System.Windows.Controls.TextBox]$InputBox,
        [Parameter(Mandatory)][System.Windows.Controls.Button]$AddButton,
        [Parameter(Mandatory)][System.Windows.Controls.Button]$RemoveButton
    )

    $addItem = {
        $text = $InputBox.Text.Trim()
        if ($text) {
            $ListBox.Items.Add($text) | Out-Null
            $InputBox.Text = ''
            $InputBox.Focus() | Out-Null
        }
    }.GetNewClosure()

    $AddButton.Add_Click($addItem)

    $InputBox.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq 'Return') {
            & $addItem
        }
    }.GetNewClosure())

    $RemoveButton.Add_Click({
        $selected = @($ListBox.SelectedItems)
        foreach ($item in $selected) {
            $ListBox.Items.Remove($item)
        }
    }.GetNewClosure())
}

function Get-ListEditorItems {
    param(
        [Parameter(Mandatory)][System.Windows.Controls.ListBox]$ListBox
    )
    return @($ListBox.Items | ForEach-Object { $_.ToString() })
}

function Set-ListEditorItems {
    param(
        [Parameter(Mandatory)][System.Windows.Controls.ListBox]$ListBox,
        [string[]]$Items
    )
    $ListBox.Items.Clear()
    foreach ($item in ($Items | Where-Object { $_ })) {
        $ListBox.Items.Add($item) | Out-Null
    }
}
