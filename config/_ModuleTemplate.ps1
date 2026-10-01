<#
.SYNOPSIS
    TEMPLATE -- copy this file to build a new tab/category.

    Steps to add a new custom task module:
      1. Copy this file to modules/<YourModuleName>.ps1
      2. Rename Get-TemplateTab to something unique, e.g. Get-TweaksTab
      3. Build whatever controls you want inside the TabItem
      4. Add an entry to manifest.json:
           { "name": "Tweaks", "file": "modules/Tweaks.ps1", "function": "Get-TweaksTab" }
      5. Commit + push. No changes to main.ps1 or bootstrap.ps1 are needed --
         it's picked up automatically the next time someone runs the tool.

    Available to you at runtime (defined in main.ps1, already loaded):
      - $BaseRepoUrl              -> your repo's raw base URL
      - Get-RepoText / Get-RepoJson -> reads local file first, then falls back to repo
      - Write-Log "msg" ["Level"] -> quick one-line log from the UI thread
      - Start-BackgroundTask -Work { param($SyncHash, ...) ... } `
            -ArgumentList @(...) -OnDone { ... }
                                  -> run long/blocking work off the UI thread.
                                     Inside -Work, log with:
                                       $SyncHash.LogQueue.Enqueue("text")
                                     -Work runs in its own runspace: it can
                                     only see what you pass in -ArgumentList,
                                     not variables from the GUI's scope.
                                     IMPORTANT: Do NOT call .GetNewClosure() on
                                     the -OnDone scriptblock so it can directly
                                     access UI controls and updateStatusLabel.
#>

function Get-TemplateTab {
    $tab = New-Object System.Windows.Controls.TabItem
    $tab.Header = "Template"

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = 10

    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text = "Replace this with your own controls description."
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
        $statusText.Text = "Current state: READY"
        $statusText.Foreground = 'LightGreen'
    }.GetNewClosure()

    & $updateStatusLabel
    $btnRefresh.Add_Click({ & $updateStatusLabel }.GetNewClosure())

    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = "Run Example Task"
    $btn.HorizontalAlignment = 'Left'
    $btn.Margin = "0,10,0,0"
    $btn.Add_Click({
        $btn.IsEnabled = $false; $btnRefresh.IsEnabled = $false
        Write-Log "Button clicked -- starting example background task."
        Start-BackgroundTask -ArgumentList @("hello") -Work {
            param($SyncHash, $Message)
            Start-Sleep -Seconds 1
            $SyncHash.LogQueue.Enqueue("Background task says: $Message")
        } -OnDone {
            & $updateStatusLabel
            $btn.IsEnabled = $true; $btnRefresh.IsEnabled = $true
        }
    }.GetNewClosure())
    $panel.Children.Add($btn) | Out-Null

    $tab.Content = $panel
    return $tab
}
