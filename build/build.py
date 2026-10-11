# -*- coding: utf-8 -*-
"""由 GeminiPet.ps1(已验证的框架)+ ChatGPT 专属代码块,组装出 ChatGPTPet.ps1。

框架部分(窗口/DPI/拖动/定时器/预览/自检/单实例)保持逐字节不变,
只替换造型、粒子、动作、菜单等角色相关内容,避免重新引入已修好的问题。
"""
import io
import os

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(os.path.dirname(BASE), "GeminiPet", "GeminiPet.ps1")
BUILD = os.path.join(BASE, "build")
DST = os.path.join(BASE, "ChatGPTPet.ps1")


def read(path):
    with io.open(path, "r", encoding="utf-8-sig") as f:
        return f.read()


def block(name):
    return read(os.path.join(BUILD, name + ".txt"))


def splice(s, start, end, new, label):
    i = s.find(start)
    j = s.find(end, i + 1)
    if i < 0 or j < 0:
        raise SystemExit("!! 片段定位失败: %s (start=%d end=%d)" % (label, i, j))
    print("  splice %-12s %6d..%-6d -> %d 字符" % (label, i, j, len(new)))
    return s[:i] + new + s[j:]


def replace_once(s, old, new, label):
    if old not in s:
        raise SystemExit("!! 文本替换失败: %s" % label)
    print("  replace %s" % label)
    return s.replace(old, new)


s = read(SRC)

# ---- 1. 头部注释 ----
s = splice(s, "#Requires -Version 5.1", "[CmdletBinding()]", block("b_header") + "\n", "header")
# ---- 1.5 框架内部命名清理 + 删除不再使用的四角星几何函数 ----
for old, new, lbl in [("GeminiPetNative", "ChatGPTPetNative", "原生互操作类名"),
                      ("GEMINIPET_VERBOSE", "GPTPET_VERBOSE", "调试环境变量")]:
    s = replace_once(s, old, new, lbl)
s = replace_once(s, "# Waist 越小腰身越细, 越大越饱满(Gemini 的星星比较饱满, 约 0.68)",
                 "# (已移除四角星几何, 保留此注释仅为占位)", "说明注释")
s = splice(s, "# 四角星(双子星火花)几何", "$script:BodyR = 78.0", "", "drop-sparkle")
# ---- 2. 几何数据 ----
s = splice(s, "$script:BodyR = 78.0", "# ---------------------------------------------------------------- 界面(XAML)", block("b_geometry"), "geometry")
# ---- 3. XAML ----
i = s.find("$xaml = @'")
j = s.find("\n'@", i)
if i < 0 or j < 0:
    raise SystemExit("!! XAML 片段定位失败")
print("  splice %-12s %6d..%-6d -> %d 字符" % ("xaml", i, j, len(block("b_xaml"))))
s = s[:i] + block("b_xaml") + s[j + 3:]
# ---- 4. 元素引用 ----
s = splice(s, "$PetWrap = N 'PetWrap'", "# ---------------------------------------------------------------- 计时元素", block("b_lookups"), "lookups")
# ---- 5. 花瓣 + 环绕闪光 ----
s = splice(s, "function Initialize-Orbit", "function New-Particle", block("b_orbit"), "blossom")
# ---- 6. 粒子 ----
s = splice(s, "function New-Particle", "# ---------------------------------------------------------------- 表情", block("b_particles"), "particles")
# ---- 7. 行为/动作 ----
s = splice(s, "function Start-Action(", "function Update-Pet(", block("b_actions"), "actions")
# ---- 8. 每帧更新 ----
s = splice(s, "function Update-Pet(", "function Step-Pet(", block("b_update"), "update")
# ---- 9. 预览姿势 ----
s = splice(s, "    $poses = @(", "    foreach ($pose in $poses) {", block("b_poses"), "poses")
# ---- 10. 右键菜单 ----
s = splice(s, "$menu = New-Object System.Windows.Controls.ContextMenu", "$root.ContextMenu = $menu", block("b_menu"), "menu")

# ---- 文本替换 ----
# ---- 载入三只桌宠联动模块(三个仓库各一份 social.ps1; 缺失时自动跳过) ----
# 注意:这段替换跑在"日志改名"之前, 所以这里仍是框架原始名字 GeminiPet.log
s = replace_once(
    s,
    "$script:LogPath = Join-Path $env:TEMP 'GeminiPet.log'",
    "$script:LogPath = Join-Path $env:TEMP 'GeminiPet.log'\n$socialPath = Join-Path $PSScriptRoot 'social.ps1'\nif (Test-Path -LiteralPath $socialPath) { . $socialPath }",
    "联动模块",
)
# 拖动时应当中断任何正在播放的动作(原来只判断名为 wander 的动作,
# 结果拖拽会被 swim/slide 这类"移动类动作"每帧覆盖回去)
s = replace_once(
    s,
    "if ($script:State -eq 'wander') { End-State }",
    "if ($script:State -ne 'idle') { End-State }",
    "拖动中断动作",
)
s = replace_once(
    s,
    "$xaml = $xaml.Replace('{BODY}', $script:BodyData).Replace('{MINI}', $script:MiniData)",
    "$xaml = $xaml.Replace('{BODY}', $script:BodyData)",
    "xaml 占位符",
)
s = replace_once(s, "'GeminiPet.log'", "'ChatGPTPet.log'", "日志名")
s = replace_once(s, "'GeminiDesktopPet.SingleInstance'", "'ChatGPTDesktopPet.SingleInstance'", "互斥体名")
s = replace_once(s, "$win.Title = 'Gemini Pet'", "$win.Title = 'ChatGPT Pet'", "窗口标题")
s = replace_once(
    s,
    "$script:SelfTestList = @('wave', 'hop', 'spin', 'look', 'burst', 'stretch', 'wander', 'pop')",
    "$script:SelfTestList = @('wobble', 'bounce', 'spin', 'look', 'ping', 'stretch', 'slide', 'think')",
    "自检动作表",
)

# ---- 残留检查 ----
leftovers = ["Gemini", "Spawn-Burst", "ArmLRot", "ArmRRot", "$script:MiniData", "$script:OrbitData",
             "{MINI}", "'wave'", "'burst'", "$ArmL", "$ArmR", "New-SparkleData"]
bad = [w for w in leftovers if w in s]
if bad:
    print("  !! 仍有残留引用: %s" % ", ".join(bad))
else:
    print("  残留检查通过")

with io.open(DST, "w", encoding="utf-8-sig", newline="") as f:
    f.write(s)
print("写出 %s (%d 字符, %d 行)" % (DST, len(s), s.count("\n") + 1))
