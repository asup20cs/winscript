<#
.SYNOPSIS
    AdminAccount module. Defines Get-AdminAccountTab, called by main.ps1 after
    this file is downloaded and Invoke-Expression'd.

    Follows the standard module contract:
      - One exported function returning a fully-built TabItem.
      - Write-Log on the GUI thread; $SyncHash.LogQueue.Enqueue in background work.

    What the tab does:
      1. Enables the built-in Administrator account (located by RID 500, so it
         works even if the account has been renamed).
      2. Sets a user-chosen password on it.
      3. Optionally (checkbox, default on) removes the account running the tool
         from the local Administrators group and adds it to the Users group.

    Safety notes:
      - No System Restore point is taken here on purpose: System Restore does
        not roll back SAM data (passwords / group membership), so it would give
        false comfort. Instead the script fails closed: the current user is only
        demoted AFTER the built-in Administrator is enabled, its new password
        has been accepted by Windows, and it is verified to be a member of the
        Administrators group.
      - Groups are resolved from well-known SIDs (S-1-5-32-544 / -545) so this
        works on non-English Windows installs.
#>

function Get-AdminAccountTab {
    $tab = New-Object System.Windows.Controls.TabItem
    $tab.Header = "Admin Account"

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'

    $mainPanel = New-Object System.Windows.Controls.StackPanel
    $mainPanel.Margin = 10

    # --- Explanation / warning block ----------------------------------------
    $info = New-Object System.Windows.Controls.TextBlock
    $info.TextWrapping = 'Wrap'
    $info.Margin = "4,4,4,8"
    $info.Text = ("This enables the built-in Windows Administrator account (hidden by default), " +
                  "sets a new password on it, and optionally turns the account you are using now " +
                  "into a Standard user. Afterwards, use the Administrator account for installs " +
                  "and system-wide changes.")
    $mainPanel.Children.Add($info) | Out-Null

    $warning = New-Object System.Windows.Controls.TextBlock
    $warning.TextWrapping = 'Wrap'
    $warning.Margin = "4,0,4,10"
    $warning.FontWeight = 'Bold'
    $warning.Foreground = [System.Windows.Media.Brushes]::Firebrick
    $warning.Text = ("Remember this password! If your own account is demoted, this password is " +
                     "the only way to approve installs and system changes afterwards.")
    $mainPanel.Children.Add($warning) | Out-Null

    # --- Password entry -------------------------------------------------------
    $lblPw = New-Object System.Windows.Controls.Label
    $lblPw.Content = "New Administrator password:"
    $lblPw.Margin = "0,4,0,0"
    $mainPanel.Children.Add($lblPw) | Out-Null

    $pwBox = New-Object System.Windows.Controls.PasswordBox
    $pwBox.Margin = "4,0,4,8"
    $mainPanel.Children.Add($pwBox) | Out-Null

    $lblPw2 = New-Object System.Windows.Controls.Label
    $lblPw2.Content = "Confirm password:"
    $mainPanel.Children.Add($lblPw2) | Out-Null

    $pwConfirm = New-Object System.Windows.Controls.PasswordBox
    $pwConfirm.Margin = "4,0,4,8"
    $mainPanel.Children.Add($pwConfirm) | Out-Null

    # --- Options ----------------------------------------------------------------
    $demoteCheck = New-Object System.Windows.Controls.CheckBox
    $demoteCheck.Content = "Demote the current account to a Standard user (remove from Administrators, add to Users)"
    $demoteCheck.IsChecked = $true
    $demoteCheck.Margin = "4,10,4,4"
    $mainPanel.Children.Add($demoteCheck) | Out-Null

    # --- Apply button ------------------------------------------------------------
    $btnApply = New-Object System.Windows.Controls.Button
    $btnApply.Content = "Enable Administrator && Apply"
    $btnApply.Margin = "4,16,4,4"
    $btnApply.HorizontalAlignment = 'Left'
    $mainPanel.Children.Add($btnApply) | Out-Null

    $btnApply.Add_Click({
        $pw1 = $pwBox.Password
        $pw2 = $pwConfirm.Password

        if ([string]::IsNullOrEmpty($pw1)) {
            Write-Log "Enter a password for the Administrator account." "Warn"
            return
        }
        if ($pw1 -cne $pw2) {
            Write-Log "Passwords do not match." "Warn"
            return
        }
        if ($pw1.Length -lt 8) {
            Write-Log "Password is short - Windows may reject it if a complexity policy is enabled." "Warn"
        }

        $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isElevated) {
            Write-Log "This tool must be running elevated (as Administrator) to change accounts." "Error"
            return
        }

        $demote = [bool]$demoteCheck.IsChecked
        $plan = if ($demote) { "and demote '$env:USERNAME' to a Standard user" } else { "(current user keeps its rights)" }
        $answer = [System.Windows.MessageBox]::Show(
            "Enable the built-in Administrator account, set its password, ${plan}?`n`nContinue?",
            "Confirm account change", 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }

        $btnApply.IsEnabled = $false
        Write-Log "Applying administrator account changes..."

        Start-BackgroundTask -ArgumentList @($pw1, $demote) -Work {
            param($SyncHash, $Password, $DemoteCurrent)

            try {
                # Resolve localized group names from well-known SIDs.
                # S-1-5-32-544 = Administrators, S-1-5-32-545 = Users.
                $adminsGroup = Get-LocalGroup -SID (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')) -ErrorAction Stop
                $usersGroup  = Get-LocalGroup -SID (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')) -ErrorAction Stop

                # Find the built-in Administrator by RID 500 (rename/locale-proof).
                $builtInAdmin = Get-LocalUser -ErrorAction Stop |
                    Where-Object { $_.SID.Value -match '-500$' } |
                    Select-Object -First 1
                if (-not $builtInAdmin) {
                    throw "Built-in Administrator account (RID 500) not found on this machine."
                }

                # Step 1: enable the account.
                $SyncHash.LogQueue.Enqueue("Enabling built-in Administrator account '$($builtInAdmin.Name)'...")
                Set-LocalUser -InputObject $builtInAdmin -Enabled $true -ErrorAction Stop
                $SyncHash.LogQueue.Enqueue("Account enabled.")

                # Step 2: set the password. If Windows rejects it (complexity
                # policy), we abort BEFORE touching the current user's groups.
                $secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
                try {
                    Set-LocalUser -InputObject $builtInAdmin -Password $secure -ErrorAction Stop
                    $SyncHash.LogQueue.Enqueue("Password set for '$($builtInAdmin.Name)'.")
                }
                catch {
                    throw "Windows rejected the password (complexity policy?). Nothing else was changed. Details: $($_.Exception.Message)"
                }

                # Step 3: demote the current account, now that a working admin exists.
                if ($DemoteCurrent) {
                    $identity   = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                    $currentSid = $identity.User.Value

                    if ($currentSid -eq $builtInAdmin.SID.Value) {
                        $SyncHash.LogQueue.Enqueue("[WARN] Tool is running AS the built-in Administrator; nothing to demote.")
                    }
                    else {
                        # Fail-closed: verify the built-in admin is in the Administrators
                        # group before removing anyone. (Get-LocalGroupMember can throw if
                        # the group contains orphaned SIDs - aborting there is intended.)
                        $adminPresent = Get-LocalGroupMember -Group $adminsGroup -ErrorAction Stop |
                            Where-Object { $_.SID.Value -eq $builtInAdmin.SID.Value }
                        if (-not $adminPresent) {
                            throw "Built-in Administrator is not in the Administrators group - refusing to demote '$($identity.Name)'."
                        }

                        try {
                            Remove-LocalGroupMember -Group $adminsGroup -Member $currentSid -ErrorAction Stop
                            $SyncHash.LogQueue.Enqueue("Removed '$($identity.Name)' from Administrators.")
                        }
                        catch {
                            $SyncHash.LogQueue.Enqueue("[WARN] Could not remove from Administrators (possibly not a member): $($_.Exception.Message)")
                        }

                        try {
                            Add-LocalGroupMember -Group $usersGroup -Member $currentSid -ErrorAction Stop
                            $SyncHash.LogQueue.Enqueue("Added '$($identity.Name)' to Users.")
                        }
                        catch {
                            $SyncHash.LogQueue.Enqueue("[ERROR] Could not add to Users group: $($_.Exception.Message)")
                        }

                        $SyncHash.LogQueue.Enqueue("Group changes apply to new sign-ins; already-running apps keep their old rights until restarted.")
                    }
                }
                else {
                    $SyncHash.LogQueue.Enqueue("Demote checkbox unticked - current user's group membership untouched.")
                }

                $SyncHash.LogQueue.Enqueue("Administrator account setup finished.")
            }
            catch {
                $SyncHash.LogQueue.Enqueue("[ERROR] $($_.Exception.Message)")
            }
        } -OnDone {
            $btnApply.IsEnabled = $true
        }.GetNewClosure()
    }.GetNewClosure())

    $scroll.Content = $mainPanel
    $tab.Content = $scroll
    return $tab
}