<#
.SYNOPSIS
    Main entry point. Downloaded and executed by bootstrap.ps1 via Invoke-Expression.
    Builds the WPF GUI shell, then pulls tab modules from manifest.json so new
    task categories can be added later without touching this file.
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

if (-not $Global:BaseRepoUrl) {
    # Fallback if someone dot-sources this file directly during dev/testing
    $Global:BaseRepoUrl = "https://raw.githubusercontent.com/asup20cs/winscript/main"
}
# ---------------------------------------------------------------------------
# Local-first repo loader.
#   - If $env:WINTOOL_LOCAL_REPO points at a folder that contains manifest.json,
#     use it.
#   - Otherwise, if main.ps1 is being run directly from a folder that contains
#     manifest.json, use that folder.
#   - Otherwise, fall back to downloading from $BaseRepoUrl.
# Set $env:WINTOOL_LOCAL_REPO once and every subsequent run is fully offline.
# ---------------------------------------------------------------------------
if (-not $Global:LocalRepoPath) {
    if ($env:WINTOOL_LOCAL_REPO -and (Test-Path (Join-Path $env:WINTOOL_LOCAL_REPO 'manifest.json'))) {
        $Global:LocalRepoPath = $env:WINTOOL_LOCAL_REPO
    }
    else {
        $candidate = $null
        if ($PSScriptRoot)                    { $candidate = $PSScriptRoot }
        elseif ($MyInvocation.MyCommand.Path) { $candidate = Split-Path -Parent $MyInvocation.MyCommand.Path }
        if ($candidate -and (Test-Path (Join-Path $candidate 'manifest.json'))) {
            $Global:LocalRepoPath = $candidate
        }
        elseif (Test-Path (Join-Path (Get-Location).Path 'manifest.json')) {
            $Global:LocalRepoPath = (Get-Location).Path
        }
    }
    if ($Global:LocalRepoPath) {
        Write-Host "[local] Using repo at $($Global:LocalRepoPath)" -ForegroundColor Cyan
    }
}

# Read a file from the repo: local disk first, network second.
function Global:Get-RepoText {
    param([Parameter(Mandatory)][string]$RelativePath)

    if ($Global:LocalRepoPath) {
        $local = Join-Path $Global:LocalRepoPath $RelativePath
        if (Test-Path $local) {
            return Get-Content -Path $local -Raw -ErrorAction Stop
        }
        Write-Host "[local] '$RelativePath' not found under $($Global:LocalRepoPath); falling back to network." -ForegroundColor Yellow
    }
    if (-not $BaseRepoUrl) { throw "No local copy of '$RelativePath' and no BaseRepoUrl configured." }
     $resp = Invoke-WebRequest -Uri "$BaseRepoUrl/$RelativePath" -UseBasicParsing
    return [string]$resp.Content
}

# Same, but JSON-decoded.
function Global:Get-RepoJson {
    param([Parameter(Mandatory)][string]$RelativePath)
    $text = Get-RepoText -RelativePath $RelativePath
    return ($text | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# Shared state used by every module (background tasks + thread-safe logging)
# ---------------------------------------------------------------------------
$Global:SyncHash = [hashtable]::Synchronized(@{
    LogQueue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
})

function Global:Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $stamp = Get-Date -Format "HH:mm:ss"
    $Global:SyncHash.LogQueue.Enqueue("[$stamp][$Level] $Message")
}

# Runs a scriptblock on a background runspace so the GUI never freezes.
# The scriptblock receives $SyncHash as its first argument -- use
# $SyncHash.LogQueue.Enqueue("text") to log from inside it.
function Global:Start-BackgroundTask {
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
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Tag = [pscustomobject]@{
        Ps     = $ps
        Rs     = $rs
        Handle = $handle
        Queue  = $Global:SyncHash.LogQueue
        OnDone = $OnDone
    }

    $timer.Add_Tick({
        param($timerRef, $timerEventArgs)
        $st = $timerRef.Tag
        if ($null -eq $st)               { $timerRef.Stop(); return }
        if (-not $st.Handle.IsCompleted) { return }

        $timerRef.Stop()
        try   { $null = $st.Ps.EndInvoke($st.Handle) }
        catch { $st.Queue.Enqueue("[ERROR] $($_.Exception.Message)") }

        if ($st.Ps.Streams.Error.Count -gt 0) {
            foreach ($err in $st.Ps.Streams.Error) {
                $st.Queue.Enqueue("[ERROR] $err")
            }
        }

        try { $st.Rs.Close()   } catch {}
        try { $st.Ps.Dispose() } catch {}

        if ($st.OnDone) {
            try { & $st.OnDone }
            catch { $st.Queue.Enqueue("[ERROR] OnDone: $($_.Exception.Message)") }
        }
    })
    $timer.Start()
}

# ---------------------------------------------------------------------------
# Window skeleton (XAML). Tabs are injected at runtime -- see below.
# ---------------------------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinScript" Height="540" Width="960"
        WindowStartupLocation="CenterScreen"
        Background="#1E1E1E">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Background" Value="#2D2D30"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,5"/>
            <Setter Property="Margin" Value="4"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="Bd"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#3E3E42"/>
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#0A84FF"/>
                                <Setter Property="Foreground" Value="White"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#007ACC"/>
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#007ACC"/>
                                <Setter Property="Foreground" Value="White"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Background" Value="#252526"/>
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#2D2D30"/>
                                <Setter Property="Foreground" Value="#6E6E6E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Margin" Value="4"/>
        </Style>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="White"/>
        </Style>

        <Style x:Key="SidebarTabItem" TargetType="TabItem">
            <Setter Property="Foreground" Value="#A0A0A0"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="16,10"/>
            <Setter Property="Margin" Value="0,2"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border Name="Bd" Background="Transparent" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter ContentSource="Header" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#2D2D30"/>
                                <Setter Property="Foreground" Value="White"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#252526"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TabControl">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabControl">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="170"/>
                                <ColumnDefinition Width="8"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Border Grid.Column="0" Background="#181818" CornerRadius="10" BorderBrush="#2D2D30" BorderThickness="1" Padding="8">
                                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                    <TabPanel IsItemsHost="True" Background="Transparent"/>
                                </ScrollViewer>
                            </Border>
                            <Border Grid.Column="2" Background="#181818" CornerRadius="10" BorderBrush="#2D2D30" BorderThickness="1" Padding="16">
                                <ContentPresenter ContentSource="SelectedContent"/>
                            </Border>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#181818" Padding="12,16" BorderBrush="#2D2D30" BorderThickness="0,0,0,1">
            <TextBlock Name="BannerText" FontFamily="Consolas" FontSize="13"
                       HorizontalAlignment="Center" TextAlignment="Center"/>
        </Border>

        <TabControl Grid.Row="1" Name="TabControl" Background="#1E1E1E" Margin="8"
                    ItemContainerStyle="{StaticResource SidebarTabItem}"/>

        <StatusBar Grid.Row="2" Background="#252526">
            <StatusBarItem>
                <TextBlock Name="StatusText" Text="Ready" Foreground="#A0A0A0"/>
            </StatusBarItem>
        </StatusBar>

        <Border Grid.Row="3" Background="#181818" Padding="6" BorderBrush="#2D2D30" BorderThickness="0,1,0,0">
            <TextBlock Text="Made with love by Ashutosh" FontStyle="Italic" FontSize="11"
                       Foreground="#707070" HorizontalAlignment="Center"/>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$TabControl = $window.FindName("TabControl")
$StatusText = $window.FindName("StatusText")
$BannerText = $window.FindName("BannerText")

# Safety net: without this, an unhandled exception anywhere in a button click
# handler (in ANY module/tab) kills the whole Dispatcher message loop and the
# window just disappears -- which looks like "it exits after running a
# module" and forces a full re-download/re-run. This catches it, logs it to
# the console, and keeps the window (and every other tab) alive.
$window.Dispatcher.add_UnhandledException({
    param($senderObj, $e)
    try { $Global:SyncHash.LogQueue.Enqueue("[UI ERROR] $($e.Exception.Message)") } catch {}
    $e.Handled = $true
})

$BannerText.Text = @"
███╗   ██╗███╗   ███╗ ██████╗    ██╗████████╗
████╗  ██║████╗ ████║██╔════╝    ██║╚══██╔══╝
██╔██╗ ██║██╔████╔██║██║         ██║   ██║   
██║╚██╗██║██║╚██╔╝██║██║         ██║   ██║   
██║ ╚████║██║ ╚═╝ ██║╚██████╗    ██║   ██║   
╚═╝  ╚═══╝╚═╝     ╚═╝ ╚═════╝    ╚═╝   ╚═╝   
                                            
"@

$bannerBrush = New-Object System.Windows.Media.LinearGradientBrush
$bannerBrush.StartPoint = New-Object System.Windows.Point(0,0)
$bannerBrush.EndPoint   = New-Object System.Windows.Point(1,1)

# Rainbow Gradient Stops (Red -> Orange -> Yellow -> Green -> Blue -> Indigo -> Violet)
$bannerBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromRgb(255, 0, 0),     0.0)))  # Red
$bannerBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromRgb(255, 127, 0),   0.17))) # Orange
$bannerBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromRgb(255, 255, 0),   0.33))) # Yellow
$bannerBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromRgb(0, 255, 0),     0.5)))  # Green
$bannerBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromRgb(0, 0, 255),     0.67))) # Blue
$bannerBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromRgb(75, 0, 130),    0.83))) # Indigo
$bannerBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromRgb(148, 0, 211),   1.0)))  # Violet

$BannerText.Foreground = $bannerBrush

$bannerGlow = New-Object System.Windows.Media.Effects.DropShadowEffect
$bannerGlow.Color = [System.Windows.Media.Color]::FromRgb(255, 255, 255) # White glow to complement rainbow
$bannerGlow.BlurRadius = 20
$bannerGlow.ShadowDepth = 3
$bannerGlow.Opacity = 0.6
$BannerText.Effect = $bannerGlow


# Continuously flush queued log lines to the console window the one-liner was
# run from, instead of a GUI log box -- frees that space up in the window for
# tab content, and you still get every log line (including from background
# runspace tasks, since they only ever touch $SyncHash.LogQueue, never the GUI).
$logTimer = New-Object System.Windows.Threading.DispatcherTimer
$logTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$logTimer.Add_Tick({
    while ($Global:SyncHash.LogQueue.Count -gt 0) {
        $line = $Global:SyncHash.LogQueue.Dequeue()
        $color = if ($line -match '\[Error\]|\[ERROR\]') { 'Red' }
                 elseif ($line -match '\[Warn\]|\[WARN\]') { 'Yellow' }
                 else { 'Gray' }
        Write-Host $line -ForegroundColor $color
    }
})
$logTimer.Start()

# ---------------------------------------------------------------------------
# Load tab modules from manifest.json. Add new categories by editing the
# manifest in your repo -- no changes to this file needed.
# ---------------------------------------------------------------------------
$StatusText.Text = "Loading modules..."
try {
    $manifest = Get-RepoJson -RelativePath "manifest.json"
    foreach ($mod in $manifest.modules) {
        try {
            Write-Log "Loading module: $($mod.name)"
            $code = Get-RepoText -RelativePath $mod.file
            Invoke-Expression $code
            $tabItem = & $mod.function
            if ($tabItem) {
                if ($tabItem.Content -isnot [System.Windows.Controls.ScrollViewer]) {
                    $originalContent = $tabItem.Content
                    $scrollWrapper = New-Object System.Windows.Controls.ScrollViewer
                    $scrollWrapper.VerticalScrollBarVisibility = 'Auto'
                    $scrollWrapper.HorizontalScrollBarVisibility = 'Disabled'
                    $scrollWrapper.Content = $originalContent
                    $tabItem.Content = $scrollWrapper
                }
                $TabControl.Items.Add($tabItem) | Out-Null
            }
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

try {
    $null = $window.ShowDialog()
}
catch {
    Write-Host ""
    Write-Host "=== GUI exception ===" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}
finally {
    Write-Host ""
    Write-Host "Window closed. Last error (if any):" -ForegroundColor Yellow
    if ($Error.Count -gt 0) { $Error[0] | Format-List * -Force }
    else { Write-Host "  (none)" }
}