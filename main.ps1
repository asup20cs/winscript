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
        Title="WinTool" Height="540" Width="960"
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
 __   __     __    __     ______     __     ______  
/\ "-.\ \   /\ "-./  \   /\  ___\   /\ \   /\__  _\ 
\ \ \-.  \  \ \ \-./\ \  \ \ \____  \ \ \  \/_/\ \/ 
 \ \_\\"\_\  \ \_\ \ \_\  \ \_____\  \ \_\    \ \_\ 
  \/_/ \/_/   \/_/  \/_/   \/_____/   \/_/     \/_/ 
"@

$bannerBrush = New-Object System.Windows.Media.LinearGradientBrush
$bannerBrush.StartPoint = New-Object System.Windows.Point(0,0)
$bannerBrush.EndPoint   = New-Object System.Windows.Point(1,1)
$bannerBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromRgb(0,217,255), 0)))
$bannerBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromRgb(10,132,255), 1)))
$BannerText.Foreground = $bannerBrush

$bannerGlow = New-Object System.Windows.Media.Effects.DropShadowEffect
$bannerGlow.Color = [System.Windows.Media.Color]::FromRgb(10,132,255)
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
    $manifest = Invoke-RestMethod -Uri "$BaseRepoUrl/manifest.json" -UseBasicParsing
    foreach ($mod in $manifest.modules) {
        try {
            Write-Log "Loading module: $($mod.name)"
            $code = Invoke-RestMethod -Uri "$BaseRepoUrl/$($mod.file)" -UseBasicParsing
            Invoke-Expression $code
            $tabItem = & $mod.function
            if ($tabItem) {
                # Modules aren't required to wrap themselves in a ScrollViewer --
                # enforce it here so every tab scrolls if its content overflows
                # the window (e.g. on smaller screens or long checklists).
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

$window.ShowDialog() | Out-Null