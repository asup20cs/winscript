<#
.SYNOPSIS
    Permissions / DenyStorage module. Toggles USB and removable storage access
    via Group Policy registry settings and system storage driver controls.
#>

function Get-DenyUsbStorageTab {
    $tab = New-Object System.Windows.Controls.TabItem
    $tab.Header = "USB Storage"

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = 10

    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text = "Blocks read/write access to all removable storage devices (USB drives, SD cards, etc.) via Group Policy and driver controls."
    $desc.TextWrapping = 'Wrap'
    $desc.Margin = "0,0,0,10"
    $panel.Children.Add($desc) | Out-Null

    $statusRow = New-Object System.Windows.Controls.StackPanel
    $statusRow.Orientation = 'Horizontal'
    $statusRow.Margin = "0,0,0,10"

    $statusText = New-Object System.Windows.Controls.TextBlock
    $statusText.FontWeight = 'Bold'
    $statusText.VerticalAlignment = 'Center'
    $statusRow.Children.Add($statusText) | Out-Null

    $btnRefresh = New-Object System.Windows.Controls.Button
    $btnRefresh.Content = "Refresh"
    $btnRefresh.Margin = "12,0,0,0"
    $btnRefresh.Padding = "8,2,8,2"
    $statusRow.Children.Add($btnRefresh) | Out-Null

    $panel.Children.Add($statusRow) | Out-Null

    $updateStatusLabel = {
        $isBlocked = $false

        if (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices") {
            $hklmDeny = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices" -Name "Deny_All" -ErrorAction SilentlyContinue).Deny_All
            if ($hklmDeny -eq 1) {
                $isBlocked = $true
            }
            $subkeys = Get-ChildItem -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices" -ErrorAction SilentlyContinue
            foreach ($sk in $subkeys) {
                $p = Get-ItemProperty -Path $sk.PSPath -ErrorAction SilentlyContinue
                if ($p.Deny_All -eq 1 -or $p.Deny_Read -eq 1 -or $p.Deny_Write -eq 1 -or $p.Deny_Execute -eq 1) {
                    $isBlocked = $true
                    break
                }
            }
        }

        if (Test-Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices") {
            $hkcuDeny = (Get-ItemProperty -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices" -Name "Deny_All" -ErrorAction SilentlyContinue).Deny_All
            if ($hkcuDeny -eq 1) {
                $isBlocked = $true
            }
        }

        $usbstor = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" -Name "Start" -ErrorAction SilentlyContinue).Start
        if ($usbstor -eq 4) {
            $isBlocked = $true
        }

        $sdp = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies" -Name "WriteProtect" -ErrorAction SilentlyContinue).WriteProtect
        if ($sdp -eq 1) {
            $isBlocked = $true
        }

        if ($isBlocked) {
            $statusText.Text = "Current state: BLOCKED"
            $statusText.Foreground = 'IndianRed'
        }
        else {
            $statusText.Text = "Current state: ALLOWED"
            $statusText.Foreground = 'LightGreen'
        }
    }.GetNewClosure()

    & $updateStatusLabel
    $btnRefresh.Add_Click({ & $updateStatusLabel }.GetNewClosure())

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
        $btnBlock.IsEnabled = $false; $btnAllow.IsEnabled = $false; $btnRefresh.IsEnabled = $false
        Write-Log "Blocking USB storage access..."
        Start-BackgroundTask -Work {
            param($SyncHash)
            try {
                $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices"
                if (-not (Test-Path $policyPath)) {
                    New-Item -Path $policyPath -Force | Out-Null
                }
                Set-ItemProperty -Path $policyPath -Name "Deny_All" -Value 1 -Type DWord

                if (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR") {
                    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" -Name "Start" -Value 4 -Type DWord -ErrorAction SilentlyContinue
                }

                gpupdate /target:computer /force | Out-Null
                $SyncHash.LogQueue.Enqueue("USB storage access blocked.")
            }
            catch {
                $SyncHash.LogQueue.Enqueue("[ERROR] Failed to block USB storage: $($_.Exception.Message)")
            }
        } -OnDone {
            & $updateStatusLabel
            $btnBlock.IsEnabled = $true; $btnAllow.IsEnabled = $true; $btnRefresh.IsEnabled = $true
        }
    }.GetNewClosure())

    $btnAllow.Add_Click({
        $btnBlock.IsEnabled = $false; $btnAllow.IsEnabled = $false; $btnRefresh.IsEnabled = $false
        Write-Log "Allowing USB storage access..."
        Start-BackgroundTask -Work {
            param($SyncHash)
            try {
                $policyHklm = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices"
                if (Test-Path $policyHklm) {
                    Remove-ItemProperty -Path $policyHklm -Name "Deny_All" -ErrorAction SilentlyContinue
                    Get-ChildItem -Path $policyHklm -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                }

                $policyHkcu = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices"
                if (Test-Path $policyHkcu) {
                    Remove-ItemProperty -Path $policyHkcu -Name "Deny_All" -ErrorAction SilentlyContinue
                    Get-ChildItem -Path $policyHkcu -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                }

                if (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR") {
                    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" -Name "Start" -Value 3 -Type DWord -ErrorAction SilentlyContinue
                }

                if (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\UASPSTOR") {
                    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\UASPSTOR" -Name "Start" -Value 3 -Type DWord -ErrorAction SilentlyContinue
                }

                $sdp = "HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies"
                if (Test-Path $sdp) {
                    Remove-ItemProperty -Path $sdp -Name "WriteProtect" -ErrorAction SilentlyContinue
                }

                gpupdate /target:computer /force | Out-Null
                $SyncHash.LogQueue.Enqueue("USB storage access allowed.")
            }
            catch {
                $SyncHash.LogQueue.Enqueue("[ERROR] Failed to allow USB storage: $($_.Exception.Message)")
            }
        } -OnDone {
            & $updateStatusLabel
            $btnBlock.IsEnabled = $true; $btnAllow.IsEnabled = $true; $btnRefresh.IsEnabled = $true
        }
    }.GetNewClosure())

    $tab.Content = $panel
    return $tab
}