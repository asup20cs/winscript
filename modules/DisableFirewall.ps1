<#
.SYNOPSIS
    Network / Firewall module. Toggles Windows Firewall for the Public and
    Private profiles using Set-NetFirewallProfile. Domain profile is left
    untouched (irrelevant on a workgroup/local-groups-only setup, and left
    alone anyway for domain-joined machines since it's usually managed by GPO).
#>

function Get-FirewallTab {
    $tab = New-Object System.Windows.Controls.TabItem
    $tab.Header = "Firewall"

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = 10

    $warn = New-Object System.Windows.Controls.TextBlock
    $warn.Text = "Turning the firewall off removes a layer of protection against network-based attacks on both profiles. Only do this on networks you trust, and re-enable it when you're done."
    $warn.TextWrapping = 'Wrap'
    $warn.Foreground = 'IndianRed'
    $warn.FontWeight = 'Bold'
    $warn.Margin = "0,0,0,10"
    $panel.Children.Add($warn) | Out-Null

    $statusText = New-Object System.Windows.Controls.TextBlock
    $statusText.FontWeight = 'Bold'
    $statusText.Margin = "0,0,0,10"
    $panel.Children.Add($statusText) | Out-Null

    $updateStatusLabel = {
        try {
            $profiles = Get-NetFirewallProfile -Profile Public, Private -ErrorAction Stop
            $lines = foreach ($p in $profiles) { "$($p.Name): $(if ($p.Enabled) { 'ON' } else { 'OFF' })" }
            $statusText.Text = "Current state -- " + ($lines -join "   |   ")
            if ($profiles | Where-Object { -not $_.Enabled }) {
                $statusText.Foreground = 'IndianRed'
            }
            else {
                $statusText.Foreground = 'LightGreen'
            }
        }
        catch {
            $statusText.Text = "Could not read firewall state: $($_.Exception.Message)"
            $statusText.Foreground = 'Gray'
        }
    }.GetNewClosure()
    & $updateStatusLabel

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = 'Horizontal'

    $btnDisable = New-Object System.Windows.Controls.Button
    $btnDisable.Content = "Turn Off Firewall (Public + Private)"

    $btnEnable = New-Object System.Windows.Controls.Button
    $btnEnable.Content = "Turn On Firewall (Public + Private)"

    $btnRow.Children.Add($btnDisable) | Out-Null
    $btnRow.Children.Add($btnEnable) | Out-Null
    $panel.Children.Add($btnRow) | Out-Null

    $btnDisable.Add_Click({
        $confirmMsg = "This will completely disable Windows Firewall for both the Public and Private network profiles. Continue?"
        $result = [System.Windows.MessageBox]::Show($confirmMsg, "Confirm Firewall Change", 'YesNo', 'Warning')
        if ($result -ne 'Yes') { return }

        $btnDisable.IsEnabled = $false; $btnEnable.IsEnabled = $false
        Write-Log "Disabling firewall for Public and Private profiles..."

        Start-BackgroundTask -Work {
            param($SyncHash)
            try {
                Set-NetFirewallProfile -Profile Public, Private -Enabled False -ErrorAction Stop
                $SyncHash.LogQueue.Enqueue("Firewall disabled for Public and Private profiles.")
            }
            catch {
                $SyncHash.LogQueue.Enqueue("[ERROR] Failed to disable firewall: $($_.Exception.Message)")
            }
        } -OnDone {
            & $updateStatusLabel
            $btnDisable.IsEnabled = $true; $btnEnable.IsEnabled = $true
        }.GetNewClosure()
    }.GetNewClosure())

    $btnEnable.Add_Click({
        $btnDisable.IsEnabled = $false; $btnEnable.IsEnabled = $false
        Write-Log "Enabling firewall for Public and Private profiles..."

        Start-BackgroundTask -Work {
            param($SyncHash)
            try {
                Set-NetFirewallProfile -Profile Public, Private -Enabled True -ErrorAction Stop
                $SyncHash.LogQueue.Enqueue("Firewall enabled for Public and Private profiles.")
            }
            catch {
                $SyncHash.LogQueue.Enqueue("[ERROR] Failed to enable firewall: $($_.Exception.Message)")
            }
        } -OnDone {
            & $updateStatusLabel
            $btnDisable.IsEnabled = $true; $btnEnable.IsEnabled = $true
        }.GetNewClosure()
    }.GetNewClosure())

    $tab.Content = $panel
    return $tab
}