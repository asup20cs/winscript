<#
.SYNOPSIS
    Main entry point. Downloaded and executed by bootstrap.ps1 via Invoke-Expression.
    Builds the WPF GUI shell, then pulls tab modules from manifest.json so new
    task categories can be added later without touching this file.
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

if (-not $Global:BaseRepoUrl) {
    # Fallback if someone dot-sources this file directly during dev/testing
    $Global:BaseRepoUrl = "https://raw.githubusercontent.com/YOURUSERNAME/YOURREPO/main"
}

# ---------------------------------------------------------------------------
# Shared state used by every module (background tasks + thread-safe logging)
# ---------------------------------------------------------------------------
$Global:SyncHash = [hashtable]::Synchronized(@{
    LogQueue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
})

function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $stamp = Get-Date -Format "HH:mm:ss"
    $Global:SyncHash.LogQueue.Enqueue("[$stamp][$Level] $Message")
}

# Runs a scriptblock on a background runspace so the GUI never freezes.
# The scriptblock receives $SyncHash as its first argument -- use
# $SyncHash.LogQueue.Enqueue("text") to log from inside it.
function Start-BackgroundTask {
    param(
        [Parameter(Mandatory)][scriptblock]$Work,
        [object[]]$ArgumentList = @(),
        [scriptblock]$OnDone
    )
    $ps = [powershell]::Create()
    $null = $ps.AddScript($Work).AddArgument($Global:SyncHash)
    foreach ($extraArg in $ArgumentList) { $null = $ps.AddArgument($extraArg) }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $ps.Runspace = $rs
    $handle = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        if ($handle.IsCompleted) {
            $timer.Stop()
            try { $null = $ps.EndInvoke($handle) }
            catch { $Global:SyncHash.LogQueue.Enqueue("[ERROR] $($_.Exception.Message)") }
            $rs.Close(); $ps.Dispose()
            if ($OnDone) { & $OnDone }
        }
    }.GetNewClosure())
    $timer.Start()
}

# ---------------------------------------------------------------------------
# Window skeleton (XAML). Tabs are injected at runtime -- see below.
# ---------------------------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinTool" Height="720" Width="1000"
        WindowStartupLocation="CenterScreen"
        Background="#1E1E1E">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#2D2D30"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="Padding" Value="10,5"/>
            <Setter Property="Margin" Value="4"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Margin" Value="4"/>
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Foreground" Value="Black"/>
            <Setter Property="Padding" Value="12,6"/>
        </Style>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="White"/>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="180"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#252526" Padding="12">
            <TextBlock Text="WinTool" FontSize="20" FontWeight="Bold"/>
        </Border>

        <TabControl Grid.Row="1" Name="TabControl" Background="#1E1E1E" Margin="8"/>

        <GroupBox Grid.Row="2" Header="Log" Foreground="White" Margin="8,0,8,8">
            <TextBox Name="LogBox" Background="#101010" Foreground="#C0C0C0"
                     FontFamily="Consolas" FontSize="12" IsReadOnly="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
        </GroupBox>

        <StatusBar Grid.Row="3" Background="#252526">
            <StatusBarItem>
                <TextBlock Name="StatusText" Text="Ready" Foreground="#A0A0A0"/>
            </StatusBarItem>
        </StatusBar>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$TabControl = $window.FindName("TabControl")
$LogBox     = $window.FindName("LogBox")
$StatusText = $window.FindName("StatusText")

# Continuously flush queued log lines to the UI (started once, used by every module)
$logTimer = New-Object System.Windows.Threading.DispatcherTimer
$logTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$logTimer.Add_Tick({
    $flushed = $false
    while ($Global:SyncHash.LogQueue.Count -gt 0) {
        $line = $Global:SyncHash.LogQueue.Dequeue()
        $LogBox.AppendText("$line`r`n")
        $flushed = $true
    }
    if ($flushed) { $LogBox.ScrollToEnd() }
})
$logTimer.Start()

# ---------------------------------------------------------------------------
# Load tab modules from manifest.json. Add new categories by editing the
# manifest in your repo -- no changes to this file needed.
# ---------------------------------------------------------------------------
$StatusText.Text = "Loading modules..."
try {
    $manifest = Invoke-RestMethod -Uri "$BaseRepoUrl/manifest.json" -UseBasicParsing
    foreach ($mod in $manifest.modules) {
        try {
            Write-Log "Loading module: $($mod.name)"
            $code = Invoke-RestMethod -Uri "$BaseRepoUrl/$($mod.file)" -UseBasicParsing
            Invoke-Expression $code
            $tabItem = & $mod.function
            if ($tabItem) { $TabControl.Items.Add($tabItem) | Out-Null }
        }
        catch {
            Write-Log "Failed to load module '$($mod.name)': $($_.Exception.Message)" "Error"
        }
    }
    $StatusText.Text = "Ready"
}
catch {
    Write-Log "Failed to load manifest.json: $($_.Exception.Message)" "Error"
    $StatusText.Text = "Failed to load modules -- check log"
}

$window.ShowDialog() | Out-Null
