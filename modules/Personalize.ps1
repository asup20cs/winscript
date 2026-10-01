<#
.SYNOPSIS
    Custom task module for Windows taskbar/start menu cleanup and wallpaper/lockscreen enforcement via Group Policy.

.DESCRIPTION
    - Windows 11: Unpins all taskbar items and aligns the taskbar to the left (direct registry edits, not Group Policy).
    - Windows 10: Unpins all Start menu tiles via the Shell COM object (not Group Policy).
    - Both versions: Sets the desktop wallpaper and lockscreen to
      C:\Windows\Web\Wallpapers\image.jpg, sets the wallpaper style to "Fill",
      and prevents the user from changing the background or lockscreen using
      Group Policy registry keys.

    Use the template rules:
      - Copy this file to modules/DesktopCleanup.ps1
      - Rename Get-TemplateTab to Get-DesktopCleanupTab
      - Add an entry to manifest.json:
        { "name": "Cleanup", "file": "modules/DesktopCleanup.ps1", "function": "Get-DesktopCleanupTab" }
#>

function Get-DesktopCleanupTab {
    $tab = New-Object System.Windows.Controls.TabItem
    $tab.Header = "Desktop Cleanup"

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = 10

    # ---------- UI: Buttons ----------
    $btnRun = New-Object System.Windows.Controls.Button
    $btnRun.Content = "Run Cleanup & Apply Policies"
    $btnRun.HorizontalAlignment = 'Left'
    $btnRun.Margin = "0,10,0,0"
    $btnRun.Add_Click({
        Write-Log "Starting desktop cleanup and policy application..."

        Start-BackgroundTask -ArgumentList @() -Work {
            param($SyncHash)

            # -------------------------------------------------
            # 1. Detect Windows version
            # -------------------------------------------------
            $os = Get-CimInstance -ClassName Win32_OperatingSystem
            $caption = $os.Caption
            $build = [int]($os.BuildNumber)

            $SyncHash.LogQueue.Enqueue("Detected OS: $caption (Build $build)")

            $isWin11 = $build -ge 22000
            $isWin10 = $build -ge 10240 -and $build -lt 22000

            # -------------------------------------------------
            # 2. Windows 11: Unpin taskbar + align left (direct registry edits)
            # -------------------------------------------------
            if ($isWin11) {
                $SyncHash.LogQueue.Enqueue("Applying Windows 11 taskbar changes (non-GP)...")

                # --- Unpin all taskbar items ---
                Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2

                # Remove pinned shortcuts
                $taskbarPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
                if (Test-Path $taskbarPath) {
                    Remove-Item "$taskbarPath\*" -Force -ErrorAction SilentlyContinue
                    $SyncHash.LogQueue.Enqueue("Removed pinned shortcuts from TaskBar folder.")
                }

                # Remove Taskband registry key
                $taskbandKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
                if (Test-Path $taskbandKey) {
                    Remove-Item $taskbandKey -Recurse -Force -ErrorAction SilentlyContinue
                    $SyncHash.LogQueue.Enqueue("Removed Taskband registry key.")
                }

                # Restart Explorer
                Start-Process explorer.exe
                Start-Sleep -Seconds 2
                $SyncHash.LogQueue.Enqueue("Taskbar pins cleared.")

                # --- Align taskbar to left (normal setting, not a policy) ---
                $advKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
                if (-not (Test-Path $advKey)) {
                    New-Item -Path $advKey -Force | Out-Null
                }
                Set-ItemProperty -Path $advKey -Name "TaskbarAl" -Value 0 -Type DWord
                $SyncHash.LogQueue.Enqueue("Taskbar alignment set to Left (TaskbarAl=0).")
            }

            # -------------------------------------------------
            # 3. Windows 10: Unpin all Start menu tiles (Shell COM, non-GP)
            # -------------------------------------------------
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
                    $SyncHash.LogQueue.Enqueue("Error unpinning Start tiles: $_")
                }
            } else {
                $SyncHash.LogQueue.Enqueue("Unsupported Windows version. Skipping taskbar/start cleanup.")
            }

            # -------------------------------------------------
            # 4. Apply wallpaper & lockscreen Group Policies
            # -------------------------------------------------
            $imagePath = "C:\Windows\Web\Wallpapers\image.jpg"
            $SyncHash.LogQueue.Enqueue("Applying wallpaper and lockscreen Group Policies...")

            # --- 4a. Desktop wallpaper (Active Desktop Wallpaper policy) ---
            # Policy: User Configuration > Administrative Templates > Desktop > Active Desktop
            #         > Active Desktop Wallpaper
            $wallpaperPolicyKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"
            if (-not (Test-Path $wallpaperPolicyKey)) {
                New-Item -Path $wallpaperPolicyKey -Force | Out-Null
            }
            Set-ItemProperty -Path $wallpaperPolicyKey -Name "Wallpaper" -Value $imagePath -Type String
            Set-ItemProperty -Path $wallpaperPolicyKey -Name "WallpaperStyle" -Value "10" -Type String   # 10 = Fill
            $SyncHash.LogQueue.Enqueue("Group Policy applied: Desktop wallpaper set to $imagePath with Fill style.")

            # --- 4b. Prevent changing desktop background ---
            # Policy: User Configuration > Administrative Templates > Control Panel > Display
            #         > Prevent changing wallpaper
            $activeDesktopKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop"
            if (-not (Test-Path $activeDesktopKey)) {
                New-Item -Path $activeDesktopKey -Force | Out-Null
            }
            Set-ItemProperty -Path $activeDesktopKey -Name "NoChangingWallPaper" -Value 1 -Type DWord
            $SyncHash.LogQueue.Enqueue("Group Policy applied: User cannot change desktop background.")

            # --- 4c. Lock screen image (machine policy) ---
            # Policy: Computer Configuration > Administrative Templates > Control Panel > Personalization
            #         > Force a specific default lock screen image
            $lockScreenPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
            if (-not (Test-Path $lockScreenPolicyKey)) {
                New-Item -Path $lockScreenPolicyKey -Force | Out-Null
            }
            Set-ItemProperty -Path $lockScreenPolicyKey -Name "LockScreenImage" -Value $imagePath -Type String
            $SyncHash.LogQueue.Enqueue("Group Policy applied: Lock screen image forced to $imagePath.")

            # --- 4d. Prevent changing lock screen image ---
            # Policy: Computer Configuration > Administrative Templates > Control Panel > Personalization
            #         > Prevent changing lock screen image
            Set-ItemProperty -Path $lockScreenPolicyKey -Name "NoChangingLockScreen" -Value 1 -Type DWord
            $SyncHash.LogQueue.Enqueue("Group Policy applied: User cannot change lock screen image.")

            # -------------------------------------------------
            # 5. Done
            # -------------------------------------------------
            $SyncHash.LogQueue.Enqueue("All tasks completed. A reboot or gpupdate /force may be required.")
        } -OnDone {
            Write-Log "Desktop cleanup and policy task finished."
        }
    }.GetNewClosure())
    $panel.Children.Add($btnRun) | Out-Null

    # Optional: a simple label explaining the actions
    $infoLabel = New-Object System.Windows.Controls.TextBlock
    $infoLabel.Text = "This tab will clean the taskbar/start menu and enforce wallpaper/lockscreen Group Policies."
    $infoLabel.TextWrapping = 'Wrap'
    $infoLabel.Margin = "0,10,0,0"
    $panel.Children.Add($infoLabel) | Out-Null

    $tab.Content = $panel
    return $tab
}