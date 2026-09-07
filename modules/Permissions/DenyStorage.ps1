<#
.SYNOPSIS
    Permissions / DenyStorage module. Toggles the same registry value that
    Group Policy writes for:
      Computer Configuration > Administrative Templates > System >
      Removable Storage Access > "All Removable Storage classes: Deny all access"

    Registry path: HKLM\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices
    Value: Deny_All (DWORD) -- 1 = deny, 0/absent = allow

    Using the policy key (rather than just disabling the USBSTOR driver)
    means gpupdate/gpresult see it as a real policy, and it also blocks
    storage-class access over other buses, not just USB.
#>

$Global:UsbPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices"

function Get-DenyUsbStorageTab {
    $tab = New-Object System.Windows.Controls.TabItem
    $tab.Header = "USB Storage"

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = 10

    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text = "Blocks read/write access to all removable storage devices (USB drives, SD cards, etc.) via the same policy Group Policy uses."
    $desc.TextWrapping = 'Wrap'
    $desc.Margin = "0,0,0,10"
    $panel.Children.Add($desc) | Out-Null

    $statusText = New-Object System.Windows.Controls.TextBlock
    $statusText.FontWeight = 'Bold'
    $statusText.Margin = "0,0,0,10"
    $panel.Children.Add($statusText) | Out-Null

    # A scriptblock variable (not a nested "function") so it survives as part
    # of the button click handlers' captured closure after this function returns.
    $updateStatusLabel = {
        $current = Get-ItemProperty -Path $Global:UsbPolicyPath -Name "Deny_All" -ErrorAction SilentlyContinue
        if ($current -and $current.Deny_All -eq 1) {
            $statusText.Text = "Current state: BLOCKED"
            $statusText.Foreground = 'IndianRed'
        }
        else {
            $statusText.Text = "Current state: ALLOWED"
            $statusText.Foreground = 'LightGreen'
        }
    }.GetNewClosure()
    & $updateStatusLabel

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = 'Horizontal'

    $btnBlock = New-Object System.Windows.Controls.Button
    $btnBlock.Content = "Block USB Storage"

    $btnAllow = New-Object System.Windows.Controls.Button
    $btnAllow.Content = "Allow USB Storage"

    $btnRow.Children.Add($btnBlock) | Out-Null
    $btnRow.Children.Add($btnAllow) | Out-Null
    $panel.Children.Add($btnRow) | Out-Null

    $note = New-Object System.Windows.Controls.TextBlock
    $note.Text = "Devices already plugged in may need to be unplugged/replugged, or the machine restarted, for the change to fully take effect."
    $note.TextWrapping = 'Wrap'
    $note.Foreground = 'Gray'
    $note.Margin = "0,10,0,0"
    $panel.Children.Add($note) | Out-Null

    $btnBlock.Add_Click({
        $btnBlock.IsEnabled = $false; $btnAllow.IsEnabled = $false
        Write-Log "Blocking USB storage access..."
        Start-BackgroundTask -ArgumentList @($Global:UsbPolicyPath) -Work {
            param($SyncHash, $PolicyPath)
            try {
                if (-not (Test-Path $PolicyPath)) {
                    New-Item -Path $PolicyPath -Force | Out-Null
                }
                Set-ItemProperty -Path $PolicyPath -Name "Deny_All" -Value 1 -Type DWord
                gpupdate /target:computer /force | Out-Null
                $SyncHash.LogQueue.Enqueue("USB storage access blocked.")
            }
            catch {
                $SyncHash.LogQueue.Enqueue("[ERROR] Failed to block USB storage: $($_.Exception.Message)")
            }
        } -OnDone {
            & $updateStatusLabel
            $btnBlock.IsEnabled = $true; $btnAllow.IsEnabled = $true
        }.GetNewClosure()
    }.GetNewClosure())

    $btnAllow.Add_Click({
        $btnBlock.IsEnabled = $false; $btnAllow.IsEnabled = $false
        Write-Log "Allowing USB storage access..."
        Start-BackgroundTask -ArgumentList @($Global:UsbPolicyPath) -Work {
            param($SyncHash, $PolicyPath)
            try {
                if (Test-Path $PolicyPath) {
                    Remove-ItemProperty -Path $PolicyPath -Name "Deny_All" -ErrorAction SilentlyContinue
                }
                gpupdate /target:computer /force | Out-Null
                $SyncHash.LogQueue.Enqueue("USB storage access allowed.")
            }
            catch {
                $SyncHash.LogQueue.Enqueue("[ERROR] Failed to allow USB storage: $($_.Exception.Message)")
            }
        } -OnDone {
            & $updateStatusLabel
            $btnBlock.IsEnabled = $true; $btnAllow.IsEnabled = $true
        }.GetNewClosure()
    }.GetNewClosure())

    $tab.Content = $panel
    return $tab
}