#Requires -Version 5.1
<#
  ChatGPT 桌面小宠物 / ChatGPT Desktop Pet  ✦
  ---------------------------------------------------------------
  * 纯 Windows 自带组件实现(WPF + PowerShell 5.1),无需安装任何依赖
  * 一只 ChatGPT 六瓣小花(OpenAI 花标造型):花瓣会慢慢转,还会冒出"正在输入…"的三个点
  * 左键拖动移动,右键菜单(打招呼、摸摸头、思考中、冒个泡、大小、挪个地方、退出)
  * 不抢焦点(可在你打字时安静地待在角落)

  用法:
    powershell -NoProfile -ExecutionPolicy Bypass -File ChatGPTPet.ps1
    powershell ... -File ChatGPTPet.ps1 -Size 1.3          # 放大
    powershell ... -File ChatGPTPet.ps1 -Preview out        # 渲染静态预览图(检查外观)
    powershell ... -File ChatGPTPet.ps1 -SelfTest 20        # 自检 20 秒(自动跑一遍所有动作)
#>

[CmdletBinding()]
param(
    [string]$Preview,                 # 渲染预览图的输出目录
    [int]$SelfTest = 0,               # 自检运行秒数
    [switch]$PreviewAlpha,           # 预览图带透明通道(用于做图标)
    [double]$Size = 1.0,              # 宠物大小倍率
    [switch]$ActivateOnClick,         # 点击时允许抢焦点(默认不抢)
    [switch]$AllowMultiple            # 允许开多只
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 程序集
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
try { Add-Type -AssemblyName System.Xaml } catch { }

$script:LogPath = Join-Path $env:TEMP 'ChatGPTPet.log'
function Write-PetLog([string]$msg) {
    try { Add-Content -LiteralPath $script:LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg) -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- 原生调用
try {
    Add-Type -Namespace 'ChatGPTPetNative' -Name 'Win32' -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
'@
} catch { Write-PetLog "Add-Type Win32 失败: $_" }

function Initialize-Dpi {
    try {
        if (-not [ChatGPTPetNative.Win32]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
            [void][ChatGPTPetNative.Win32]::SetProcessDPIAware()
        }
    } catch {
        try { [void][ChatGPTPetNative.Win32]::SetProcessDPIAware() } catch { }
    }
}
function Get-CursorPoint {
    $p = New-Object ChatGPTPetNative.Win32+POINT
    if ([ChatGPTPetNative.Win32]::GetCursorPos([ref]$p)) { return @($p.X, $p.Y) }
    return @(0, 0)
}

# ---------------------------------------------------------------- 小工具
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
function F([double]$v) { $v.ToString('0.###', $script:Inv) }
function Clamp01([double]$v) { if ($v -lt 0) { 0.0 } elseif ($v -gt 1) { 1.0 } else { $v } }
function Ease-InOut([double]$p) { $p = Clamp01 $p; $p * $p * (3 - 2 * $p) }

$script:Rng = New-Object System.Random
function Rand([double]$min, [double]$max) { $min + $script:Rng.NextDouble() * ($max - $min) }

function New-Gs([string]$color, [double]$offset) {
    $g = New-Object System.Windows.Media.GradientStop
    $g.Color = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($color)
    $g.Offset = $offset
    return $g
}
function New-LinBrush([string[]]$colors, [double[]]$offsets, [double]$x1 = 0, [double]$y1 = 0, [double]$x2 = 1, [double]$y2 = 1) {
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = New-Object System.Windows.Point($x1, $y1)
    $b.EndPoint = New-Object System.Windows.Point($x2, $y2)
    for ($i = 0; $i -lt $colors.Count; $i++) { [void]$b.GradientStops.Add((New-Gs $colors[$i] $offsets[$i])) }
    return $b
}
function New-RadBrush([string]$inner, [string]$outer, [double]$gx = 0.5, [double]$gy = 0.5, [double]$rx = 0.5, [double]$ry = 0.5) {
    $b = New-Object System.Windows.Media.RadialGradientBrush
    $b.GradientOrigin = New-Object System.Windows.Point($gx, $gy)
    $b.Center = New-Object System.Windows.Point($gx, $gy)
    $b.RadiusX = $rx
    $b.RadiusY = $ry
    [void]$b.GradientStops.Add((New-Gs $inner 0))
    [void]$b.GradientStops.Add((New-Gs $outer 1))
    return $b
}

# 正 N 边形(可带圆角)路径数据生成器:花心/花瓣都用它,方便调形状
# 注意:PowerShell 里 @(a, b) 中逗号的优先级比 + * 高,元素里带运算必须拆成变量,
#       否则 @($CX + Cos($a)*$R, $CY + ...) 会被解析成 $CX + (Cos($a)*($R,$CY))
function New-RoundPolyData {
    param(
        [double]$R, [int]$N, [double]$Round = 0.4, [double]$Phase = 0,
        [double]$CX = 120, [double]$CY = 122
    )
    $v = @()
    for ($i = 0; $i -lt $N; $i++) {
        $a = 2 * [Math]::PI * $i / $N + $Phase
        $px = $CX + [Math]::Cos($a) * $R
        $py = $CY + [Math]::Sin($a) * $R
        $v += , @($px, $py)
    }
    $k = $Round
    $en = @(); $ex = @()
    for ($i = 0; $i -lt $N; $i++) {
        $vi = $v[$i]
        $pv = $v[($i - 1 + $N) % $N]
        $nv = $v[($i + 1) % $N]
        $en1 = $vi[0] + ($pv[0] - $vi[0]) * $k
        $en2 = $vi[1] + ($pv[1] - $vi[1]) * $k
        $en += , @($en1, $en2)
        $ex1 = $vi[0] + ($nv[0] - $vi[0]) * $k
        $ex2 = $vi[1] + ($nv[1] - $vi[1]) * $k
        $ex += , @($ex1, $ex2)
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('M ' + (F $ex[0][0]) + ',' + (F $ex[0][1]))
    for ($i = 1; $i -lt $N; $i++) {
        [void]$sb.Append(' L ' + (F $en[$i][0]) + ',' + (F $en[$i][1]))
        [void]$sb.Append(' Q ' + (F $v[$i][0]) + ',' + (F $v[$i][1]) + ' ' + (F $ex[$i][0]) + ',' + (F $ex[$i][1]))
    }
    [void]$sb.Append(' L ' + (F $en[0][0]) + ',' + (F $en[0][1]))
    [void]$sb.Append(' Q ' + (F $v[0][0]) + ',' + (F $v[0][1]) + ' ' + (F $ex[0][0]) + ',' + (F $ex[0][1]))
    [void]$sb.Append(' Z')
    return $sb.ToString()
}

$script:CenterX = 120.0
$script:CenterY = 122.0
# 花心:六边形(尖朝上),圆角较大,像一个软软的坐垫
$script:BodyData = New-RoundPolyData -R 50 -N 6 -Round 0.42 -Phase ([Math]::PI / 2)
# 花瓣(6 片):圆角长条,围着花心转一圈
$script:ArmLen = 50.0
$script:ArmThick = 24.0
$script:ArmDist = 51.5
$script:ArmTwist = 12.0
$script:SparkData = 'M 0,-9 C 0,-2 2,0 9,0 C 2,0 0,2 0,9 C 0,2 -2,0 -9,0 C -2,0 0,-2 0,-9 Z'
$script:BubbleData = 'M -11,-8 L 11,-8 A 4,4 0 0 1 15,-4 L 15,4 A 4,4 0 0 1 11,8 L 3,8 L -3,14 L -2,8 L -11,8 A 4,4 0 0 1 -15,4 L -15,-4 A 4,4 0 0 1 -11,-8 Z'
$script:HeartData = 'M 0,9 C -11,2 -10,-7 -4.5,-9 C -1.5,-10 0,-8 0,-6 C 0,-8 1.5,-10 4.5,-9 C 10,-7 11,2 0,9 Z'

# ---------------------------------------------------------------- 界面(XAML)
$xaml = @'
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="Root" Width="240" Height="240" ClipToBounds="False">

  <Canvas x:Name="PetWrap" Width="240" Height="240" Canvas.Left="0" Canvas.Top="0"
          RenderTransformOrigin="0.5,0.5" Cursor="Hand" ClipToBounds="False">
    <Canvas.RenderTransform>
      <TransformGroup>
        <ScaleTransform x:Name="TScale" ScaleX="1" ScaleY="1"/>
        <RotateTransform x:Name="TRot" Angle="0"/>
        <TranslateTransform x:Name="TTrans" X="0" Y="0"/>
      </TransformGroup>
    </Canvas.RenderTransform>
    <!-- 六片花瓣(代码里生成, 会慢慢自转)
         注意:必须放在带 BitmapCache 的 Pet 画布之外! WPF 的位图缓存不会因为
         子元素被代码新增而刷新, 花瓣若加在缓存内部, 整个宠物会渲染成空白 -->
    <Canvas x:Name="BlossomLayer" Width="240" Height="240">
      <Canvas.RenderTransform>
        <TransformGroup>
          <ScaleTransform x:Name="BlossomScale" ScaleX="1" ScaleY="1" CenterX="120" CenterY="122"/>
          <RotateTransform x:Name="BlossomRot" CenterX="120" CenterY="122" Angle="0"/>
        </TransformGroup>
      </Canvas.RenderTransform>
    </Canvas>
    <Canvas x:Name="Pet" Width="240" Height="240">

      <!-- 柔光 -->
      <Ellipse Width="232" Height="232" Canvas.Left="4" Canvas.Top="4" Opacity="0.5" IsHitTestVisible="False">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#595CE0B4" Offset="0.30"/>
            <GradientStop Color="#2E10A37F" Offset="0.68"/>
            <GradientStop Color="#000A7A5E" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
      </Ellipse>


      <!-- 花心(六边形坐垫) -->
      <Path x:Name="Body" Data="{BODY}" IsHitTestVisible="True">
        <Path.Fill>
          <RadialGradientBrush MappingMode="Absolute" Center="120,92" GradientOrigin="120,92" RadiusX="152" RadiusY="152">
            <GradientStop Color="#FF62E3B8" Offset="0"/>
            <GradientStop Color="#FF17A882" Offset="0.45"/>
            <GradientStop Color="#FF0A7A5E" Offset="1"/>
          </RadialGradientBrush>
        </Path.Fill>
        <Path.Effect>
          <DropShadowEffect Color="#7A00543F" BlurRadius="16" ShadowDepth="5" Direction="270" Opacity="0.5"/>
        </Path.Effect>
      </Path>

      <!-- 花心高光 -->
      <Path Data="{BODY}" IsHitTestVisible="False">
        <Path.Fill>
          <RadialGradientBrush GradientOrigin="0.34,0.20" Center="0.34,0.20" RadiusX="0.72" RadiusY="0.62">
            <GradientStop Color="#66FFFFFF" Offset="0"/>
            <GradientStop Color="#00FFFFFF" Offset="1"/>
          </RadialGradientBrush>
        </Path.Fill>
      </Path>

      <!-- 眼睛(睁) -->
      <Canvas x:Name="EyeOpen" Width="240" Height="240" RenderTransformOrigin="0.5,0.5" IsHitTestVisible="False">
        <Canvas.RenderTransform>
          <TransformGroup>
            <ScaleTransform x:Name="EyeScale" ScaleX="1" ScaleY="1"/>
            <TranslateTransform x:Name="EyeLook" X="0" Y="0"/>
          </TransformGroup>
        </Canvas.RenderTransform>
        <Ellipse Width="24" Height="27" Canvas.Left="92" Canvas.Top="100.5">
          <Ellipse.Fill>
            <LinearGradientBrush StartPoint="0.2,0" EndPoint="0.8,1">
              <GradientStop Color="#FF12463A" Offset="0"/>
              <GradientStop Color="#FF06231B" Offset="1"/>
            </LinearGradientBrush>
          </Ellipse.Fill>
        </Ellipse>
        <Ellipse Width="24" Height="27" Canvas.Left="124" Canvas.Top="100.5">
          <Ellipse.Fill>
            <LinearGradientBrush StartPoint="0.2,0" EndPoint="0.8,1">
              <GradientStop Color="#FF12463A" Offset="0"/>
              <GradientStop Color="#FF06231B" Offset="1"/>
            </LinearGradientBrush>
          </Ellipse.Fill>
        </Ellipse>
        <Ellipse Width="9" Height="9" Canvas.Left="96" Canvas.Top="104" Fill="#FFFFFFFF" Opacity="0.95"/>
        <Ellipse Width="9" Height="9" Canvas.Left="128" Canvas.Top="104" Fill="#FFFFFFFF" Opacity="0.95"/>
        <Ellipse Width="4" Height="4" Canvas.Left="110" Canvas.Top="117" Fill="#FFFFFFFF" Opacity="0.6"/>
        <Ellipse Width="4" Height="4" Canvas.Left="142" Canvas.Top="117" Fill="#FFFFFFFF" Opacity="0.6"/>
      </Canvas>

      <!-- 眼睛(笑成弯月) -->
      <Canvas x:Name="EyeHappy" Width="240" Height="240" Visibility="Collapsed" IsHitTestVisible="False">
        <Path Data="M -11,3 Q 0,-9 11,3" Stroke="#FF06231B" StrokeThickness="4"
              StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round">
          <Path.RenderTransform>
            <TranslateTransform X="104" Y="115"/>
          </Path.RenderTransform>
        </Path>
        <Path Data="M -11,3 Q 0,-9 11,3" Stroke="#FF06231B" StrokeThickness="4"
              StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round">
          <Path.RenderTransform>
            <TranslateTransform X="136" Y="115"/>
          </Path.RenderTransform>
        </Path>
      </Canvas>

      <!-- 嘴 -->
      <Canvas x:Name="Mouth" Width="240" Height="240" IsHitTestVisible="False">
        <Path x:Name="MouthSmile" Data="M -9,0 Q 0,9 9,0" Stroke="#FF06231B" StrokeThickness="3.2"
              StrokeStartLineCap="Round" StrokeEndLineCap="Round">
          <Path.RenderTransform>
            <TranslateTransform X="120" Y="138"/>
          </Path.RenderTransform>
        </Path>
        <Path x:Name="MouthFlat" Data="M -7,0 L 7,0" Stroke="#FF06231B" StrokeThickness="3.2"
              StrokeStartLineCap="Round" StrokeEndLineCap="Round" Visibility="Collapsed">
          <Path.RenderTransform>
            <TranslateTransform X="120" Y="139"/>
          </Path.RenderTransform>
        </Path>
        <Ellipse x:Name="MouthOpen" Width="12" Height="14" Canvas.Left="114" Canvas.Top="131" Fill="#FF06231B" Visibility="Collapsed"/>
      </Canvas>

      <!-- 腮红 -->
      <Canvas x:Name="Blush" Width="240" Height="240" Opacity="0" IsHitTestVisible="False">
        <Ellipse Width="24" Height="12" Canvas.Left="73" Canvas.Top="120">
          <Ellipse.Fill>
            <RadialGradientBrush>
              <GradientStop Color="#FFFF8FB4" Offset="0"/>
              <GradientStop Color="#00FF8FB4" Offset="1"/>
            </RadialGradientBrush>
          </Ellipse.Fill>
        </Ellipse>
        <Ellipse Width="24" Height="12" Canvas.Left="143" Canvas.Top="120">
          <Ellipse.Fill>
            <RadialGradientBrush>
              <GradientStop Color="#FFFF8FB4" Offset="0"/>
              <GradientStop Color="#00FF8FB4" Offset="1"/>
            </RadialGradientBrush>
          </Ellipse.Fill>
        </Ellipse>
      </Canvas>

      <!-- "正在输入…" 气泡 -->
      <Canvas x:Name="ThinkBubble" Width="240" Height="240" Visibility="Collapsed" IsHitTestVisible="False">
        <Path Data="M 0,0 L 16,0 L 2,15 Z" Fill="#F2FFFFFF" Opacity="0.95">
          <Path.RenderTransform>
            <TranslateTransform X="140" Y="50"/>
          </Path.RenderTransform>
        </Path>
        <Border Canvas.Left="136" Canvas.Top="16" Width="64" Height="38" CornerRadius="14" Background="#F2FFFFFF">
          <Border.Effect>
            <DropShadowEffect Color="#4D00543F" BlurRadius="10" ShadowDepth="2" Direction="270" Opacity="0.4"/>
          </Border.Effect>
        </Border>
        <Ellipse x:Name="Dot1" Width="9" Height="9" Canvas.Left="147" Canvas.Top="30" Fill="#FF10A37F"/>
        <Ellipse x:Name="Dot2" Width="9" Height="9" Canvas.Left="162" Canvas.Top="30" Fill="#FF10A37F"/>
        <Ellipse x:Name="Dot3" Width="9" Height="9" Canvas.Left="177" Canvas.Top="30" Fill="#FF10A37F"/>
      </Canvas>
    </Canvas>
  </Canvas>

  <Canvas x:Name="OrbitLayer" Width="240" Height="240" IsHitTestVisible="False"/>
  <Canvas x:Name="ParticleLayer" Width="240" Height="240" IsHitTestVisible="False"/>
</Canvas>
'@


$xaml = $xaml.Replace('{BODY}', $script:BodyData)
$root = [System.Windows.Markup.XamlReader]::Parse($xaml)

function N([string]$name) {
    $el = $root.FindName($name)
    if (-not $el) { throw "找不到界面元素: $name" }
    return $el
}
$PetWrap = N 'PetWrap'
$Pet = N 'Pet'
$Pet.CacheMode = New-Object System.Windows.Media.BitmapCache
$Pet.CacheMode.RenderAtScale = 1.0
$Pet.CacheMode.EnableClearType = $false
$TScale = N 'TScale'; $TRot = N 'TRot'; $TTrans = N 'TTrans'
$Body = N 'Body'
$BlossomLayer = N 'BlossomLayer'; $BlossomRot = N 'BlossomRot'; $BlossomScale = N 'BlossomScale'
$EyeOpen = N 'EyeOpen'; $EyeHappy = N 'EyeHappy'; $EyeScale = N 'EyeScale'; $EyeLook = N 'EyeLook'
$Mouth = N 'Mouth'; $MouthSmile = N 'MouthSmile'; $MouthFlat = N 'MouthFlat'; $MouthOpen = N 'MouthOpen'
$Blush = N 'Blush'
$ThinkBubble = N 'ThinkBubble'; $Dot1 = N 'Dot1'; $Dot2 = N 'Dot2'; $Dot3 = N 'Dot3'
$OrbitLayer = N 'OrbitLayer'; $ParticleLayer = N 'ParticleLayer'

# ---------------------------------------------------------------- 计时元素
$script:Orbit = New-Object System.Collections.ArrayList
# 统一的品牌绿渐变(绝对坐标, 让 6 片花瓣共用同一束光)
function New-MarkBrush {
    $b = New-Object System.Windows.Media.RadialGradientBrush
    $b.MappingMode = [System.Windows.Media.BrushMappingMode]::Absolute
    $b.Center = New-Object System.Windows.Point(120, 92)
    $b.GradientOrigin = New-Object System.Windows.Point(120, 92)
    $b.RadiusX = 152; $b.RadiusY = 152
    [void]$b.GradientStops.Add((New-Gs '#FF62E3B8' 0))
    [void]$b.GradientStops.Add((New-Gs '#FF17A882' 0.45))
    [void]$b.GradientStops.Add((New-Gs '#FF0A7A5E' 1))
    return $b
}

# 六片花瓣:围一圈, 每片略扭一点角度, 做出花标那种互相咬合的感觉
function Initialize-Blossom {
    for ($i = 0; $i -lt 6; $i++) {
        $ang = 2 * [Math]::PI * $i / 6
        $r = New-Object System.Windows.Shapes.Rectangle
        $r.Width = $script:ArmLen
        $r.Height = $script:ArmThick
        $r.RadiusX = $script:ArmThick / 2
        $r.RadiusY = $script:ArmThick / 2
        $r.Fill = New-MarkBrush
        $r.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
        $r.RenderTransform = New-Object System.Windows.Media.RotateTransform((90 + $i * 60 + $script:ArmTwist))
        $r.IsHitTestVisible = $false
        [System.Windows.Controls.Canvas]::SetLeft($r, $script:CenterX + [Math]::Cos($ang) * $script:ArmDist - $script:ArmLen / 2)
        [System.Windows.Controls.Canvas]::SetTop($r, $script:CenterY + [Math]::Sin($ang) * $script:ArmDist - $script:ArmThick / 2)
        [void]$BlossomLayer.Children.Add($r)
    }
}
Initialize-Blossom

# 身边飘的三颗小闪光
$script:Orbit = New-Object System.Collections.ArrayList
function Initialize-Orbit {
    $i = 0
    foreach ($phase in @(0.6, 2.7, 4.8)) {
        $p = New-Object System.Windows.Shapes.Path
        $p.Data = [System.Windows.Media.Geometry]::Parse($script:SparkData)
        $p.Fill = New-LinBrush -colors @('#F2FFFFFF', '#FF5CE0B4') -offsets @(0, 1)
        $p.RenderTransformOrigin = New-Object System.Windows.Point(0, 0)
        $rt = New-Object System.Windows.Media.RotateTransform(0)
        $p.RenderTransform = $rt
        $p.IsHitTestVisible = $false
        [void]$OrbitLayer.Children.Add($p)
        [void]$script:Orbit.Add(@{
                El = $p; Rot = $rt; Phase = $phase
                Speed = 0.30 + 0.06 * $i
                Radius = 92.0 + 8.0 * $i
            })
        $i++
    }
}
Initialize-Orbit

$script:Particles = New-Object System.Collections.ArrayList

function New-Particle {
    param(
        [ValidateSet('spark', 'bubble', 'heart', 'z')][string]$Kind,
        [double]$X, [double]$Y, [double]$VX, [double]$VY, [double]$G,
        [double]$Life, [double]$S0, [double]$S1, [double]$Spin
    )
    $el = $null
    $offX = 0.0; $offY = 0.0
    switch ($Kind) {
        'spark' {
            $el = New-Object System.Windows.Shapes.Path
            $el.Data = [System.Windows.Media.Geometry]::Parse($script:SparkData)
            $el.Fill = New-LinBrush -colors @('#FFFFFFFF', '#FF5CE0B4') -offsets @(0, 1)
        }
        'bubble' {
            $el = New-Object System.Windows.Shapes.Path
            $el.Data = [System.Windows.Media.Geometry]::Parse($script:BubbleData)
            $el.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString('#F2FFFFFF'))
            $el.Stroke = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString('#4D10A37F'))
            $el.StrokeThickness = 1.2
            $offX = 0.0; $offY = 0.0
        }
        'heart' {
            $el = New-Object System.Windows.Shapes.Path
            $el.Data = [System.Windows.Media.Geometry]::Parse($script:HeartData)
            $el.Fill = New-LinBrush -colors @('#FFFF9EC2', '#FFE0658C') -offsets @(0, 1)
        }
        'z' {
            $el = New-Object System.Windows.Controls.TextBlock
            $el.Text = 'Z'
            $el.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
            $el.FontWeight = [System.Windows.FontWeights]::Bold
            $el.FontSize = 17
            $el.Foreground = New-LinBrush -colors @('#FFFFFFFF', '#FF5CE0B4') -offsets @(0, 1)
        }
    }
    $el.IsHitTestVisible = $false
    $sc = New-Object System.Windows.Media.ScaleTransform($S0, $S0)
    $rt = New-Object System.Windows.Media.RotateTransform(0)
    $tg = New-Object System.Windows.Media.TransformGroup
    [void]$tg.Children.Add($sc)
    [void]$tg.Children.Add($rt)
    $el.RenderTransformOrigin = New-Object System.Windows.Point(0, 0)
    $el.RenderTransform = $tg
    $el.Opacity = 1.0
    [System.Windows.Controls.Canvas]::SetLeft($el, $X + $offX)
    [System.Windows.Controls.Canvas]::SetTop($el, $Y + $offY)
    [void]$ParticleLayer.Children.Add($el)
    [void]$script:Particles.Add(@{
            El = $el; X = $X; Y = $Y; VX = $VX; VY = $VY; G = $G
            Life = 0.0; MaxLife = $Life; S0 = $S0; S1 = $S1; Spin = $Spin
            Sc = $sc; Rot = $rt; OX = $offX; OY = $offY
        })
}

function Clear-Particles {
    foreach ($p in @($script:Particles)) { [void]$ParticleLayer.Children.Remove($p.El) }
    $script:Particles.Clear()
}

# 闪光四散(冒个泡/被戳时用)
function Spawn-Spark([int]$n) {
    for ($i = 0; $i -lt $n; $i++) {
        $a = $script:Rng.NextDouble() * 2 * [Math]::PI
        $sp = Rand 45 125
        New-Particle -Kind 'spark' -X (120 + [Math]::Cos($a) * 14) -Y (116 + [Math]::Sin($a) * 14) `
            -VX ([Math]::Cos($a) * $sp) -VY ([Math]::Sin($a) * $sp - 28) -G 55 `
            -Life (Rand 0.7 1.15) -S0 (Rand 0.45 0.9) -S1 (Rand 0.1 0.35) -Spin (Rand -200 200)
    }
}

# 冒出来的对话气泡
function Spawn-Bubble([int]$n, [double]$bx = 150, [double]$by = 60) {
    for ($i = 0; $i -lt $n; $i++) {
        New-Particle -Kind 'bubble' -X ($bx + (Rand -14 14)) -Y ($by + (Rand -8 10)) `
            -VX (Rand -20 20) -VY (Rand -60 -34) -G -6 `
            -Life (Rand 0.9 1.5) -S0 (Rand 0.4 0.62) -S1 (Rand 0.85 1.15) -Spin (Rand -30 30)
    }
}

function Spawn-Hearts([int]$n) {
    for ($i = 0; $i -lt $n; $i++) {
        New-Particle -Kind 'heart' -X (120 + (Rand -46 46)) -Y (120 + (Rand -14 14)) `
            -VX (Rand -24 24) -VY (Rand -66 -36) -G -8 `
            -Life (Rand 0.9 1.4) -S0 (Rand 0.3 0.5) -S1 (Rand 0.9 1.25) -Spin (Rand -70 70)
    }
}

function Spawn-Z {
    New-Particle -Kind 'z' -X (Rand 146 162) -Y (Rand 74 88) `
        -VX (Rand 9 20) -VY (Rand -24 -14) -G -2 `
        -Life (Rand 1.6 2.1) -S0 (Rand 0.6 0.8) -S1 (Rand 1.3 1.7) -Spin 0
}

# ---------------------------------------------------------------- 表情
$script:CurExpr = ''
$script:EyeBase = 1.0
function Show-Mouth([string]$which) {
    $MouthSmile.Visibility = if ($which -eq 'smile') { 'Visible' } else { 'Collapsed' }
    $MouthFlat.Visibility = if ($which -eq 'flat') { 'Visible' } else { 'Collapsed' }
    $MouthOpen.Visibility = if ($which -eq 'open') { 'Visible' } else { 'Collapsed' }
}
function Set-Expression([string]$name) {
    if ($script:CurExpr -eq $name) { return }
    $script:CurExpr = $name
    switch ($name) {
        'happy' {
            $EyeOpen.Visibility = 'Collapsed'; $EyeHappy.Visibility = 'Visible'
            Show-Mouth 'smile'; $script:EyeBase = 1.0
        }
        'sleepy' {
            $EyeOpen.Visibility = 'Visible'; $EyeHappy.Visibility = 'Collapsed'
            Show-Mouth 'flat'; $script:EyeBase = 0.07
        }
        'surprised' {
            $EyeOpen.Visibility = 'Visible'; $EyeHappy.Visibility = 'Collapsed'
            Show-Mouth 'open'; $script:EyeBase = 1.2
        }
        default {
            $EyeOpen.Visibility = 'Visible'; $EyeHappy.Visibility = 'Collapsed'
            Show-Mouth 'smile'; $script:EyeBase = 1.0
        }
    }
}

# ---------------------------------------------------------------- 状态
$script:Win = $null
$script:T = 0.0
$script:State = 'idle'
$script:StateT = 0.0
$script:StateDur = 0.0
$script:LastAction = ''
$script:NextAction = 5.0
$script:BlinkT = -1.0
$script:NextBlink = 3.0
$script:PatT = -1.0
$script:ZTimer = 0.0
$script:Sleepy = $false
$script:IdleSince = 0.0
$script:ExprForce = ''
$script:ExprUntil = 0.0
$script:WanderFrom = 0.0
$script:WanderTo = 0.0
$script:WanderDir = 1.0
$script:PatCount = 0
$script:ErrorCount = 0

function Reset-PetState {
    Clear-Particles
    $script:State = 'idle'; $script:StateT = 0.0; $script:StateDur = 0.0
    $script:Sleepy = $false; $script:BlinkT = -1.0; $script:PatT = -1.0
    $script:ExprForce = ''; $script:ExprUntil = 0.0; $script:CurExpr = ''
    $script:EyeBase = 1.0
    $script:IdleSince = $script:T
    $script:NextAction = $script:T + 6.0
}

function End-State {
    $script:State = 'idle'; $script:StateT = 0.0; $script:StateDur = 0.0
    $script:NextAction = $script:T + (Rand 3.5 9.5)
}

function Start-Action([string]$name) {
    $script:State = $name
    $script:StateT = 0.0
    switch ($name) {
        'think' { $script:StateDur = 2.30 }
        'ping' { $script:StateDur = 1.10; Spawn-Spark 9; Spawn-Bubble 2 152 62 }
        'bounce' {
            $script:StateDur = 0.88
            $script:BounceLand = $false
        }
        'spin' { $script:StateDur = 1.05 }
        'wobble' { $script:StateDur = 1.30 }
        'stretch' { $script:StateDur = 1.10 }
        'look' { $script:StateDur = 1.50 }
        'pop' { $script:StateDur = 0.62 }
        'slide' {
            $script:StateDur = 2.40
            $script:WanderFrom = 0.0; $script:WanderTo = 0.0; $script:WanderDir = 1.0
            if ($script:Win) {
                $wa = [System.Windows.SystemParameters]::WorkArea
                $w = $script:Win.Width
                $minX = $wa.Left + 8
                $maxX = $wa.Right - $w - 8
                $cur = $script:Win.Left
                $tgt = $cur
                if ($maxX -gt $minX) {
                    for ($i = 0; $i -lt 12; $i++) {
                        $tgt = Rand $minX $maxX
                        if ([Math]::Abs($tgt - $cur) -gt 150) { break }
                    }
                    if ([Math]::Abs($tgt - $cur) -lt 60) { $tgt = if ($cur -lt ($minX + $maxX) / 2) { $maxX } else { $minX } }
                }
                $script:WanderFrom = $cur
                $script:WanderTo = $tgt
                $script:WanderDir = [Math]::Sign($tgt - $cur)
            }
        }
    }
    Write-PetLog "动作: $name"
}

function Start-RandomAction {
    $pool = @(
        @{ n = 'think'; w = 18 }, @{ n = 'look'; w = 16 }, @{ n = 'wobble'; w = 13 },
        @{ n = 'ping'; w = 14 }, @{ n = 'stretch'; w = 11 }, @{ n = 'slide'; w = 14 },
        @{ n = 'bounce'; w = 12 }, @{ n = 'spin'; w = 10 }
    )
    $pool = @($pool | Where-Object { $_.n -ne $script:LastAction })
    $total = 0.0
    foreach ($it in $pool) { $total += $it.w }
    $r = $script:Rng.NextDouble() * $total
    $acc = 0.0
    foreach ($it in $pool) {
        $acc += $it.w
        if ($r -le $acc) { $script:LastAction = $it.n; Start-Action $it.n; return }
    }
    Start-Action 'wobble'
}

function Enter-Sleep {
    $script:Sleepy = $true
    $script:State = 'idle'; $script:StateT = 0.0; $script:StateDur = 0.0
    $script:ZTimer = 0.0
    Write-PetLog '睡着了'
}
function Wake-Pet {
    if ($script:Sleepy) {
        $script:Sleepy = $false
        $script:ExprForce = 'surprised'; $script:ExprUntil = $script:T + 0.7
        Write-PetLog '醒了'
    }
}

function Invoke-Pat {
    $script:IdleSince = $script:T
    Wake-Pet
    $script:PatCount++
    $script:PatT = 0.0
    $script:ExprForce = 'happy'; $script:ExprUntil = $script:T + 1.1
    Spawn-Hearts 4
    Spawn-Bubble 2 150 62
    $roll = $script:Rng.NextDouble()
    if ($roll -lt 0.30) { Start-Action 'bounce' }
    elseif ($roll -lt 0.50) { Start-Action 'spin' }
    elseif ($roll -lt 0.64) { Start-Action 'ping' }
    else { Start-Action 'pop' }
}

function Update-Pet([double]$dt) {
    $script:T += $dt
    $script:StateT += $dt
    if ($script:PatT -ge 0) { $script:PatT += $dt }

    # 太久没人理 -> 睡觉
    if (-not $script:Sleepy -and $script:State -eq 'idle' -and ($script:T - $script:IdleSince) -gt 75) { Enter-Sleep }

    # 眨眼
    $blink = 1.0
    if (-not $script:Sleepy -and $script:EyeBase -gt 0.5) {
        if ($script:BlinkT -lt 0 -and $script:T -ge $script:NextBlink) { $script:BlinkT = 0.0 }
        if ($script:BlinkT -ge 0) {
            $script:BlinkT += $dt
            $k = $script:BlinkT / 0.16
            if ($k -ge 1) {
                $script:BlinkT = -1.0
                $script:NextBlink = $script:T + (Rand 2.2 6.5)
            } else {
                $blink = 1.0 - 0.93 * [Math]::Sin([Math]::PI * $k)
            }
        }
    }

    # 随机小动作
    if ($script:State -eq 'idle' -and -not $script:Sleepy -and $script:T -ge $script:NextAction) { Start-RandomAction }

    # ---- 待机:浮动 + 花瓣自转 ----
    $bobP = if ($script:Sleepy) { 5.0 } else { 3.5 }
    $bobA = if ($script:Sleepy) { 4.0 } else { 7.0 }
    $oy = [Math]::Sin($script:T * 2 * [Math]::PI / $bobP) * $bobA
    $rot = [Math]::Sin($script:T * 2 * [Math]::PI / 6.3) * 3.0
    $brA = 0.016 * [Math]::Sin($script:T * 2 * [Math]::PI / 2.7)
    $sx = 1.0 + $brA
    $sy = 1.0 - $brA
    $ox = 0.0
    $lookX = 0.0; $lookY = 0.0
    $blushAmt = 0.0
    $armRate = 7.0                       # 花瓣自转速度(度/秒)
    $petalScale = 1.0                  # 花瓣张开程度
    if ($script:Sleepy) { $rot = 0.0; $armRate = 1.2 }

    # ---- 当前动作 ----
    $st = $script:State
    switch ($st) {
        'think' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $armRate = 108.0
            $petalScale = 1.03 + 0.02 * [Math]::Sin($script:T * 4.0)
            $rot += 2.4 * [Math]::Sin(2 * [Math]::PI * $p * 1.5)
            $lookX = -3.0; $lookY = -3.0
            if ($p -ge 1) { End-State }
        }
        'ping' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $k = [Math]::Sin([Math]::PI * $p)
            $s = 1 + 0.16 * $k
            $sx *= $s; $sy *= $s
            $rot += 6 * $k
            if ($p -ge 1) { End-State }
        }
        'bounce' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $oy -= 52 * 4 * $p * (1 - $p)
            $s = [Math]::Sin([Math]::PI * $p)
            $sy = 1 + 0.14 * $s
            $sx = 1 - 0.08 * $s
            $rot += -8 + 16 * $p
            if ($p -gt 0.78) {
                $q = ($p - 0.78) / 0.22
                $sy *= 1 - 0.14 * [Math]::Sin([Math]::PI * $q)
                $sx *= 1 + 0.11 * [Math]::Sin([Math]::PI * $q)
                if (-not $script:BounceLand) { $script:BounceLand = $true; Spawn-Spark 5 }
            }
            if ($p -ge 1) { $script:BounceLand = $false; End-State }
        }
        'spin' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $petalScale = 1 + 0.20 * [Math]::Sin([Math]::PI * $p)
            $s = 1 - 0.06 * [Math]::Sin([Math]::PI * $p)
            $sx *= $s; $sy *= $s
            $rot += 4 * [Math]::Sin(2 * [Math]::PI * $p)
            if ($p -ge 1) { End-State }
        }
        'wobble' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $k = [Math]::Sin(2 * [Math]::PI * $p * 3.0) * (1 - $p)
            $sx *= 1 + 0.09 * $k
            $sy *= 1 - 0.09 * $k
            $rot += 9 * $k
            if ($p -ge 1) { End-State }
        }
        'stretch' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $k = [Math]::Sin([Math]::PI * $p)
            $sx *= 1 + 0.13 * $k
            $sy *= 1 - 0.12 * $k
            if ($p -ge 1) { End-State }
        }
        'look' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $sw = [Math]::Sin(2 * [Math]::PI * $p)
            $rot += 7 * $sw
            $lookX = 7 * $sw
            $lookY = 2 * [Math]::Sin(4 * [Math]::PI * $p)
            if ($p -ge 1) { End-State }
        }
        'pop' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $blushAmt = 0.45 * [Math]::Sin([Math]::PI * $p)
            if ($p -ge 1) { End-State }
        }
        'slide' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $e = Ease-InOut $p
            if ($script:Win) { $script:Win.Left = $script:WanderFrom + ($script:WanderTo - $script:WanderFrom) * $e }
            $rot += 7 * $script:WanderDir * [Math]::Sin([Math]::PI * $p)
            $oy -= 14 * [Math]::Abs([Math]::Sin(2 * [Math]::PI * $p))
            $armRate = 26.0
            if ($p -ge 1) { End-State }
        }
    }

    # 被戳时的一下弹跳
    if ($script:PatT -ge 0) {
        if ($script:PatT -lt 0.40) {
            $pop = 1 + 0.17 * [Math]::Sin([Math]::PI * ($script:PatT / 0.40))
            $sx *= $pop; $sy *= $pop
        } else { $script:PatT = -1.0 }
    }

    # 睡觉时冒 Z
    if ($script:Sleepy) {
        $script:ZTimer += $dt
        if ($script:ZTimer -gt 0.95) { $script:ZTimer = 0.0; Spawn-Z }
    }

    # ---- 表情 ----
    $expr = 'normal'
    if ($script:Sleepy) { $expr = 'sleepy' }
    elseif ($st -eq 'wobble' -or $st -eq 'pop' -or $st -eq 'bounce') { $expr = 'happy' }
    elseif ($st -eq 'ping') { $expr = 'surprised' }
    if ($script:T -lt $script:ExprUntil) { $expr = $script:ExprForce }
    if ($script:T -ge $script:ExprUntil -and $script:ExprForce -ne '') { $script:ExprForce = '' }
    Set-Expression $expr

    # ---- "正在输入…" 气泡 ----
    if ($st -eq 'think') {
        $ThinkBubble.Visibility = 'Visible'
        $cyc = ($script:StateT * 2.6) % 3.6
        $d1 = 0.28; if ($cyc -lt 1.2) { $d1 = 1.0 }
        $d2 = 0.28; if ($cyc -ge 1.2 -and $cyc -lt 2.4) { $d2 = 1.0 }
        $d3 = 0.28; if ($cyc -ge 2.4) { $d3 = 1.0 }
        $Dot1.Opacity = $d1
        $Dot2.Opacity = $d2
        $Dot3.Opacity = $d3
    } elseif ($ThinkBubble.Visibility -ne 'Collapsed') {
        $ThinkBubble.Visibility = 'Collapsed'
    }

    # ---- 花瓣自转(思考时飞快, 转圈时转两整圈) ----
    # 坑(已踩): 这里必须用 $script:State, 不能用本帧早先取到的 $st。
    # End-State 会把 StateT/StateDur 清零, 而那一帧 $st 仍是 'spin',
    # 于是 0/0 = NaN 被写进 RotateTransform.Angle → 花瓣整个不渲染,
    # 且 NaN 会一直累加下去(要等下一次旋转重新赋值才恢复)。
    if ($script:State -eq 'spin' -and $script:StateDur -gt 0) {
        $script:BlossomAngle = 720 * (Ease-InOut (Clamp01 ($script:StateT / $script:StateDur)))
    } else {
        $script:BlossomAngle += $armRate * $dt
    }
    if ([double]::IsNaN($script:BlossomAngle) -or [double]::IsInfinity($script:BlossomAngle)) { $script:BlossomAngle = 0.0 }
    if ([double]::IsNaN($petalScale) -or [double]::IsInfinity($petalScale) -or $petalScale -le 0.05) { $petalScale = 1.0 }
    $script:BlossomAngle = $script:BlossomAngle % 360
    $BlossomRot.Angle = $script:BlossomAngle
    $BlossomScale.ScaleX = $petalScale
    $BlossomScale.ScaleY = $petalScale

    # 兜底: NaN / Infinity 一旦写进变换, 元素就直接不渲染了
    if ([double]::IsNaN($rot) -or [double]::IsInfinity($rot)) { $rot = 0.0 }
    if ([double]::IsNaN($sx) -or [double]::IsInfinity($sx) -or $sx -le 0.01) { $sx = 1.0 }
    if ([double]::IsNaN($sy) -or [double]::IsInfinity($sy) -or $sy -le 0.01) { $sy = 1.0 }
    if ([double]::IsNaN($oy) -or [double]::IsInfinity($oy)) { $oy = 0.0 }
    if ([double]::IsNaN($lookX) -or [double]::IsInfinity($lookX)) { $lookX = 0.0 }
    if ([double]::IsNaN($lookY) -or [double]::IsInfinity($lookY)) { $lookY = 0.0 }

    # ---- 应用到界面 ----
    $TRot.Angle = $rot
    $TScale.ScaleX = $sx
    $TScale.ScaleY = $sy
    $TTrans.X = $ox
    $TTrans.Y = $oy
    $EyeScale.ScaleY = $script:EyeBase * $blink
    $EyeLook.X = $lookX
    $EyeLook.Y = $lookY
    $Blush.Opacity = [Math]::Max(0.0, [Math]::Min(1.0, $blushAmt))

    # ---- 身边的小闪光 ----
    foreach ($o in $script:Orbit) {
        $ang = $script:T * $o.Speed + $o.Phase
        [System.Windows.Controls.Canvas]::SetLeft($o.El, 120 + [Math]::Cos($ang) * $o.Radius)
        [System.Windows.Controls.Canvas]::SetTop($o.El, 122 + [Math]::Sin($ang) * $o.Radius * 0.6)
        $o.El.Opacity = 0.16 + 0.5 * (0.5 + 0.5 * [Math]::Sin($script:T * 1.35 + $o.Phase))
        $o.Rot.Angle = $ang * 57.2958
    }

    # ---- 粒子 ----
    if ($script:Particles.Count -gt 0) {
        for ($i = $script:Particles.Count - 1; $i -ge 0; $i--) {
            $pt = $script:Particles[$i]
            $pt.Life += $dt
            $tt = $pt.Life / $pt.MaxLife
            if ($tt -ge 1) {
                [void]$ParticleLayer.Children.Remove($pt.El)
                $script:Particles.RemoveAt($i)
                continue
            }
            $pt.X += $pt.VX * $dt
            $pt.Y += $pt.VY * $dt
            $pt.VY += $pt.G * $dt
            $pt.VX *= 0.985
            [System.Windows.Controls.Canvas]::SetLeft($pt.El, $pt.X + $pt.OX)
            [System.Windows.Controls.Canvas]::SetTop($pt.El, $pt.Y + $pt.OY)
            $pt.El.Opacity = [Math]::Max(0.0, 1.0 - $tt * $tt)
            $s = $pt.S0 + ($pt.S1 - $pt.S0) * $tt
            $pt.Sc.ScaleX = $s
            $pt.Sc.ScaleY = $s
            $pt.Rot.Angle += $pt.Spin * $dt
        }
    }
}

function Step-Pet([double]$dt) {
    try { Update-Pet $dt }
    catch {
        $script:ErrorCount++
        Write-PetLog "Update 异常: $_ @ $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')"
        if ($env:GPTPET_VERBOSE) { Write-Host "Update 异常: $_ @ $($_.InvocationInfo.PositionMessage)" }
        if ($script:ErrorCount -gt 40) { if ($script:Win) { $script:Win.Close() } }
    }
}

# ---------------------------------------------------------------- 预览模式
function Render-Preview([string]$path) {
    $holder = New-Object System.Windows.Controls.Border
    $holder.Width = 240; $holder.Height = 240
    if (-not $script:PreviewAlpha) {
        $holder.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString('#FFF1F2F8'))
    }
    $holder.Child = $root
    $holder.Measure((New-Object System.Windows.Size(240, 240)))
    $holder.Arrange((New-Object System.Windows.Rect(0, 0, 240, 240)))
    $holder.UpdateLayout()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(240, 240, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($holder)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    [void]$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [System.IO.File]::Create($path)
    try { $enc.Save($fs) } finally { $fs.Close() }
    $holder.Child = $null
}

if ($Preview) {
    Initialize-Dpi
    $script:Rng = New-Object System.Random 20240607
    $script:PreviewAlpha = $PreviewAlpha
    $dir = $Preview
    if (-not [System.IO.Path]::IsPathRooted($dir)) { $dir = Join-Path (Get-Location).Path $dir }
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    Write-Host "预览输出目录: $dir"

    $poses = @(
        @{ n = '01_idle'; step = 0.033; times = 4; act = {} },
        @{ n = '02_blink'; step = 0.033; times = 3; act = { $script:BlinkT = 0.07 } },
        @{ n = '03_think'; step = 0.033; times = 17; act = { Start-Action 'think' } },
        @{ n = '04_ping'; step = 0.033; times = 6; act = { Start-Action 'ping' } },
        @{ n = '05_bounce'; step = 0.033; times = 12; act = { Start-Action 'bounce' } },
        @{ n = '06_spin'; step = 0.033; times = 14; act = { Start-Action 'spin' } },
        @{ n = '07_wobble'; step = 0.033; times = 7; act = { Start-Action 'wobble' } },
        @{ n = '08_pat'; step = 0.033; times = 5; act = { Invoke-Pat } },
        @{ n = '09_sleep'; step = 0.05; times = 44; act = { Enter-Sleep } },
        @{ n = '10_stretch'; step = 0.033; times = 17; act = { Start-Action 'stretch' } },
        @{ n = '11_look'; step = 0.033; times = 22; act = { Start-Action 'look' } },
        @{ n = '12_slide'; step = 0.033; times = 26; act = { Start-Action 'slide' } }
    )
    foreach ($pose in $poses) {
        Reset-PetState
        $script:T = 12.0
        $script:NextBlink = 999
        & $pose.act
        for ($i = 0; $i -lt $pose.times; $i++) { Step-Pet $pose.step }
        $out = Join-Path $dir ($pose.n + '.png')
        Render-Preview $out
        Write-Host ("  已渲染 {0}" -f $pose.n)
    }
    Write-Host '预览完成。'
    exit 0
}

# ---------------------------------------------------------------- 单实例
if (-not $AllowMultiple -and -not $SelfTest) {
    $created = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, 'ChatGPTDesktopPet.SingleInstance', [ref]$created)
    if (-not $created) {
        Write-PetLog '已经有一只小宠物在运行了,本次启动退出。'
        exit 0
    }
}

# ---------------------------------------------------------------- 主窗口
Initialize-Dpi

$win = New-Object System.Windows.Window
$win.Title = 'ChatGPT Pet'
$win.WindowStyle = 'None'
$win.AllowsTransparency = $true
$win.Background = [System.Windows.Media.Brushes]::Transparent
$win.ShowInTaskbar = $false
$win.Topmost = $true
$win.ResizeMode = 'NoResize'
$win.SizeToContent = 'Manual'
$win.WindowStartupLocation = 'Manual'
$win.ShowActivated = $false
$win.UseLayoutRounding = $true
$win.SnapsToDevicePixels = $true
$win.Content = $root
$script:Win = $win

function Set-PetSize([double]$s) {
    $script:SizeFactor = $s
    $root.LayoutTransform = New-Object System.Windows.Media.ScaleTransform($s, $s)
    if ($Pet.CacheMode) { $Pet.CacheMode.RenderAtScale = [Math]::Max(1.0, $s) }
    $win.Width = 240 * $s
    $win.Height = 240 * $s
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($win.Left -lt $wa.Left - 40 -or $win.Left -gt $wa.Right) { $win.Left = $wa.Right - $win.Width - 36 }
    if ($win.Top -lt $wa.Top - 40 -or $win.Top -gt $wa.Bottom) { $win.Top = $wa.Bottom - $win.Height - 8 }
}
$script:SizeFactor = $Size

# 初始位置:右下角
$wa = [System.Windows.SystemParameters]::WorkArea
$win.Width = 240 * $Size
$win.Height = 240 * $Size
$win.Left = $wa.Right - $win.Width - 36
$win.Top = $wa.Bottom - $win.Height - 8
Set-PetSize $Size

# 不抢焦点
if (-not $ActivateOnClick) {
    $win.Add_SourceInitialized({
            try {
                $helper = New-Object System.Windows.Interop.WindowInteropHelper($win)
                $h = $helper.Handle
                $GWLEX = -20
                $ex = [ChatGPTPetNative.Win32]::GetWindowLong($h, $GWLEX)
                $ex = $ex -bor 0x08000000 -bor 0x00000080   # WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
                [void][ChatGPTPetNative.Win32]::SetWindowLong($h, $GWLEX, $ex)
                Write-PetLog '已设置不抢焦点 (WS_EX_NOACTIVATE)'
            } catch { Write-PetLog "设置 NOACTIVATE 失败: $_" }
        })
}

# ---------------------------------------------------------------- 右键菜单
function New-MenuItem([string]$header, [scriptblock]$action) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $header
    $mi.Add_Click($action)
    return $mi
}
$menu = New-Object System.Windows.Controls.ContextMenu
$menu.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
$menu.FontSize = 13
[void]$menu.Items.Add((New-MenuItem '👋  打个招呼' { $script:IdleSince = $script:T; Wake-Pet; Start-Action 'wobble'; $script:ExprForce = 'happy'; $script:ExprUntil = $script:T + 1.6 }))
[void]$menu.Items.Add((New-MenuItem '💗  摸摸头' { Invoke-Pat }))
[void]$menu.Items.Add((New-MenuItem '💭  思考一下' { $script:IdleSince = $script:T; Wake-Pet; Start-Action 'think' }))
[void]$menu.Items.Add((New-MenuItem '💬  冒个泡' { $script:IdleSince = $script:T; Wake-Pet; Start-Action 'ping' }))
[void]$menu.Items.Add((New-MenuItem '😴  去睡觉' { Enter-Sleep }))
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
$miSize = New-Object System.Windows.Controls.MenuItem
$miSize.Header = '大小'
foreach ($opt in @(@('小', 0.7), @('中', 1.0), @('大', 1.4))) {
    $sub = New-MenuItem $opt[0] ([scriptblock]::Create("Set-PetSize $($opt[1])"))
    [void]$miSize.Items.Add($sub)
}
[void]$menu.Items.Add($miSize)
[void]$menu.Items.Add((New-MenuItem '🚀  挪个地方' { $script:IdleSince = $script:T; Start-Action 'slide' }))
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
[void]$menu.Items.Add((New-MenuItem '❌  退出' { $win.Close() }))
$root.ContextMenu = $menu

# ---------------------------------------------------------------- 鼠标交互
$script:Pressed = $false
$script:DragMoved = $false
$script:PressPos = @(0, 0)
$script:WinStart = @(0.0, 0.0)

$root.Add_MouseLeftButtonDown({
        $script:Pressed = $true
        $script:DragMoved = $false
        $script:PressPos = Get-CursorPoint
        $script:WinStart = @($win.Left, $win.Top)
        [void]$root.CaptureMouse()
        $script:IdleSince = $script:T
    })
$root.Add_MouseMove({
        if (-not $script:Pressed) { return }
        $p = Get-CursorPoint
        $dx = $p[0] - $script:PressPos[0]
        $dy = $p[1] - $script:PressPos[1]
        if (-not $script:DragMoved -and ([Math]::Abs($dx) + [Math]::Abs($dy)) -gt 5) {
            $script:DragMoved = $true
            if ($script:State -ne 'idle') { End-State }
        }
        if ($script:DragMoved) {
            # 鼠标坐标是物理像素,窗口坐标是 DIP,需要按 DPI 缩放换算
            $sc = 1.0
            try { $sc = [System.Windows.Media.VisualTreeHelper]::GetDpi($root).DpiScaleX } catch { }
            if ($sc -le 0) { $sc = 1.0 }
            $win.Left = $script:WinStart[0] + $dx / $sc
            $win.Top = $script:WinStart[1] + $dy / $sc
        }
    })
$root.Add_MouseLeftButtonUp({
        [void]$root.ReleaseMouseCapture()
        if ($script:Pressed -and -not $script:DragMoved) { Invoke-Pat }
        $script:Pressed = $false
        $script:IdleSince = $script:T
    })

# ---------------------------------------------------------------- 心跳
$script:Clock = [System.Diagnostics.Stopwatch]::StartNew()
$script:LastTick = 0.0
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(33)
$timer.Add_Tick({
        $now = $script:Clock.Elapsed.TotalSeconds
        $dt = $now - $script:LastTick
        $script:LastTick = $now
        if ($dt -le 0) { $dt = 0.033 }
        if ($dt -gt 0.25) { $dt = 0.25 }
        Step-Pet $dt
    })

# ---------------------------------------------------------------- 启动
$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnMainWindowClose'
$app.MainWindow = $win

$win.Add_Loaded({
        $script:Clock.Restart()
        $script:LastTick = 0.0
        $timer.Start()
        Write-PetLog '宠物已启动'
    })
$win.Add_Closed({
        $timer.Stop()
        Write-PetLog '宠物已退出'
    })

# 自检:按脚本跑一遍所有动作,便于验证不会出错
if ($SelfTest -gt 0) {
    $script:SelfTestLeft = [double]$SelfTest
    $script:SelfTestTick = 0.0
    $script:SelfTestStep = 0
    $script:SelfTestList = @('wobble', 'bounce', 'spin', 'look', 'ping', 'stretch', 'slide', 'think')
    $stTimer = New-Object System.Windows.Threading.DispatcherTimer
    $stTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $stTimer.Add_Tick({
            $script:SelfTestLeft -= 0.1
            $script:SelfTestTick += 0.1
            if ($script:SelfTestTick -ge 1.6) {
                $script:SelfTestTick = 0.0
                $act = $script:SelfTestList[$script:SelfTestStep % $script:SelfTestList.Count]
                $script:SelfTestStep++
                if ($act -eq 'pop') { Invoke-Pat } else { Start-Action $act }
                if ($script:SelfTestStep -eq 3) { Invoke-Pat }
                if ($script:SelfTestStep -eq 6) { Enter-Sleep }
                if ($script:SelfTestStep -eq 7) { Wake-Pet }
                Write-PetLog "自检步骤 $($script:SelfTestStep): $act"
            }
            if ($script:SelfTestLeft -le 0) {
                $stTimer.Stop()
                Write-PetLog "自检结束, 异常次数=$($script:ErrorCount), 粒子残留=$($script:Particles.Count)"
                Write-Host "自检结束: 异常次数=$($script:ErrorCount)"
                $win.Close()
            }
        })
    $win.Add_Loaded({ $stTimer.Start() })
}

$win.Show()
[void]$app.Run()
Write-PetLog '进程结束'
