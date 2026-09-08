<#
.SYNOPSIS
    Accounts / EnableDefaultAdmin module.

    Order of operations matters here -- we never touch the current user's
    group membership until the built-in Administrator account has been
    confirmed enabled AND its password has been confirmed set. If either
    of those fails, the demote step is skipped entirely so you can't end up
    with no working admin account on the box.

    Uses well-known SIDs (S-1-5-32-544 = Administrators, S-1-5-32-545 =
    Users) instead of the group names, since "Administrators"/"Users" are
    localized on non-English Windows builds.
#>

function Get-EnableDefaultAdminTab {
    $tab = New-Object System.Windows.Controls.TabItem
    $tab.Header = "Local Accounts"

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = 10

    $warn = New-Object System.Windows.Controls.TextBlock
    $warn.Text = "This enables the built-in Administrator account, sets its password, then removes the CURRENT user ($([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)) from the Administrators group and adds it to Users. Make sure you will remember the Administrator password -- it becomes your only local admin account after this runs."
    $warn.TextWrapping = 'Wrap'
    $warn.Foreground = 'IndianRed'
    $warn.FontWeight = 'Bold'
    $warn.Margin = "0,0,0,14"
    $panel.Children.Add($warn) | Out-Null

    $lblPw = New-Object System.Windows.Controls.TextBlock
    $lblPw.Text = "New password for Administrator account:"
    $panel.Children.Add($lblPw) | Out-Null

    $pwBox = New-Object System.Windows.Controls.PasswordBox
    $pwBox.Width = 300
    $pwBox.HorizontalAlignment = 'Left'
    $pwBox.Margin = "0,4,0,10"
    $panel.Children.Add($pwBox) | Out-Null

    $lblPw2 = New-Object System.Windows.Controls.TextBlock
    $lblPw2.Text = "Confirm password:"
    $panel.Children.Add($lblPw2) | Out-Null

    $pwBox2 = New-Object System.Windows.Controls.PasswordBox
    $pwBox2.Width = 300
    $pwBox2.HorizontalAlignment = 'Left'
    $pwBox2.Margin = "0,4,0,10"
    $panel.Children.Add($pwBox2) | Out-Null

    $reqText = New-Object System.Windows.Controls.TextBlock
    $reqText.Text = "Minimum 8 characters, and at least 3 of: uppercase, lowercase, digit, symbol."
    $reqText.Foreground = 'Gray'
    $reqText.FontSize = 11
    $reqText.Margin = "0,0,0,10"
    $panel.Children.Add($reqText) | Out-Null

    $validationText = New-Object System.Windows.Controls.TextBlock
    $validationText.Foreground = 'IndianRed'
    $validationText.TextWrapping = 'Wrap'
    $validationText.Margin = "0,0,0,10"
    $panel.Children.Add($validationText) | Out-Null

    $btnApply = New-Object System.Windows.Controls.Button
    $btnApply.Content = "Enable Administrator, Set Password, and Demote Current User"
    $btnApply.HorizontalAlignment = 'Left'
    $panel.Children.Add($btnApply) | Out-Null

    $btnApply.Add_Click({
        $validationText.Text = ""
        $pw1 = $pwBox.Password
        $pw2 = $pwBox2.Password

        if ([string]::IsNullOrEmpty($pw1) -or [string]::IsNullOrEmpty($pw2)) {
            $validationText.Text = "Enter and confirm a password."
            return
        }
        if ($pw1 -ne $pw2) {
            $validationText.Text = "Passwords do not match."
            return
        }
        if ($pw1.Length -lt 8) {
            $validationText.Text = "Password must be at least 8 characters."
            return
        }
        $categories = 0
        if ($pw1 -cmatch '[A-Z]') { $categories++ }
        if ($pw1 -cmatch '[a-z]') { $categories++ }
        if ($pw1 -match '[0-9]') { $categories++ }
        if ($pw1 -match '[^a-zA-Z0-9]') { $categories++ }
        if ($categories -lt 3) {
            $validationText.Text = "Password needs at least 3 of: uppercase, lowercase, digit, symbol."
            return
        }

        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

        $confirmMsg = "This will:`n`n1. Enable the built-in Administrator account`n2. Set its password`n3. Remove '$currentUser' from Administrators`n4. Add '$currentUser' to Users`n`nYou will need to sign out and back in (or restart) for the group change to apply. Continue?"
        $result = [System.Windows.MessageBox]::Show($confirmMsg, "Confirm Account Changes", 'YesNo', 'Warning')
        if ($result -ne 'Yes') {
            $validationText.Text = "Cancelled."
            $pwBox.Password = ""; $pwBox2.Password = ""
            return
        }

        $securePw = ConvertTo-SecureString -String $pw1 -AsPlainText -Force
        $pwBox.Password = ""; $pwBox2.Password = ""
        $pw1 = $null; $pw2 = $null

        $btnApply.IsEnabled = $false
        Write-Log "Starting local account changes for user '$currentUser'..."

        Start-BackgroundTask -ArgumentList @($securePw, $currentUser) -Work {
            param($SyncHash, [SecureString] $SecurePassword, $CurrentUser)

            $adminAccountReady = $false

            # --- Step 1 & 2: enable Administrator and set its password -------
            try {
                $admin = Get-LocalUser -Name "Administrator" -ErrorAction Stop
                if (-not $admin.Enabled) {
                    Enable-LocalUser -Name "Administrator" -ErrorAction Stop
                    $SyncHash.LogQueue.Enqueue("Administrator account enabled.")
                }
                else {
                    $SyncHash.LogQueue.Enqueue("Administrator account was already enabled.")
                }

                Set-LocalUser -Name "Administrator" -Password $SecurePassword -ErrorAction Stop
                $SyncHash.LogQueue.Enqueue("Administrator password set.")

                # Verify before proceeding any further
                $verify = Get-LocalUser -Name "Administrator" -ErrorAction Stop
                if ($verify.Enabled) {
                    $adminAccountReady = $true
                    $SyncHash.LogQueue.Enqueue("Verified: Administrator account is enabled.")
                }
                else {
                    $SyncHash.LogQueue.Enqueue("[ERROR] Administrator account did not verify as enabled. Aborting before touching current user's group membership.")
                }
            }
            catch {
                $SyncHash.LogQueue.Enqueue("[ERROR] Failed to enable/configure Administrator account: $($_.Exception.Message)")
                $SyncHash.LogQueue.Enqueue("Aborting -- current user's group membership was NOT changed.")
            }

            if (-not $adminAccountReady) {
                return
            }

            # --- Step 3 & 4: only run if Administrator is confirmed working --
            try {
                $adminGroup = Get-LocalGroup -SID "S-1-5-32-544" -ErrorAction Stop
                $usersGroup = Get-LocalGroup -SID "S-1-5-32-545" -ErrorAction Stop

                try {
                    Add-LocalGroupMember -SID $usersGroup.SID -Member $CurrentUser -ErrorAction Stop
                    $SyncHash.LogQueue.Enqueue("Added '$CurrentUser' to $($usersGroup.Name).")
                }
                catch {
                    if ($_.Exception.Message -match "already a member") {
                        $SyncHash.LogQueue.Enqueue("'$CurrentUser' is already a member of $($usersGroup.Name).")
                    }
                    else {
                        $SyncHash.LogQueue.Enqueue("[ERROR] Failed to add '$CurrentUser' to Users group: $($_.Exception.Message)")
                    }
                }

                try {
                    Remove-LocalGroupMember -SID $adminGroup.SID -Member $CurrentUser -ErrorAction Stop
                    $SyncHash.LogQueue.Enqueue("Removed '$CurrentUser' from $($adminGroup.Name).")
                    $SyncHash.LogQueue.Enqueue("Done. Sign out and back in (or restart) for the change to take effect.")
                }
                catch {
                    $SyncHash.LogQueue.Enqueue("[ERROR] Failed to remove '$CurrentUser' from Administrators: $($_.Exception.Message)")
                }
            }
            catch {
                $SyncHash.LogQueue.Enqueue("[ERROR] Failed to resolve local groups by SID: $($_.Exception.Message)")
            }
        } -OnDone {
            $btnApply.IsEnabled = $true
        }.GetNewClosure()
    }.GetNewClosure())

    $tab.Content = $panel
    return $tab
}