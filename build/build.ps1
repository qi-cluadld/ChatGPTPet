# =====================================================================
#  由「已验证框架 + 角色代码块」组装出最终程序   —— 开发辅助脚本
#  --------------------------------------------------------------------
#  纯 PowerShell 实现, 不需要 Python。
#  用法:  powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
#  说明:  框架取自 ..\..\GeminiPet\GeminiPet.ps1, 角色代码块取自本目录 b_*.txt;
#         本脚本会自动按所在目录判断是哪个宠物(ChatGPTPet / DeepSeekPet)。
# =====================================================================
$ErrorActionPreference = 'Stop'

$build = $PSScriptRoot
$petDir = Split-Path $build -Parent
$petId = Split-Path $petDir -Leaf
$parent = Split-Path $petDir -Parent
$srcPath = Join-Path (Join-Path $parent 'GeminiPet') 'GeminiPet.ps1'

$configs = @{
    'ChatGPTPet' = @{
        Dst = 'ChatGPTPet.ps1'
        Native = 'ChatGPTPetNative'
        Env = 'GPTPET_VERBOSE'
        Log = 'ChatGPTPet.log'
        Mutex = 'ChatGPTDesktopPet.SingleInstance'
        Title = 'ChatGPT Pet'
        SelfTest = "@('wobble', 'bounce', 'spin', 'look', 'ping', 'stretch', 'slide', 'think')"
        XamlNew = "`$xaml = `$xaml.Replace('{BODY}', `$script:BodyData)"
    }
    'DeepSeekPet' = @{
        Dst = 'DeepSeekPet.ps1'
        Native = 'DeepSeekPetNative'
        Env = 'DSPET_VERBOSE'
        Log = 'DeepSeekPet.log'
        Mutex = 'DeepSeekDesktopPet.SingleInstance'
        Title = 'DeepSeek Pet'
        SelfTest = "@('flap', 'breach', 'roll', 'look', 'spout', 'stretch', 'swim', 'bubbles')"
        XamlNew = "`$xaml = `$xaml.Replace('{BODY}', `$script:BodyData).Replace('{BELLY}', `$script:BellyData).Replace('{TAIL}', `$script:TailData).Replace('{FIN}', `$script:FinData)"
    }
}
$cfg = $configs[$petId]
if (-not $cfg) { Write-Host "本脚本只支持 ChatGPTPet / DeepSeekPet 两个目录(当前: $petId)"; exit 1 }

$encPlain = New-Object System.Text.UTF8Encoding($false)
$encBom = New-Object System.Text.UTF8Encoding($true)

function Read-Text([string]$p) { return [System.IO.File]::ReadAllText($p, $encPlain) }
function Get-Block([string]$name) { return Read-Text (Join-Path $build ($name + '.txt')) }
function Splice([string]$text, [string]$start, [string]$end, [string]$new, [string]$label) {
    $i = $text.IndexOf($start)
    if ($i -lt 0) { throw "片段定位失败: $label (开始标记)" }
    $j = $text.IndexOf($end, $i + 1)
    if ($j -lt 0) { throw "片段定位失败: $label (结束标记)" }
    Write-Host ("  splice {0,-12} {1,6}..{2,-6} -> {3} 字符" -f $label, $i, $j, $new.Length)
    return $text.Substring(0, $i) + $new + $text.Substring($j)
}
function ReplaceOnce([string]$text, [string]$old, [string]$new, [string]$label) {
    if (-not $text.Contains($old)) { throw "文本替换失败: $label" }
    Write-Host "  replace $label"
    return $text.Replace($old, $new)
}

$s = Read-Text $srcPath

# ---- 1. 头部注释 ----
$s = Splice $s '#Requires -Version 5.1' '[CmdletBinding()]' ((Get-Block 'b_header') + "`n") 'header'
# ---- 1.5 框架内部命名清理 + 去掉不再使用的四角星几何 ----
$s = ReplaceOnce $s 'GeminiPetNative' $cfg.Native '原生互操作类名'
$s = ReplaceOnce $s 'GEMINIPET_VERBOSE' $cfg.Env '调试环境变量'
$s = ReplaceOnce $s '# Waist 越小腰身越细, 越大越饱满(Gemini 的星星比较饱满, 约 0.68)' '# (已移除四角星几何, 保留此注释仅为占位)' '说明注释'
$s = Splice $s '# 四角星(双子星火花)几何' '$script:BodyR = 78.0' '' 'drop-sparkle'
# ---- 2. 几何数据 ----
$s = Splice $s '$script:BodyR = 78.0' '# ---------------------------------------------------------------- 界面(XAML)' (Get-Block 'b_geometry') 'geometry'
# ---- 3. XAML(收尾的 '@ 单独处理) ----
$xamlStart = "`$xaml = @'"
$i = $s.IndexOf($xamlStart)
$j = $s.IndexOf("`n'@", $i)
if ($i -lt 0 -or $j -lt 0) { throw 'XAML 片段定位失败' }
$xamlBlock = Get-Block 'b_xaml'
Write-Host ("  splice {0,-12} {1,6}..{2,-6} -> {3} 字符" -f 'xaml', $i, $j, $xamlBlock.Length)
$s = $s.Substring(0, $i) + $xamlBlock + $s.Substring($j + 3)
# ---- 4. 元素引用 ----
$s = Splice $s '$PetWrap = N ''PetWrap''' '# ---------------------------------------------------------------- 计时元素' (Get-Block 'b_lookups') 'lookups'
# ---- 5. 角色专属层(花瓣/尾鳍 + 环绕特效) ----
$s = Splice $s 'function Initialize-Orbit' 'function New-Particle' (Get-Block 'b_orbit') 'orbit'
# ---- 6. 粒子 ----
$s = Splice $s 'function New-Particle' '# ---------------------------------------------------------------- 表情' (Get-Block 'b_particles') 'particles'
# ---- 7. 行为/动作 ----
$s = Splice $s 'function Start-Action(' 'function Update-Pet(' (Get-Block 'b_actions') 'actions'
# ---- 8. 每帧更新 ----
$s = Splice $s 'function Update-Pet(' 'function Step-Pet(' (Get-Block 'b_update') 'update'
# ---- 9. 预览姿势 ----
$s = Splice $s '    $poses = @(' '    foreach ($pose in $poses) {' (Get-Block 'b_poses') 'poses'
# ---- 10. 右键菜单 ----
$s = Splice $s '$menu = New-Object System.Windows.Controls.ContextMenu' '$root.ContextMenu = $menu' (Get-Block 'b_menu') 'menu'

# ---- 文本替换 ----
# 拖动时应当中断任何正在播放的动作(原来只判断名为 wander 的动作,
# 结果拖拽会被 swim/slide 这类"移动类动作"每帧覆盖回去)
$s = ReplaceOnce $s "if (`$script:State -eq 'wander') { End-State }" "if (`$script:State -ne 'idle') { End-State }" '拖动中断动作'
# 注意:这段跑在"日志改名"之前, 所以这里仍是框架原始名字 GeminiPet.log
$socialNew = "`$script:LogPath = Join-Path `$env:TEMP 'GeminiPet.log'`n" +
             "`$socialPath = Join-Path `$PSScriptRoot 'social.ps1'`n" +
             "if (Test-Path -LiteralPath `$socialPath) { . `$socialPath }"
$s = ReplaceOnce $s "`$script:LogPath = Join-Path `$env:TEMP 'GeminiPet.log'" $socialNew '联动模块'
$s = ReplaceOnce $s "`$xaml = `$xaml.Replace('{BODY}', `$script:BodyData).Replace('{MINI}', `$script:MiniData)" $cfg.XamlNew 'xaml 占位符'
$s = ReplaceOnce $s "'GeminiPet.log'" ("'" + $cfg.Log + "'") '日志名'
$s = ReplaceOnce $s "'GeminiDesktopPet.SingleInstance'" ("'" + $cfg.Mutex + "'") '互斥体名'
$s = ReplaceOnce $s "`$win.Title = 'Gemini Pet'" ("`$win.Title = '" + $cfg.Title + "'") '窗口标题'
$s = ReplaceOnce $s "`$script:SelfTestList = @('wave', 'hop', 'spin', 'look', 'burst', 'stretch', 'wander', 'pop')" ("`$script:SelfTestList = " + $cfg.SelfTest) '自检动作表'

# ---- 残留检查 ----
$leftovers = @('Gemini', 'Spawn-Burst', 'ArmLRot', 'ArmRRot', '$script:MiniData', '$script:OrbitData',
    '{MINI}', "'wave'", "'burst'", '$ArmL', '$ArmR', 'New-SparkleData')
$bad = @($leftovers | Where-Object { $s.Contains($_) })
if ($bad.Count -gt 0) { Write-Host ("  !! 仍有残留引用: " + ($bad -join ', ')) }
else { Write-Host '  残留检查通过' }

$dst = Join-Path $petDir $cfg.Dst
[System.IO.File]::WriteAllText($dst, $s, $encBom)
Write-Host ("写出 {0} ({1} 字符, {2} 行)" -f $dst, $s.Length, ($s.Split("`n").Count))
