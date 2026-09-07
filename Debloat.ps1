<#
.SYNOPSIS
    Debloat module. Defines Get-DebloatTab, called by main.ps1 after this
    file is downloaded and Invoke-Expression'd.

    Contract for every module in this repo:
      - Expose one function (registered in manifest.json) that takes no
        parameters and returns a fully-built [System.Windows.Controls.TabItem].
      - Use the global Write-Log function for simple one-line log messages.
      - Use Start-BackgroundTask for anything that touches the filesystem,
        registry, or network so the GUI thread never blocks. Background
        scriptblocks run in a separate runspace: log via
        $SyncHash.LogQueue.Enqueue("text"), not Write-Log.
#>

function Get-DebloatTab {
    $tab = New-Object System.Windows.Controls.TabItem
    $tab.Header = "Debloat"

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'

    $mainPanel = New-Object System.Windows.Controls.StackPanel
    $mainPanel.Margin = 10

    # --- Toolbar: Select All / Select None ---------------------------------
    $toolbar = New-Object System.Windows.Controls.StackPanel
    $toolbar.Orientation = 'Horizontal'

    $btnAll = New-Object System.Windows.Controls.Button
    $btnAll.Content = "Select All"
    $btnNone = New-Object System.Windows.Controls.Button
    $btnNone.Content = "Select None"

    $toolbar.Children.Add($btnAll)  | Out-Null
    $toolbar.Children.Add($btnNone) | Out-Null
    $mainPanel.Children.Add($toolbar) | Out-Null

    $restoreCheck = New-Object System.Windows.Controls.CheckBox
    $restoreCheck.Content = "Create a System Restore Point first (recommended)"
    $restoreCheck.IsChecked = $true
    $restoreCheck.Margin = "4,10,4,10"
    $mainPanel.Children.Add($restoreCheck) | Out-Null

    # --- App checklist, loaded from config/debloat-list.json ---------------
    $appCheckboxes = New-Object System.Collections.Generic.List[object]

    try {
        $appList = Invoke-RestMethod -Uri "$BaseRepoUrl/config/debloat-list.json" -UseBasicParsing
    }
    catch {
        Write-Log "Failed to load debloat-list.json: $($_.Exception.Message)" "Error"
        $appList = @()
    }

    foreach ($app in $appList) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $app.Name
        $cb.Tag = $app.Package
        $cb.IsChecked = [bool]$app.Checked
        $mainPanel.Children.Add($cb) | Out-Null
        $appCheckboxes.Add($cb) | Out-Null
    }

    $btnAll.Add_Click({ foreach ($c in $appCheckboxes) { $c.IsChecked = $true } }.GetNewClosure())
    $btnNone.Add_Click({ foreach ($c in $appCheckboxes) { $c.IsChecked = $false } }.GetNewClosure())

    # --- Remove button -------------------------------------------------------
    $btnRemove = New-Object System.Windows.Controls.Button
    $btnRemove.Content = "Remove Selected Apps"
    $btnRemove.Margin = "4,16,4,4"
    $btnRemove.HorizontalAlignment = 'Left'
    $mainPanel.Children.Add($btnRemove) | Out-Null

    $btnRemove.Add_Click({
        $selected = @($appCheckboxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        if ($selected.Count -eq 0) {
            Write-Log "No apps selected." "Warn"
            return
        }

        $makeRestorePoint = [bool]$restoreCheck.IsChecked
        $btnRemove.IsEnabled = $false
        Write-Log "Removing $($selected.Count) app(s)..."

        Start-BackgroundTask -ArgumentList @($selected, $makeRestorePoint) -Work {
            param($SyncHash, $Packages, $MakeRestorePoint)

            if ($MakeRestorePoint) {
                try {
                    $SyncHash.LogQueue.Enqueue("Creating system restore point...")
                    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
                    Checkpoint-Computer -Description "WinTool Debloat" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
                    $SyncHash.LogQueue.Enqueue("Restore point created.")
                }
                catch {
                    $SyncHash.LogQueue.Enqueue("[WARN] Could not create restore point: $($_.Exception.Message)")
                }
            }

            foreach ($pkg in $Packages) {
                try {
                    $installed = Get-AppxPackage -AllUsers -Name $pkg -ErrorAction SilentlyContinue
                    if ($installed) {
                        $installed | Remove-AppxPackage -AllUsers -ErrorAction Stop
                        $SyncHash.LogQueue.Enqueue("Removed: $pkg")
                    }
                    else {
                        $SyncHash.LogQueue.Enqueue("Not installed, skipping: $pkg")
                    }

                    # Also remove the provisioned package so it doesn't come back for new user profiles
                    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                        Where-Object { $_.DisplayName -eq $pkg } |
                        ForEach-Object {
                            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
                        }
                }
                catch {
                    $SyncHash.LogQueue.Enqueue("[ERROR] Failed to remove $pkg`: $($_.Exception.Message)")
                }
            }

            $SyncHash.LogQueue.Enqueue("Debloat run finished.")
        } -OnDone {
            $btnRemove.IsEnabled = $true
        }.GetNewClosure()
    }.GetNewClosure())

    $scroll.Content = $mainPanel
    $tab.Content = $scroll
    return $tab
}
