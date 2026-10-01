<#
.SYNOPSIS
    Custom task module for Windows taskbar/start menu cleanup and wallpaper/lockscreen enforcement via Group Policy.
#>

function Get-DesktopCleanupTab {
    $tab = New-Object System.Windows.Controls.TabItem
    $tab.Header = "Desktop Cleanup"

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = 10

    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text = "Clean taskbar/start menu and configure wallpaper/lockscreen Group Policies."
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
        $noWall = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" -Name "NoChangingWallPaper" -ErrorAction SilentlyContinue).NoChangingWallPaper
        $noLock = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoChangingLockScreen" -ErrorAction SilentlyContinue).NoChangingLockScreen
        $wallPolicy = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "Wallpaper" -ErrorAction SilentlyContinue).Wallpaper

        if ($noWall -eq 1 -or $noLock -eq 1 -or $wallPolicy) {
            $statusText.Text = "Current state: POLICIES ENFORCED (Wallpaper/Lock Screen Locked)"
            $statusText.Foreground = 'IndianRed'
        }
        else {
            $statusText.Text = "Current state: ALLOWED (Customization Unrestricted)"
            $statusText.Foreground = 'LightGreen'
        }
    }.GetNewClosure()

    & $updateStatusLabel
    $btnRefresh.Add_Click({ & $updateStatusLabel }.GetNewClosure())

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = 'Horizontal'
    $btnRow.Margin = "0,0,0,10"

    $btnApply = New-Object System.Windows.Controls.Button
    $btnApply.Content = "Run Cleanup & Apply Policies"

    $btnRevert = New-Object System.Windows.Controls.Button
    $btnRevert.Content = "Remove Policies (Allow Changes)"

    $btnRow.Children.Add($btnApply) | Out-Null
    $btnRow.Children.Add($btnRevert) | Out-Null
    $panel.Children.Add($btnRow) | Out-Null

    $btnApply.Add_Click({
        $btnApply.IsEnabled = $false; $btnRevert.IsEnabled = $false; $btnRefresh.IsEnabled = $false
        Write-Log "Starting desktop cleanup and policy application..."

        Start-BackgroundTask -Work {
            param($SyncHash)

            $os = Get-CimInstance -ClassName Win32_OperatingSystem
            $caption = $os.Caption
            $build = [int]($os.BuildNumber)
            $SyncHash.LogQueue.Enqueue("Detected OS: $caption (Build $build)")

            $isWin11 = $build -ge 22000
            $isWin10 = $build -ge 10240 -and $build -lt 22000

            if ($isWin11) {
                $SyncHash.LogQueue.Enqueue("Applying Windows 11 taskbar changes...")
                Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2

                $taskbarPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
                if (Test-Path $taskbarPath) {
                    Remove-Item "$taskbarPath\*" -Force -ErrorAction SilentlyContinue
                    $SyncHash.LogQueue.Enqueue("Removed pinned shortcuts from TaskBar folder.")
                }

                $taskbandKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
                if (Test-Path $taskbandKey) {
                    Remove-Item $taskbandKey -Recurse -Force -ErrorAction SilentlyContinue
                    $SyncHash.LogQueue.Enqueue("Removed Taskband registry key.")
                }

                Start-Process explorer.exe
                Start-Sleep -Seconds 2
                $SyncHash.LogQueue.Enqueue("Taskbar pins cleared.")

                $advKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
                if (-not (Test-Path $advKey)) {
                    New-Item -Path $advKey -Force | Out-Null
                }
                Set-ItemProperty -Path $advKey -Name "TaskbarAl" -Value 0 -Type DWord
                $SyncHash.LogQueue.Enqueue("Taskbar alignment set to Left (TaskbarAl=0).")
            }
            elseif ($isWin10) {
                $SyncHash.LogQueue.Enqueue("Applying Windows 10 Start menu tile cleanup...")
                try {
                    $shell = New-Object -ComObject Shell.Application
                    $namespace = $shell.NameSpace('shell:::{4234d49b-0245-4df3-b780-3893943456e1}')
                    foreach ($item in $namespace.Items()) {
                        foreach ($verb in $item.Verbs()) {
                            $verbName = $verb.Name.Replace('&', '')
                            if ($verbName -match 'From "Start" UnPin|Unpin from Start') {
                                $verb.DoIt()
                            }
                        }
                    }
                    $SyncHash.LogQueue.Enqueue("All Start menu tiles unpinned.")
                } catch {
                    $SyncHash.LogQueue.Enqueue("[ERROR] Unpinning Start tiles: $($_.Exception.Message)")
                }
            }

            $imagePath = "C:\Windows\Web\Wallpapers\image.jpg"
            $SyncHash.LogQueue.Enqueue("Applying wallpaper and lockscreen Group Policies...")

            $wallpaperPolicyKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"
            if (-not (Test-Path $wallpaperPolicyKey)) {
                New-Item -Path $wallpaperPolicyKey -Force | Out-Null
            }
            Set-ItemProperty -Path $wallpaperPolicyKey -Name "Wallpaper" -Value $imagePath -Type String
            Set-ItemProperty -Path $wallpaperPolicyKey -Name "WallpaperStyle" -Value "10" -Type String

            $activeDesktopKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop"
            if (-not (Test-Path $activeDesktopKey)) {
                New-Item -Path $activeDesktopKey -Force | Out-Null
            }
            Set-ItemProperty -Path $activeDesktopKey -Name "NoChangingWallPaper" -Value 1 -Type DWord

            $lockScreenPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
            if (-not (Test-Path $lockScreenPolicyKey)) {
                New-Item -Path $lockScreenPolicyKey -Force | Out-Null
            }
            Set-ItemProperty -Path $lockScreenPolicyKey -Name "LockScreenImage" -Value $imagePath -Type String
            Set-ItemProperty -Path $lockScreenPolicyKey -Name "NoChangingLockScreen" -Value 1 -Type DWord

            gpupdate /force | Out-Null
            $SyncHash.LogQueue.Enqueue("Cleanup and policy enforcement completed.")
        } -OnDone {
            & $updateStatusLabel
            $btnApply.IsEnabled = $true; $btnRevert.IsEnabled = $true; $btnRefresh.IsEnabled = $true
        }
    }.GetNewClosure())

    $btnRevert.Add_Click({
        $btnApply.IsEnabled = $false; $btnRevert.IsEnabled = $false; $btnRefresh.IsEnabled = $false
        Write-Log "Removing customization policies..."

        Start-BackgroundTask -Work {
            param($SyncHash)
            try {
                $activeDesktopKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop"
                if (Test-Path $activeDesktopKey) {
                    Remove-ItemProperty -Path $activeDesktopKey -Name "NoChangingWallPaper" -ErrorAction SilentlyContinue
                }

                $wallpaperPolicyKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"
                if (Test-Path $wallpaperPolicyKey) {
                    Remove-ItemProperty -Path $wallpaperPolicyKey -Name "Wallpaper" -ErrorAction SilentlyContinue
                    Remove-ItemProperty -Path $wallpaperPolicyKey -Name "WallpaperStyle" -ErrorAction SilentlyContinue
                }

                $lockScreenPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
                if (Test-Path $lockScreenPolicyKey) {
                    Remove-ItemProperty -Path $lockScreenPolicyKey -Name "NoChangingLockScreen" -ErrorAction SilentlyContinue
                    Remove-ItemProperty -Path $lockScreenPolicyKey -Name "LockScreenImage" -ErrorAction SilentlyContinue
                }

                gpupdate /force | Out-Null
                $SyncHash.LogQueue.Enqueue("Customization policies removed. Users can now change wallpaper and lock screen.")
            }
            catch {
                $SyncHash.LogQueue.Enqueue("[ERROR] Failed to revert policies: $($_.Exception.Message)")
            }
        } -OnDone {
            & $updateStatusLabel
            $btnApply.IsEnabled = $true; $btnRevert.IsEnabled = $true; $btnRefresh.IsEnabled = $true
        }
    }.GetNewClosure())

    $tab.Content = $panel
    return $tab
}