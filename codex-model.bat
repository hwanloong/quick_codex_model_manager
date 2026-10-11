@echo off
setlocal
set "CM_SELF=%~f0"
set "CM_PAYLOAD=%TEMP%\codex-model-manager.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c = Get-Content -LiteralPath $env:CM_SELF -Encoding UTF8; $i = [Array]::IndexOf($c, '#__CM_PS_PAYLOAD__'); if ($i -lt 0) { Write-Host '[x] payload marker not found'; exit 2 }; Set-Content -LiteralPath $env:CM_PAYLOAD -Value $c[($i+1)..($c.Count-1)] -Encoding UTF8"
if errorlevel 1 (
  echo [x] failed to extract built-in script
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%CM_PAYLOAD%" %*
set "CM_RC=%ERRORLEVEL%"
del "%CM_PAYLOAD%" 2>nul
endlocal & exit /b %CM_RC%
#__CM_PS_PAYLOAD__
# ============================================================
#  Codex 模型管理器  (codex-model.bat 的内置脚本部分)
#  目标：查看 / 接入 / 删除 / 切换 Codex 的模型提供方
# ============================================================
$ErrorActionPreference = 'Stop'
# 故意不覆盖 [Console]::OutputEncoding：让它跟随控制台当前代码页。
# 这样中文在 CP936 的 cmd 里正常显示，在 UTF-8 控制台里也正常。
# 文件读写一律走 .NET 的显式 UTF-8，不受此影响。

$script:CodexHome  = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$script:ConfigPath = Join-Path $script:CodexHome 'config.toml'
$script:ModelsPath = Join-Path $script:CodexHome 'models.json'
$script:BackupDir  = Join-Path $script:CodexHome 'backup-manager'

# ============================================================
#  主流模型预设表
#  Context 必须是真实上下文窗口：写大了会导致自动压缩不触发，
#  跑到一半 API 报错；写小了会过早压缩。不确定就别乱填。
# ============================================================
$script:Presets = @(
    @{
        Id      = 'deepseek'
        Label   = 'DeepSeek 深度求索'
        BaseUrl = 'https://api.deepseek.com/'
        Doc     = 'https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/codex'
        Note    = '官方原生支持 Responses API'
        Models  = @(
            @{ Slug = 'deepseek-flash';  Display = 'DeepSeek-Flash';  Desc = 'DeepSeek-V4.1-Flash，支持图片输入'; Ctx = 1048576; Image = $true;  Levels = @('low','high','max'); Default = 'high' }
            @{ Slug = 'deepseek-v4-pro'; Display = 'DeepSeek-V4-Pro'; Desc = 'DeepSeek-V4-Pro-0813';            Ctx = 1048576; Image = $false; Levels = @('low','high','max'); Default = 'high' }
        )
    }
    @{
        Id      = 'ZAI'
        Label   = '智谱 GLM (Z.AI)'
        BaseUrl = 'https://open.bigmodel.cn/api/v1'
        Doc     = 'https://docs.bigmodel.cn/cn/coding-plan/tool/codex'
        Note    = '官方给出了 Codex 专用 Responses 端点'
        Models  = @(
            @{ Slug = 'glm-5.3';       Display = 'glm-5.3';       Desc = 'Z.ai 旗舰模型，仅文本'; Ctx = 1048576; Image = $false; Levels = @('low','high','max'); Default = 'max' }
            @{ Slug = 'glm-5.3-flash'; Display = 'glm-5.3-flash'; Desc = '原生多模态（图/视频/文件）'; Ctx = 1048576; Image = $true; Levels = @('low','high','max'); Default = 'max' }
            @{ Slug = 'glm-5-turbo';   Display = 'glm-5-turbo';   Desc = 'Agent 优化模型'; Ctx = 204800;  Image = $false; Levels = @();                Default = 'max' }
        )
    }
    @{
        Id      = 'kimi'
        Label   = 'Kimi 月之暗面 (Moonshot)'
        BaseUrl = 'https://api.moonshot.cn/v1'
        Doc     = 'https://platform.kimi.com/docs/guide/codex-kimi'
        Note    = '有官方 Codex 端到端指南；国际站用 https://api.moonshot.ai/v1'
        Models  = @(
            @{ Slug = 'kimi-k3';        Display = 'Kimi-K3';        Desc = 'Kimi K3，1M 上下文，支持图片'; Ctx = 1048576; Image = $true;  Levels = @('low','high','max'); Default = 'high' }
            @{ Slug = 'kimi-k2.7-code'; Display = 'Kimi-K2.7-Code'; Desc = 'Kimi K2.7 代码模型';            Ctx = 262144;  Image = $false; Levels = @('low','high','max'); Default = 'high' }
            @{ Slug = 'kimi-k2.6';      Display = 'Kimi-K2.6';      Desc = 'Kimi K2.6';                     Ctx = 262144;  Image = $false; Levels = @('low','high','max'); Default = 'high' }
        )
    }
    @{
        Id      = 'minimax'
        Label   = 'MiniMax'
        BaseUrl = 'https://api.minimax.io/v1'
        Doc     = 'https://platform.minimax.io/docs/api-reference/responses-create'
        Note    = '官方 Responses 端点；注意其思考模式无法关闭'
        Models  = @(
            @{ Slug = 'MiniMax-M3.1-Flash-Preview'; Display = 'MiniMax-M3.1-Flash'; Desc = 'MiniMax M3.1 Flash 预览版'; Ctx = 1000000; Image = $true; Levels = @('high','max'); Default = 'high' }
            @{ Slug = 'MiniMax-M3';   Display = 'MiniMax-M3';   Desc = 'MiniMax M3';   Ctx = 1000000; Image = $true; Levels = @('high','max'); Default = 'high' }
            @{ Slug = 'MiniMax-M2.7'; Display = 'MiniMax-M2.7'; Desc = 'MiniMax M2.7'; Ctx = 204800;  Image = $true; Levels = @('high','max'); Default = 'high' }
        )
    }
    @{
        Id      = 'dashscope'
        Label   = '阿里云百炼 / 通义千问'
        BaseUrl = 'https://dashscope.aliyuncs.com/compatible-mode/v1'
        Doc     = 'https://www.alibabacloud.com/help/en/model-studio/compatibility-with-openai-responses-api'
        Note    = '官方有 Responses 兼容端点；上下文官方未公布，本工具先用保守值'
        Models  = @(
            @{ Slug = 'qwen3.8-max';   Display = 'Qwen3.8-Max';   Desc = '通义千问 3.8 Max';   Ctx = 0; Image = $true; Levels = @('low','high','max'); Default = 'high' }
            @{ Slug = 'qwen3.8-flash'; Display = 'Qwen3.8-Flash'; Desc = '通义千问 3.8 Flash'; Ctx = 0; Image = $true; Levels = @('low','high','max'); Default = 'high' }
            @{ Slug = 'qwen3.6-plus';  Display = 'Qwen3.6-Plus';  Desc = '通义千问 3.6 Plus';  Ctx = 0; Image = $true; Levels = @('low','high','max'); Default = 'high' }
        )
    }
    @{
        Id      = 'openrouter'
        Label   = 'OpenRouter (聚合网关)'
        BaseUrl = 'https://openrouter.ai/api/v1'
        Doc     = 'https://openrouter.ai/docs/api_reference/responses/overview.md'
        Note    = '模型 ID 自己填，格式 vendor/slug，例如 openai/gpt-5.1'
        Models  = @()
    }
)

# ============================================================
#  基础工具
# ============================================================
function W {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}
function Line { param([string]$C = 'DarkGray') W ('-' * 62) $C }
function Title { param([string]$T) W ''; W ('=' * 62) 'Cyan'; W ("  $T") 'Cyan'; W ('=' * 62) 'Cyan' }

# --- 非交互支持：--yes 时所有提问都取默认值，便于脚本化调用与自动化测试 ---
$script:AssumeYes = $false
$script:SkipTest  = $false
function Ask {
    param([string]$Prompt, [string]$Default = '')
    if ($script:AssumeYes) { return $Default }
    $v = Read-Host $Prompt
    if ($null -eq $v -or $v -eq '') { return $Default }
    return $v
}
function Ask-Confirm {
    param([string]$Prompt)
    if ($script:AssumeYes) { return $true }
    $v = Read-Host $Prompt
    return ($v -match '^[Yy]')
}

function Read-TextRaw {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}
function Write-TextRaw {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}
function Backup-File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    if (-not (Test-Path -LiteralPath $script:BackupDir)) {
        New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $leaf  = Split-Path $Path -Leaf
    $dest  = Join-Path $script:BackupDir ($leaf + ".$stamp.bak")
    # 同一秒内多次备份时避免互相覆盖
    $n = 1
    while (Test-Path -LiteralPath $dest) {
        $dest = Join-Path $script:BackupDir ($leaf + ".$stamp.$n.bak")
        $n++
    }
    Copy-Item -LiteralPath $Path -Destination $dest -Force
    return $dest
}

# ============================================================
#  config.toml 处理
#  核心难点：顶层键必须写在所有 [table] 之前，否则会被归入上一个表而失效
# ============================================================
function Get-ConfigLines {
    $raw = Read-TextRaw $script:ConfigPath
    if ($null -eq $raw) { return @() }
    return ($raw -split "`r`n|`n|`r")
}
function Get-ConfigEol {
    $raw = Read-TextRaw $script:ConfigPath
    if ($null -ne $raw -and $raw.Contains("`r`n")) { return "`r`n" }
    return "`n"
}

# 返回：顶层键值（只扫描第一个 [table] 之前）
function Get-TopLevel {
    $lines = Get-ConfigLines
    $res = @{}
    foreach ($l in $lines) {
        if ($l -match '^\s*\[') { break }
        if ($l -match '^\s*([A-Za-z0-9_\-]+)\s*=\s*(.+?)\s*$') {
            $k = $Matches[1]
            $v = $Matches[2].Trim()
            if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2) }
            elseif ($v.Length -ge 2 -and $v.StartsWith("'") -and $v.EndsWith("'")) { $v = $v.Substring(1, $v.Length - 2) }
            $res[$k] = $v
        }
    }
    return $res
}

# 设置顶层键：先清除头部区域里的同名键，再把新键插到文件最顶端
function Set-TopLevel {
    param([hashtable]$Pairs)

    $lines = Get-ConfigLines
    if ($lines.Count -eq 0) { throw "找不到配置文件：$script:ConfigPath" }

    # 找到第一个 [table] 的位置
    $firstTable = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[') { $firstTable = $i; break }
    }

    $head = @()
    if ($firstTable -gt 0) { $head = $lines[0..($firstTable - 1)] }
    $body = @()
    if ($firstTable -lt $lines.Count) { $body = $lines[$firstTable..($lines.Count - 1)] }

    # 从头部剔除托管键（只删顶层的，绝不动 [table] 里的）
    # 固定托管集：不在 $Pairs 里的会被清掉，行为可预测
    $managed = @('model', 'model_provider', 'model_reasoning_effort', 'model_catalog_json')
    $headKept = @()
    foreach ($l in $head) {
        $drop = $false
        if ($l -match '^\s*([A-Za-z0-9_\-]+)\s*=') {
            if ($managed -contains $Matches[1]) { $drop = $true }
        }
        if (-not $drop) { $headKept += $l }
    }
    # 去掉头部开头的空行
    while ($headKept.Count -gt 0 -and $headKept[0].Trim() -eq '') {
        $headKept = @($headKept[1..($headKept.Count - 1)])
    }

    $new = @()
    foreach ($k in $managed) {
        $v = $Pairs[$k]
        if ($null -eq $v) { continue }
        if ($v -is [int] -or $v -is [long] -or $v -is [bool]) {
            $new += "$k = $($v.ToString().ToLower())"
        } else {
            $new += "$k = `"$v`""
        }
    }

    $out = @()
    $out += $new
    if ($headKept.Count -gt 0) { $out += ''; $out += $headKept }
    if ($body.Count -gt 0) { $out += ''; $out += $body }
    Write-TextRaw $script:ConfigPath ($out -join (Get-ConfigEol))
}

# 列出 [model_providers.*] 区块
function Get-ProviderBlocks {
    $lines = Get-ConfigLines
    $blocks = @()
    $cur = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[(.+?)\]\s*$') {
            $hdr = $Matches[1].Trim()
            if ($null -ne $cur) { $cur.End = $i - 1; $blocks += $cur }
            $cur = @{ Header = $hdr; Start = $i; End = $lines.Count - 1 }
        }
    }
    if ($null -ne $cur) { $blocks += $cur }

    $res = @()
    foreach ($b in $blocks) {
        if ($b.Header -match '^model_providers\.([A-Za-z0-9_\-]+)$') {
            $id = $Matches[1]
            # 扩展到它的子表（如 [model_providers.x.env]）
            $end = $b.End
            foreach ($b2 in $blocks) {
                if ($b2.Start -le $b.Start) { continue }
                if ($b2.Header -match ('^model_providers\.' + [regex]::Escape($id) + '\.')) { $end = [Math]::Max($end, $b2.End) }
            }
            $res += @{ Id = $id; Start = $b.Start; End = $end }
        }
    }
    return $res
}

function Get-ProviderSettings {
    param([string]$Id)
    $lines = Get-ConfigLines
    $blk = Get-ProviderBlocks | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    $res = @{ Id = $Id; BaseUrl = ''; WireApi = ''; HasToken = $false; KeyEnv = '' }
    if ($null -eq $blk) { return $res }
    for ($i = $blk.Start; $i -le $blk.End; $i++) {
        if ($lines[$i] -match '^\s*base_url\s*=\s*["''](.+?)["'']') { $res.BaseUrl = $Matches[1] }
        if ($lines[$i] -match '^\s*wire_api\s*=\s*["''](.+?)["'']') { $res.WireApi = $Matches[1] }
        if ($lines[$i] -match '^\s*experimental_bearer_token\s*=\s*["''](.+?)["'']') { $res.HasToken = $true }
        if ($lines[$i] -match '^\s*env_key\s*=\s*["''](.+?)["'']') { $res.KeyEnv = $Matches[1] }
    }
    return $res
}

function Set-ProviderBlock {
    param([string]$Id, [string]$BaseUrl, [string]$KeyMode, [string]$Key)

    $lines = Get-ConfigLines
    $blk   = Get-ProviderBlocks | Where-Object { $_.Id -eq $Id } | Select-Object -First 1

    $repl = @()
    $repl += "[model_providers.$Id]"
    $repl += "name = `"$Id`""
    $repl += "base_url = `"$BaseUrl`""
    $repl += 'wire_api = "responses"'
    if ($KeyMode -eq 'inline') { $repl += "experimental_bearer_token = `"$Key`"" }
    else                       { $repl += "env_key = `"$Key`"" }

    if ($null -ne $blk) {
        $out = @()
        if ($blk.Start -gt 0) { $out += $lines[0..($blk.Start - 1)] }
        $out += $repl
        if ($blk.End -lt $lines.Count - 1) { $out += $lines[($blk.End + 1)..($lines.Count - 1)] }
        Write-TextRaw $script:ConfigPath ($out -join (Get-ConfigEol))
        return 'updated'
    } else {
        $out = @($lines)
        if ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -ne '') { $out += '' }
        $out += $repl
        Write-TextRaw $script:ConfigPath ($out -join (Get-ConfigEol))
        return 'added'
    }
}

function Remove-ProviderBlock {
    param([string]$Id)
    $lines = Get-ConfigLines
    $blk   = Get-ProviderBlocks | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($null -eq $blk) { return $false }

    $start = $blk.Start
    # 连同紧邻上方的注释块一起删掉
    while ($start -gt 0 -and $lines[$start - 1].TrimStart().StartsWith('#')) { $start-- }
    while ($start -gt 0 -and $lines[$start - 1].Trim() -eq '') { $start-- }

    $out = @()
    if ($start -gt 0) { $out += $lines[0..($start - 1)] }
    if ($blk.End -lt $lines.Count - 1) { $out += $lines[($blk.End + 1)..($lines.Count - 1)] }
    Write-TextRaw $script:ConfigPath ($out -join (Get-ConfigEol))
    return $true
}

# ============================================================
#  models.json 处理（用文本级增删，保证不破坏其它条目）
# ============================================================
function Get-CatalogParts {
    $raw = Read-TextRaw $script:ModelsPath
    if ($null -eq $raw) { throw "找不到模型目录：$script:ModelsPath" }

    $m = [regex]::Match($raw, '"models"\s*:\s*\[')
    if (-not $m.Success) { throw "models.json 格式异常：找不到 models 数组" }
    $arrOpen = $m.Index + $m.Length - 1

    $objs = New-Object System.Collections.ArrayList
    $depth = 0; $inStr = $false; $esc = $false; $objStart = -1; $arrClose = -1
    for ($i = $arrOpen + 1; $i -lt $raw.Length; $i++) {
        $ch = $raw[$i]
        if ($inStr) {
            if ($esc) { $esc = $false }
            elseif ($ch -eq [char]92) { $esc = $true }
            elseif ($ch -eq [char]34) { $inStr = $false }
            continue
        }
        if ($ch -eq [char]34) { $inStr = $true }
        elseif ($ch -eq [char]123) { if ($depth -eq 0) { $objStart = $i }; $depth++ }
        elseif ($ch -eq [char]125) { $depth--; if ($depth -eq 0 -and $objStart -ge 0) { [void]$objs.Add($raw.Substring($objStart, $i - $objStart + 1)); $objStart = -1 } }
        elseif ($ch -eq [char]93 -and $depth -eq 0) { $arrClose = $i; break }
    }
    if ($arrClose -lt 0) { throw "models.json 格式异常：models 数组没有闭合" }

    return @{
        Raw     = $raw
        ArrOpen = $arrOpen
        ArrClose = $arrClose
        Prefix  = $raw.Substring(0, $arrOpen + 1)
        Suffix  = $raw.Substring($arrClose)
        Objects = $objs
    }
}

function Get-SlugOf {
    param([string]$ObjText)
    $m = [regex]::Match($ObjText, '"slug"\s*:\s*"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
function Get-CatalogSlugs {
    $p = Get-CatalogParts
    $res = @()
    foreach ($o in $p.Objects) {
        $s = Get-SlugOf $o
        if ($s -ne '') { $res += $s }
    }
    return $res
}
function Save-CatalogObjects {
    param($Parts, $Objects)
    $eol = "`n"
    if ($Parts.Raw.Contains("`r`n")) { $eol = "`r`n" }
    $inner = ($Objects -join (',' + $eol + '    '))
    Write-TextRaw $script:ModelsPath ($Parts.Prefix + $eol + '    ' + $inner + $eol + '  ' + $Parts.Suffix)
}

function New-CatalogEntry {
    param($Spec)
    $levels = @()
    if ($Spec.Levels -and $Spec.Levels.Count -gt 0) {
        $parts = @()
        foreach ($lv in $Spec.Levels) {
            $d = switch ($lv) { 'low' { 'Light reasoning' } 'high' { 'Enhanced reasoning' } 'max' { 'Deep reasoning' } default { $lv } }
            $parts += "        { `"effort`": `"$lv`", `"description`": `"$d`" }"
        }
        $levels = @('      "supported_reasoning_levels": [') + ($parts -join ",`n") + @('      ],')
    } else {
        $levels = @('      "supported_reasoning_levels": [],')
    }
    $mods = if ($Spec.Image) { '["text", "image"]' } else { '["text"]' }

    $l = @()
    $l += '    {'
    $l += "      `"slug`": `"$($Spec.Slug)`","
    $l += "      `"display_name`": `"$($Spec.Display)`","
    $l += "      `"description`": `"$($Spec.Desc)`","
    $l += "      `"default_reasoning_level`": `"$($Spec.Default)`","
    $l += $levels
    $l += '      "shell_type": "shell_command",'
    $l += '      "visibility": "list",'
    $l += '      "supported_in_api": true,'
    $l += '      "priority": 5,'
    $l += '      "base_instructions": "",'
    $l += '      "supports_reasoning_summaries": true,'
    $l += '      "default_reasoning_summary": "none",'
    $l += '      "support_verbosity": false,'
    $l += '      "apply_patch_tool_type": "freeform",'
    $l += '      "truncation_policy": {'
    $l += '        "mode": "bytes",'
    $l += '        "limit": 10000'
    $l += '      },'
    $l += "      `"context_window`": $($Spec.Ctx),"
    $l += "      `"max_context_window`": $($Spec.Ctx),"
    $l += '      "effective_context_window_percent": 95,'
    $l += '      "supports_parallel_tool_calls": true,'
    $l += '      "experimental_supported_tools": [],'
    $l += "      `"input_modalities`": $mods"
    $l += '    }'
    return ($l -join "`n")
}

function Add-CatalogEntries {
    param($Specs)
    $p = Get-CatalogParts
    $existing = @()
    foreach ($o in $p.Objects) { $existing += (Get-SlugOf $o) }
    $objs = @($p.Objects)
    $added = @(); $skipped = @()
    foreach ($s in $Specs) {
        if ($existing -contains $s.Slug) { $skipped += $s.Slug; continue }
        $objs += (New-CatalogEntry $s)
        $added += $s.Slug
    }
    if ($added.Count -gt 0) { Save-CatalogObjects $p $objs }
    return @{ Added = $added; Skipped = $skipped }
}

function Remove-CatalogEntries {
    param([string[]]$Slugs)
    $p = Get-CatalogParts
    $keep = @(); $removed = @()
    foreach ($o in $p.Objects) {
        $sl = Get-SlugOf $o
        if ($Slugs -contains $sl) { $removed += $sl } else { $keep += $o }
    }
    if ($removed.Count -gt 0) { Save-CatalogObjects $p $keep }
    return $removed
}

# ============================================================
#  展示
# ============================================================
function Get-CatalogDisplay {
    try {
        $p = Get-CatalogParts
        $res = @{}
        foreach ($o in $p.Objects) {
            $sl = Get-SlugOf $o
            if ($sl -eq '') { continue }
            $dn = ([regex]::Match($o, '"display_name"\s*:\s*"([^"]*)"')).Groups[1].Value
            $cx = ([regex]::Match($o, '"context_window"\s*:\s*(\d+)')).Groups[1].Value
            $res[$sl] = @{ Display = $dn; Ctx = $cx }
        }
        return $res
    } catch { return @{} }
}

function Show-Status {
    Title 'Codex 模型管理器 —— 当前状态'

    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        W "  [x] 找不到配置文件：$script:ConfigPath" 'Red'
        W "      请先运行一次 Codex，让它生成配置。" 'Yellow'
        return
    }

    $top = Get-TopLevel
    $curModel = if ($top.ContainsKey('model')) { $top['model'] } else { '(未设置)' }
    $curProv  = if ($top.ContainsKey('model_provider')) { $top['model_provider'] } else { 'openai(默认)' }

    W ''
    W ("  配置文件 : " + $script:ConfigPath) 'DarkGray'
    W ("  生效模型 : " + $curModel) 'Green'
    W ("  提供方   : " + $curProv) 'Green'
    if ($top.ContainsKey('model_reasoning_effort')) { W ("  推理强度 : " + $top['model_reasoning_effort']) 'Green' }

    $cat = Get-CatalogDisplay
    $blocks = Get-ProviderBlocks

    W ''
    Line
    W '  已接入的模型提供方' 'White'
    Line

    if ($blocks.Count -eq 0) {
        W '  (没有自定义提供方，当前使用内置 openai)' 'Yellow'
    } else {
        $n = 0
        foreach ($b in $blocks) {
            $n++
            $st = Get-ProviderSettings $b.Id
            $mark = ''
            if ($b.Id -eq $curProv) { $mark = '  <= 当前使用' }
            $wireWarn = ''
            if ($st.WireApi -ne 'responses') { $wireWarn = '  [!] wire_api 不是 responses，新版 Codex 会启动失败' }
            W ("  [$n] " + $b.Id + $mark) $(if ($b.Id -eq $curProv) { 'Green' } else { 'White' })
            W ("      base_url : " + $st.BaseUrl) 'DarkGray'
            if ($st.HasToken)      { W "      API Key  : 已写入配置 (experimental_bearer_token)" 'DarkGray' }
            elseif ($st.KeyEnv)    { W ("      API Key  : 读环境变量 " + $st.KeyEnv) 'DarkGray' }
            else                   { W "      API Key  : [!] 未配置" 'Yellow' }
            if ($wireWarn -ne '') { W $wireWarn 'Yellow' }

            # 找出属于该提供方的模型（按同 id 的预设推断）
            $preset = $script:Presets | Where-Object { $_.Id -eq $b.Id } | Select-Object -First 1
            if ($null -ne $preset) {
                foreach ($m in $preset.Models) {
                    $d = if ($cat.ContainsKey($m.Slug)) { $cat[$m.Slug] } else { $null }
                    if ($null -eq $d) {
                        W ("      - " + $m.Slug + "   [!] 模型目录里没有它，选择器会显示 Custom") 'Yellow'
                    } else {
                        $ctxTxt = if ($d.Ctx) { ([int]$d.Ctx).ToString('N0') + ' tokens' } else { '?' }
                        $imgTxt = if ($m.Image) { '  [支持图片]' } else { '' }
                        W ("      - " + $m.Slug.PadRight(20) + $ctxTxt + $imgTxt) 'Gray'
                    }
                }
            }
        }
    }

    W ''
    Line
    W ("  模型目录 : $script:ModelsPath") 'DarkGray'
    if ($cat.Count -gt 0) {
        $slugList = @($cat.Keys)
        W ("  目录内共 " + $slugList.Count + " 个模型: " + ($slugList -join ', ')) 'DarkGray'
    } else {
        W '  [!] 模型目录为空或不存在' 'Yellow'
    }
    W ''
}

# ============================================================
#  连通性测试
# ============================================================
function Test-Endpoint {
    param([string]$BaseUrl, [string]$Key, [string]$Model)
    $uri = $BaseUrl.TrimEnd('/') + '/responses'
    $hdr = @{ 'Authorization' = "Bearer $Key"; 'Content-Type' = 'application/json' }
    $body = '{"model":"' + $Model + '","input":"ping","max_output_tokens":16}'
    try {
        $r = Invoke-RestMethod -Uri $uri -Headers $hdr -Method Post -Body $body -TimeoutSec 45
        $raw = $r | ConvertTo-Json -Depth 4 -Compress
        if ($raw -match '"code"\s*:\s*(\d+)' -and $raw -notmatch '"output"') {
            $code = $Matches[1]
            $msg  = ([regex]::Match($raw, '"msg"\s*:\s*"([^"]*)"')).Groups[1].Value
            return @{ Ok = $false; Msg = "接口返回错误 code=$code $msg" }
        }
        if ($raw -match '"error"') {
            $msg = ([regex]::Match($raw, '"message"\s*:\s*"([^"]*)"')).Groups[1].Value
            return @{ Ok = $false; Msg = "接口返回 error: $msg" }
        }
        return @{ Ok = $true; Msg = "连通正常" }
    } catch {
        $detail = ''
        try { $detail = $_.ErrorDetails.Message } catch { }
        if (-not $detail) { $detail = $_.Exception.Message }
        return @{ Ok = $false; Msg = ($detail -replace '\s+', ' ') }
    }
}

# ============================================================
#  操作：接入
# ============================================================
function Invoke-Add {
    param([string]$PresetId, [string]$KeyIn = '')

    Title '接入新模型'

    $preset = $null
    if ($PresetId) {
        $preset = $script:Presets | Where-Object { $_.Id -eq $PresetId } | Select-Object -First 1
        if ($null -eq $preset) {
            W "  [x] 没有这个预设：$PresetId" 'Red'
            W "      可选：" (Get-PresetIds) 'DarkGray'
            return
        }
    } else {
        W ''
        W '  请选择要接入的模型提供方：' 'White'
        W ''
        $i = 0
        foreach ($p in $script:Presets) {
            $i++
            W ("    [$i] " + $p.Label) 'White'
            W ("        " + $p.BaseUrl) 'DarkGray'
            if ($p.Note) { W ("        " + $p.Note) 'DarkGray' }
            W ("        模型: " + (($p.Models | ForEach-Object { $_.Slug }) -join ', ')) 'DarkGray'
        }
        W ("    [" + ($i + 1) + "] 自定义 (自己填 base_url 和模型名)") 'White'
        W ''
        $sel = Ask '  请输入编号' '1'
        $n = 0
        if (-not [int]::TryParse($sel, [ref]$n)) { W '  [x] 输入无效' 'Red'; return }
        if ($n -eq $i + 1) { Invoke-AddCustom; return }
        if ($n -lt 1 -or $n -gt $i) { W '  [x] 编号超出范围' 'Red'; return }
        $preset = $script:Presets[$n - 1]
    }

    $id      = $preset.Id
    $baseUrl = $preset.BaseUrl
    $models  = $preset.Models

    # 网关型提供方（预设里没有固定模型）：让用户自己填模型 ID
    if (@($models).Count -eq 0) {
        W ''
        W '  这是聚合网关，需要你自己填模型 ID。' 'White'
        $slug = Ask '  模型 ID (如 openai/gpt-5.1)' ''
        if (-not $slug) { W '  [x] 模型 ID 不能为空' 'Red'; return }
        $disp = Ask ("  显示名 [" + $slug + "]") $slug
        $ctxIn = Ask '  上下文窗口 tokens [131072]' '131072'
        $ctxV = 131072
        [void][int64]::TryParse($ctxIn, [ref]$ctxV)
        $imgV = Ask-Confirm '  支持图片输入？(y/N)'
        $models = @(@{ Slug = $slug; Display = $disp; Desc = $disp; Ctx = $ctxV; Image = $imgV; Levels = @('low','high','max'); Default = 'high' })
    }

    # 上下文窗口未知(Ctx=0)时用保守值。
    # 写大了会让自动压缩不触发、跑到一半 API 报错；写小了只是压缩得早一点。
    $unknownCtx = @()
    $resolved = @()
    foreach ($m in $models) {
        $c = $m.Ctx
        if ($null -eq $c -or [int64]$c -le 0) { $c = 131072; $unknownCtx += $m.Slug }
        $resolved += @{ Slug = $m.Slug; Display = $m.Display; Desc = $m.Desc; Ctx = $c; Image = $m.Image; Levels = $m.Levels; Default = $m.Default }
    }
    $models = $resolved
    if ($unknownCtx.Count -gt 0) {
        W ''
        W ("  [!] 官方没公布这些模型的上下文窗口: " + ($unknownCtx -join ', ')) 'Yellow'
        W '      先用保守值 131072（宁可早压缩，也不能写大导致压缩失效）。' 'Yellow'
        W '      若确认实际更大，改 ~/.codex/models.json 里的 context_window 即可。' 'Yellow'
    }

    W ''
    W ("  已选: " + $preset.Label) 'Cyan'
    W ("  端点: " + $baseUrl) 'DarkGray'
    W ("  模型: " + (($models | ForEach-Object { $_.Slug }) -join ', ')) 'DarkGray'
    W ''

    # ---- API Key ----
    $key = $KeyIn
    if (-not $key) {
        W '  API Key 处理方式：' 'White'
        W '    [1] 直接写入 config.toml (experimental_bearer_token)  —— 最简单' 'Gray'
        W '    [2] 从环境变量读取 (env_key)                          —— 更安全' 'Gray'
        $km = Ask '  选择 [1]' '1'
        if ($km -eq '2') {
            $envName = Ask ("  环境变量名 [" + $id.ToUpper() + "_API_KEY]") ($id.ToUpper() + '_API_KEY')
            $keyMode = 'env'
            $key     = $envName
        } else {
            $key = Ask '  请粘贴 API Key (sk- 开头，留空则跳过)' ''
            if (-not $key) { $keyMode = 'env'; $key = $id.ToUpper() + '_API_KEY' }
            else            { $keyMode = 'inline' }
        }
    } else {
        $keyMode = 'inline'
    }

    if (-not (Ask-Confirm '  确认写入配置？(y/N)')) { W '  已取消' 'Yellow'; return }

    # ---- 写 config.toml ----
    $bk = Backup-File $script:ConfigPath
    if ($bk) { W ("  已备份 -> " + $bk) 'DarkGray' }

    $r = Set-ProviderBlock -Id $id -BaseUrl $baseUrl -KeyMode $keyMode -Key $key
    W ("  [ok] 提供方 [$id] 已" + $(if ($r -eq 'added') { '新增' } else { '更新' })) 'Green'

    # ---- 写 models.json ----
    $mk = Backup-File $script:ModelsPath
    if ($mk) { W ("  已备份 -> " + $mk) 'DarkGray' }
    $cr = Add-CatalogEntries $models
    if ($cr.Added.Count -gt 0)   { W ("  [ok] 模型目录新增: " + ($cr.Added -join ', ')) 'Green' }
    if ($cr.Skipped.Count -gt 0) { W ("  [--] 已存在，保留原有元数据: " + ($cr.Skipped -join ', ')) 'DarkGray' }

    # ---- 设为当前 ----
    $first = $models[0]
    Set-TopLevel @{ model = $first.Slug; model_provider = $id; model_catalog_json = $script:ModelsPath.Replace('\','/'); model_reasoning_effort = $first.Default }
    W ("  [ok] 当前模型已设为 " + $first.Slug) 'Green'

    # ---- 测试 ----
    if ($script:SkipTest) {
        W '  [--] 已跳过连通性测试'
        W ''
        W '  改动要生效需要重启 Codex 应用（菜单里有）。' 'Yellow'
        return
    }
    $testKey = $key
    if ($keyMode -eq 'env') { $testKey = [Environment]::GetEnvironmentVariable($key, 'User') }
    if ($testKey) {
        W ''
        W '  正在测试连通性...' 'DarkGray'
        $t = Test-Endpoint -BaseUrl $baseUrl -Key $testKey -Model $first.Slug
        if ($t.Ok) { W ("  [ok] " + $t.Msg) 'Green' }
        else       { W ("  [!] 测试失败: " + $t.Msg) 'Yellow'; W '      配置已写入，但接口没通，请检查 Key / 端点 / 网络' 'Yellow' }
    } else {
        W '  [--] 没有可用的 Key，跳过连通性测试' 'DarkGray'
    }

    W ''
    W '  改动要生效需要重启 Codex 应用（菜单里有）。' 'Yellow'
}

function Invoke-AddCustom {
    Title '自定义提供方'
    $id = Ask '  提供方 ID (字母数字，如 myapi)' ''
    if (-not $id -or $id -notmatch '^[A-Za-z0-9_\-]+$') { W '  [x] ID 不合法' 'Red'; return }
    $baseUrl = Ask '  base_url (Codex 会拼成 <base_url>/responses)' ''
    if (-not $baseUrl) { W '  [x] 不能为空' 'Red'; return }
    $slug = Ask '  模型 ID (用于 model = "...")' ''
    if (-not $slug) { W '  [x] 不能为空' 'Red'; return }
    $disp = Ask ("  显示名 [" + $slug + "]") $slug
    $ctxIn = Ask '  上下文窗口 tokens [131072]' '131072'
    $ctx = 131072
    if ($ctxIn) { [void][int64]::TryParse($ctxIn, [ref]$ctx) }
    $img = Ask-Confirm '  支持图片输入？(y/N)'

    $spec = @{ Slug = $slug; Display = $disp; Desc = $disp; Ctx = $ctx; Image = $img; Levels = @('low','high','max'); Default = 'high' }
    $script:Presets += @{ Id = $id; Label = $id; BaseUrl = $baseUrl; Note = '用户自定义'; Models = @($spec) }
    Invoke-Add -PresetId $id
}

function Get-PresetIds { return (($script:Presets | ForEach-Object { $_.Id }) -join ', ') }

# ============================================================
#  操作：删除
# ============================================================
function Invoke-Remove {
    param([string]$ProviderId)

    Title '删除已接入的提供方'
    $blocks = Get-ProviderBlocks
    if ($blocks.Count -eq 0) { W '  当前没有接入任何自定义提供方。' 'Yellow'; return }

    $target = $null
    if ($ProviderId) {
        $target = $blocks | Where-Object { $_.Id -eq $ProviderId } | Select-Object -First 1
        if ($null -eq $target) { W ("  [x] 没有接入这个提供方：" + $ProviderId) 'Red'; return }
    } else {
        $top = Get-TopLevel
        $i = 0
        foreach ($b in $blocks) {
            $i++
            $st = Get-ProviderSettings $b.Id
            $mark = if ($b.Id -eq $top['model_provider']) { '  <= 当前使用' } else { '' }
            W ("    [$i] " + $b.Id + $mark) 'White'
            W ("        " + $st.BaseUrl) 'DarkGray'
        }
        W ''
        $sel = Ask '  请输入要删除的编号' '1'
        $n = 0
        if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $i) { W '  [x] 输入无效' 'Red'; return }
        $target = $blocks[$n - 1]
    }

    $id = $target.Id
    $top = Get-TopLevel

    W ''
    W ("  将要删除提供方: " + $id) 'Yellow'
    if ($id -eq $top['model_provider']) {
        W '  [!] 它正是当前使用的提供方，删除后会把当前模型切回内置 openai' 'Yellow'
    }

    # 推断该提供方关联的模型
    $preset = $script:Presets | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    $slugs = @()
    if ($null -ne $preset) { $slugs = @($preset.Models | ForEach-Object { $_.Slug }) }
    $catSlugs = Get-CatalogSlugs
    $slugs = @($slugs | Where-Object { $catSlugs -contains $_ })

    $delCat = $false
    if ($slugs.Count -gt 0) {
        W ("  关联模型: " + ($slugs -join ', ')) 'DarkGray'
        if (Ask-Confirm '  是否同时从模型目录 models.json 删除这些模型？(y/N)') { $delCat = $true }
    }

    if (-not (Ask-Confirm '  确认删除？(y/N)')) { W '  已取消' 'Yellow'; return }

    $bk = Backup-File $script:ConfigPath
    if ($bk) { W ("  已备份 -> " + $bk) 'DarkGray' }

    [void](Remove-ProviderBlock $id)
    W ("  [ok] 已从 config.toml 删除 [" + $id + "]") 'Green'

    if ($delCat) {
        $bk2 = Backup-File $script:ModelsPath
        if ($bk2) { W ("  已备份 -> " + $bk2) 'DarkGray' }
        $rm = Remove-CatalogEntries $slugs
        if ($rm.Count -gt 0) { W ("  [ok] 已从模型目录删除: " + ($rm -join ', ')) 'Green' }
    }

    if ($id -eq $top['model_provider']) {
        Set-TopLevel @{ model_provider = 'openai' }
        W '  [ok] 已把 model_provider 切回内置 openai，并清掉 model 让它用默认模型' 'Green'
    }

    W ''
    W '  改动要生效需要重启 Codex 应用（菜单里有）。' 'Yellow'
}

# ============================================================
#  操作：切换
# ============================================================
function Invoke-Use {
    param([string]$ProviderId, [string]$ModelSlug)

    Title '切换当前使用的模型'
    $cat = Get-CatalogDisplay
    if ($cat.Count -eq 0) { W '  模型目录为空，请先接入模型。' 'Yellow'; return }

    $top = Get-TopLevel
    $curProv = $top['model_provider']

    # 汇总可选项：预设 + 目录
    $cand = @()
    foreach ($p in $script:Presets) {
        foreach ($m in $p.Models) {
            if ($cat.ContainsKey($m.Slug)) {
                $cand += @{ Prov = $p.Id; Slug = $m.Slug; Display = $cat[$m.Slug].Display; Ctx = $cat[$m.Slug].Ctx; Default = $m.Default }
            }
        }
    }
    # 目录里其它没被预设覆盖的
    foreach ($k in $cat.Keys) {
        if (-not ($cand | Where-Object { $_.Slug -eq $k })) {
            $cand += @{ Prov = '(未知)'; Slug = $k; Display = $cat[$k].Display; Ctx = $cat[$k].Ctx; Default = 'high' }
        }
    }

    if ($ModelSlug) {
        $hit = $cand | Where-Object { $_.Slug -eq $ModelSlug } | Select-Object -First 1
        if ($null -eq $hit) { W ("  [x] 目录里没有模型：" + $ModelSlug) 'Red'; return }
        $pick = $hit
    } else {
        W ''
        $i = 0
        foreach ($c in $cand) {
            $i++
            $mark = if ($c.Slug -eq $top['model']) { '  <= 当前' } else { '' }
            W ("    [$i] " + $c.Slug.PadRight(20) + $c.Display + $mark) 'White'
        }
        W ''
        $sel = Ask '  请输入编号' '1'
        $n = 0
        if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $i) { W '  [x] 输入无效' 'Red'; return }
        $pick = $cand[$n - 1]
    }

    if ($pick.Prov -eq '(未知)') {
        W ''
        W ("  [!] 模型 " + $pick.Slug + " 不在预设表里，无法确定它属于哪个提供方。") 'Yellow'
        W '      请在配置里手动设置 model_provider。' 'Yellow'
        return
    }

    $pairs = @{ model = $pick.Slug; model_provider = $pick.Prov; model_catalog_json = $script:ModelsPath.Replace('\','/') }
    if ($pick.Default) { $pairs['model_reasoning_effort'] = $pick.Default }
    Set-TopLevel $pairs
    W ''
    W ("  [ok] 已切换: " + $pick.Prov + " / " + $pick.Slug) 'Green'
    W '  改动要生效需要重启 Codex 应用（菜单里有）。' 'Yellow'
}

# ============================================================
#  操作：重启 Codex
# ============================================================
function Invoke-Restart {
    Title '重启 Codex 应用'

    $pkg = Get-AppxPackage -Name '*Codex*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $pkg) {
        W '  [!] 没找到已安装的 Codex 桌面应用。' 'Yellow'
        W '      如果你用的是 Codex CLI，改动在新开终端时就已生效，无需重启。' 'DarkGray'
        return
    }
    $aumid = $pkg.PackageFamilyName + '!App'

    $procs = @(Get-Process ChatGPT, codex -ErrorAction SilentlyContinue)
    W ("  当前进程数: " + $procs.Count) 'DarkGray'
    if (-not (Ask-Confirm '  确认重启？会关闭当前所有 Codex 窗口 (y/N)')) { W '  已取消' 'Yellow'; return }

    if ($procs.Count -gt 0) {
        $procs | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object { [void]$_.CloseMainWindow() }
        Start-Sleep -Seconds 5
        Get-Process ChatGPT -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Get-Process codex   -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        W '  [ok] 已关闭' 'Green'
    }

    Start-Process 'explorer.exe' -ArgumentList ('shell:appsFolder\' + $aumid)
    W '  [ok] 已重新启动，请等待 10 秒左右让它加载新配置' 'Green'
}

# ============================================================
#  交互菜单
# ============================================================
function Show-Menu {
    if ($script:AssumeYes) { Show-Status; return }
    while ($true) {
        Show-Status
        W ''
        W '  操作：' 'White'
        W '    [1] 刷新状态' 'Gray'
        W '    [2] 接入新模型（主流预设 / 自定义）' 'Gray'
        W '    [3] 删除已接入的提供方' 'Gray'
        W '    [4] 切换当前使用的模型' 'Gray'
        W '    [5] 重启 Codex 应用（让改动生效）' 'Gray'
        W '    [0] 退出' 'Gray'
        W ''
        $c = Read-Host '  请选择'
        switch ($c) {
            '1' { continue }
            '2' { Invoke-Add }
            '3' { Invoke-Remove }
            '4' { Invoke-Use }
            '5' { Invoke-Restart }
            '0' { return }
            default { W '  无效选择' 'Red' }
        }
        W ''
        Read-Host '  按回车继续' | Out-Null
    }
}

# ============================================================
#  命令行入口
# ============================================================
function Show-Help {
    Title 'Codex 模型管理器'
    W '  用法：' 'White'
    W '    codex-model.bat                 打开交互菜单' 'Gray'
    W '    codex-model.bat list            查看当前接入了哪些模型' 'Gray'
    W '    codex-model.bat add [预设ID]    接入模型（不带ID则列出预设菜单）' 'Gray'
    W '    codex-model.bat rm <提供方ID>   删除提供方' 'Gray'
    W '    codex-model.bat use <模型ID>    切换当前模型' 'Gray'
    W '    codex-model.bat restart         重启 Codex 应用' 'Gray'
    W ''
    W ("  预设ID: " + (Get-PresetIds)) 'DarkGray'
    W ''
    W '  已确认不支持 Responses API（新版 Codex 无法接入）：' 'White'
    W '    硅基流动 SiliconFlow —— 只有 chat/completions，官方无 /responses' 'DarkGray'
    W ''
    W '  官方有 Responses 端点但参数本轮未核实，请用「自定义」接入：' 'White'
    W '    腾讯混元/TokenHub   https://tokenhub-intl.tencentcloudmaas.com (是否带 /v1 待实测)' 'DarkGray'
    W '    火山方舟/豆包       base_url 官方页面未抓到' 'DarkGray'
    W '    百度千帆            base_url 官方页面未抓到' 'DarkGray'
    W '    xAI Grok            https://api.x.ai/v1 (上下文未核实)' 'DarkGray'
    W ("  配置文件: " + $script:ConfigPath) 'DarkGray'
    W ("  模型目录: " + $script:ModelsPath) 'DarkGray'
    W ("  备份目录: " + $script:BackupDir) 'DarkGray'
}

$rest = @()
foreach ($a in @($args)) {
    if ($a -eq '--yes' -or $a -eq '-y') { $script:AssumeYes = $true; continue }
    if ($a -eq '--no-test')             { $script:SkipTest  = $true; continue }
    $rest += [string]$a
}
$cmd = ''
if ($rest.Count -gt 0) { $cmd = [string]$rest[0] }

switch ($cmd.ToLower()) {
    ''          { Show-Menu }
    'menu'      { Show-Menu }
    'list'      { Show-Status }
    'ls'        { Show-Status }
    'status'    { Show-Status }
    'add'       {
        if ($rest.Count -gt 1) {
            $k = ''
            if ($rest.Count -gt 2) { $k = $rest[2] }
            Invoke-Add -PresetId ([string]$rest[1]) -KeyIn $k
        } else { Invoke-Add }
    }
    'rm'        { if ($rest.Count -gt 1) { Invoke-Remove -ProviderId ([string]$rest[1]) } else { Invoke-Remove } }
    'remove'    { if ($rest.Count -gt 1) { Invoke-Remove -ProviderId ([string]$rest[1]) } else { Invoke-Remove } }
    'use'       { if ($rest.Count -gt 1) { Invoke-Use -ModelSlug ([string]$rest[1]) } else { Invoke-Use } }
    'restart'   { Invoke-Restart }
    'help'      { Show-Help }
    '-h'        { Show-Help }
    '--help'    { Show-Help }
    default     { W ("未知命令: " + $cmd) 'Red'; Show-Help }
}
