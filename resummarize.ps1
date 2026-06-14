# ============================================================
#  Re-summarize: สรุปไฟล์ใหม่จาก transcript ที่มีอยู่
#
#  ใช้งาน:
#    .\resummarize.ps1 "Recording 2026-06-13 215814"
#    .\resummarize.ps1 "Recording 2026-06-13 215814" -Model opus
#    .\resummarize.ps1 "Recording 2026-06-13 215814" -Mode lecture
#    .\resummarize.ps1 "Recording 2026-06-13 215814" -Prompt "สรุปแบบ..."
#    .\resummarize.ps1 "..." -ConfigPath "D:\my-config.json"
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Name,

    [ValidateSet('haiku', 'sonnet', 'opus')]
    [string]$Model,

    [ValidateSet('default', 'lecture', 'meeting')]
    [string]$Mode,

    [string]$Prompt,

    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ===================== Load config =====================
function Resolve-ConfigPath {
    if ($ConfigPath) { return $ConfigPath }
    if ($env:VIDEOSUMMARY_CONFIG) { return $env:VIDEOSUMMARY_CONFIG }
    return Join-Path $PSScriptRoot 'config.json'
}

$cfgFile = Resolve-ConfigPath
if (-not (Test-Path $cfgFile)) {
    Write-Host "ERROR: ไม่พบ config: $cfgFile" -ForegroundColor Red
    exit 1
}
$config = Get-Content $cfgFile -Raw -Encoding utf8 | ConvertFrom-Json

function Get-Cfg {
    param([string]$Path, $Default)
    $parts = $Path -split '\.'
    $cur = $config
    foreach ($p in $parts) {
        if ($null -eq $cur) { return $Default }
        $member = $cur.PSObject.Properties[$p]
        if (-not $member) { return $Default }
        $cur = $member.Value
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

$Base                = [string](Get-Cfg 'base' $null)
$DefaultModel        = [string](Get-Cfg 'claude_model' 'sonnet')
$ChunkThresholdChars = [int](Get-Cfg 'chunk_threshold_chars' 600000)
$ChunkSizeChars      = [int](Get-Cfg 'chunk_size_chars' 200000)
$Outputs = @()
$rawOutputs = Get-Cfg 'outputs' @()
if ($rawOutputs) { $Outputs = @($rawOutputs) }

if (-not $Base) {
    Write-Host "ERROR: config.base ไม่ได้ระบุ" -ForegroundColor Red
    exit 1
}

$TranscriptDir = Join-Path $Base 'transcripts'
$SummaryDir    = Join-Path $Base 'summaries'

# ===================== Prompt templates =====================
$PromptModes = @{}

$PromptModes['default'] = @'
คุณคือผู้ช่วยสรุปเนื้อหา ด้านล่างนี้คือข้อความถอดเสียงจากวิดีโอ/เสียง
กรุณาสรุปเป็นภาษาไทยให้กระชับ ครบถ้วน และอ่านง่าย จัดรูปแบบ Markdown ดังนี้:

## หัวข้อเรื่อง
(ตั้งชื่อเรื่องสั้น ๆ ที่สื่อถึงเนื้อหา — สำคัญมาก ต้องมีบรรทัดนี้)

## ภาพรวม
(สรุปภาพรวม 2-4 ประโยค)

## ประเด็นสำคัญ
(แจกแจงประเด็นหลักเป็นข้อ ๆ แบบ bullet)

## ข้อสรุป / สิ่งที่ต้องทำต่อ
(ถ้ามีข้อสรุปสำคัญหรือ action item ให้ระบุ ถ้าไม่มีให้ข้ามหัวข้อนี้)

## แท็ก
(แท็กหัวข้อ 2-5 อัน คั่นด้วย comma — สำคัญมาก ต้องมีบรรทัดนี้)

ตอบเฉพาะเนื้อหาสรุปเท่านั้น ไม่ต้องมีคำนำหรือคำลงท้าย
'@

$PromptModes['lecture'] = @'
คุณคือผู้ช่วยสรุปเนื้อหาการเรียน ด้านล่างนี้คือข้อความถอดเสียงจากบทเรียน
กรุณาสรุปเป็นภาษาไทยสำหรับใช้ทบทวน จัดรูปแบบ Markdown ดังนี้:

## หัวข้อเรื่อง
(ชื่อบทเรียนสั้น ๆ — สำคัญมาก ต้องมีบรรทัดนี้)

## ภาพรวม
(สรุปสิ่งที่ได้เรียน 2-4 ประโยค)

## ประเด็นสำคัญ
(แจกแจงเนื้อหาหลักเป็นข้อ ๆ พร้อมคำอธิบายสั้น)

## คำศัพท์ / แนวคิดสำคัญ
(คำศัพท์หรือแนวคิดที่ผู้สอนเน้น ระบุพร้อมความหมายสั้น ๆ ถ้าไม่มีให้ข้าม)

## ตัวอย่าง / กรณีศึกษา
(ตัวอย่างที่ผู้สอนยก ถ้าไม่มีให้ข้าม)

## สิ่งที่ควรทบทวนต่อ
(จุดที่ควรกลับมาดูซ้ำหรือฝึกเพิ่ม ถ้าไม่มีให้ข้าม)

## แท็ก
(แท็ก 2-5 อัน คั่นด้วย comma — สำคัญมาก ต้องมีบรรทัดนี้)

ตอบเฉพาะเนื้อหาสรุปเท่านั้น ไม่ต้องมีคำนำหรือคำลงท้าย
'@

$PromptModes['meeting'] = @'
คุณคือผู้ช่วยสรุปการประชุม ด้านล่างนี้คือข้อความถอดเสียงจากการประชุม
กรุณาสรุปเป็นภาษาไทย จัดรูปแบบ Markdown ดังนี้:

## หัวข้อเรื่อง
(ชื่อการประชุมสั้น ๆ — สำคัญมาก ต้องมีบรรทัดนี้)

## วาระและประเด็นที่คุยกัน
(แจกแจงประเด็นที่หารือเป็นข้อ ๆ)

## ข้อตัดสินใจ
(สิ่งที่ตกลงกัน ถ้าไม่มีให้ข้าม)

## Action items
(งานที่ต้องทำต่อ ระบุผู้รับผิดชอบและกำหนดเวลาถ้ามี ถ้าไม่มีให้ข้าม)

## คำถามที่ยังไม่มีคำตอบ
(ประเด็นที่ค้าง รอข้อมูลเพิ่ม ถ้าไม่มีให้ข้าม)

## แท็ก
(แท็ก 2-5 อัน คั่นด้วย comma — สำคัญมาก ต้องมีบรรทัดนี้)

ตอบเฉพาะเนื้อหาสรุปเท่านั้น ไม่ต้องมีคำนำหรือคำลงท้าย
'@

# ----- resolve transcript -----
$basename = $Name -replace '\.(txt|md|mp4|mkv|mov|avi|webm|m4v|flv|wmv|mp3|wav|m4a|aac|flac|ogg|opus|wma)$', ''
$txtPath  = Join-Path $TranscriptDir "$basename.txt"
$mdPath   = Join-Path $TranscriptDir "$basename.transcript.md"
$metaPath = Join-Path $TranscriptDir "$basename.meta.json"

if (-not (Test-Path $txtPath)) {
    Write-Host "ERROR: ไม่พบ transcript: $txtPath" -ForegroundColor Red
    Write-Host ''
    Write-Host 'transcript ที่มีอยู่:'
    Get-ChildItem $TranscriptDir -Filter '*.txt' | Sort-Object LastWriteTime -Descending |
        Select-Object -First 20 | ForEach-Object { Write-Host "  $($_.BaseName)" }
    exit 1
}

$transcript = Get-Content $txtPath -Raw -Encoding utf8
if ([string]::IsNullOrWhiteSpace($transcript)) {
    Write-Host "ERROR: transcript ว่างเปล่า: $txtPath" -ForegroundColor Red
    exit 1
}

# ----- prompt + model -----
$promptTpl =
    if ($Prompt) { $Prompt }
    elseif ($Mode) { $PromptModes[$Mode] }
    else { $PromptModes['default'] }

$modelToUse = if ($Model) { $Model } else { $DefaultModel }

# ----- find Claude CLI -----
$candidates = New-Object System.Collections.Generic.List[string]
$ccRoot = Join-Path $env:APPDATA 'Claude\claude-code'
if (Test-Path $ccRoot) {
    Get-ChildItem $ccRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object { try { [version]$_.Name } catch { [version]'0.0.0' } } -Descending |
        ForEach-Object { $candidates.Add((Join-Path $_.FullName 'claude.exe')) }
}
foreach ($extRoot in @(
        (Join-Path $env:USERPROFILE '.vscode\extensions'),
        (Join-Path $env:USERPROFILE '.vscode-insiders\extensions'),
        (Join-Path $env:USERPROFILE '.cursor\extensions'))) {
    if (Test-Path $extRoot) {
        Get-ChildItem $extRoot -Directory -Filter 'anthropic.claude-code-*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { $candidates.Add((Join-Path $_.FullName 'resources\native-binary\claude.exe')) }
    }
}
$cmd = Get-Command claude -ErrorAction SilentlyContinue
if ($cmd) { $candidates.Add($cmd.Source) }
$ClaudeExe = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $ClaudeExe) {
    Write-Host 'ERROR: ไม่พบ Claude CLI' -ForegroundColor Red
    exit 1
}

# ----- helpers (chunking) -----
function Split-IntoChunks($PlainText, $TranscriptMdPath) {
    $paragraphs = @()
    if ($TranscriptMdPath -and (Test-Path $TranscriptMdPath)) {
        $md = Get-Content $TranscriptMdPath -Raw -Encoding utf8
        $body = $md -replace '(?s)^---.*?---\s*', ''
        $paragraphs = $body -split "(?:`r?`n){2,}" | Where-Object { $_.Trim() }
    } else {
        $paragraphs = $PlainText -split "(?:`r?`n)+" | Where-Object { $_.Trim() }
    }
    $chunks = @()
    $current = New-Object System.Text.StringBuilder
    foreach ($p in $paragraphs) {
        if ($current.Length -gt 0 -and ($current.Length + $p.Length) -gt $ChunkSizeChars) {
            $chunks += $current.ToString()
            $current = New-Object System.Text.StringBuilder
        }
        [void]$current.AppendLine($p)
        [void]$current.AppendLine()
    }
    if ($current.Length -gt 0) { $chunks += $current.ToString() }
    return $chunks
}

function Invoke-ClaudeOnce($p, $m) {
    $out = ($p | & $ClaudeExe -p --model $m) -join "`r`n"
    if ($LASTEXITCODE -ne 0) { throw "Claude ล้มเหลว (exit code $LASTEXITCODE)" }
    if ([string]::IsNullOrWhiteSpace($out)) { throw 'Claude คืนค่าว่างเปล่า' }
    return $out
}

# ----- call Claude -----
Write-Host "transcript: $($transcript.Length) chars (~$([int]($transcript.Length / 4)) tokens)"
Write-Host "model: $modelToUse"

if ($transcript.Length -gt $ChunkThresholdChars) {
    $chunks = Split-IntoChunks $transcript $mdPath
    $n = $chunks.Count
    Write-Host "ใช้ map-reduce: $n chunks"
    $partials = @()
    for ($i = 0; $i -lt $n; $i++) {
        Write-Host ("  chunk {0}/{1}..." -f ($i + 1), $n)
        $chunkPrompt = @"
นี่คือบางส่วนของถอดเสียงวิดีโอ/เสียงยาว (ส่วนที่ $($i + 1) จาก $n)
สรุปเฉพาะเนื้อหาในส่วนนี้เป็นภาษาไทยแบบ bullet points ครบทุกประเด็น
ห้ามใส่หัวข้อ Markdown ห้ามใส่คำนำหรือคำลงท้าย

--- ข้อความถอดเสียง ส่วนที่ $($i + 1) ---
$($chunks[$i])
"@
        $partials += "### ส่วนที่ $($i + 1)`n" + (Invoke-ClaudeOnce $chunkPrompt $modelToUse)
    }
    Write-Host '  รวมเป็นสรุปสุดท้าย...'
    $merged = $partials -join "`n`n"
    $finalPrompt = $promptTpl + @"


--- หมายเหตุ ---
ด้านล่างนี้คือสรุปย่อยจากแต่ละส่วน ให้สังเคราะห์เป็นสรุปเดียวตาม format ข้างบน

--- สรุปย่อยจากแต่ละส่วน ---
$merged
"@
    $summary = Invoke-ClaudeOnce $finalPrompt $modelToUse
} else {
    Write-Host 'ส่งให้ Claude สรุป...'
    $fullPrompt = $promptTpl + "`n`n--- ข้อความถอดเสียง ---`n" + $transcript
    $summary = Invoke-ClaudeOnce $fullPrompt $modelToUse
}

# ----- extract title + tags -----
$title = $null; $tags = @()
if ($summary -match '(?m)^##\s*หัวข้อเรื่อง\s*\r?\n+\s*(.+?)\s*\r?\n') {
    $title = $Matches[1].Trim() -replace '^\*+|\*+$', ''
}
if ($summary -match '(?ms)^##\s*แท็ก\s*\r?\n+(.+?)(\r?\n##|\r?\n*$)') {
    $tagLine = $Matches[1].Trim()
    $rawTags = $tagLine -split '[,\n]' | ForEach-Object { ($_ -replace '^[\s\-\*•#]+', '').Trim() }
    $tags = $rawTags | Where-Object { $_ -and $_.Length -le 40 } | Select-Object -Unique
}
$cleanedBody = ($summary -replace '(?ms)\r?\n*##\s*แท็ก\s*\r?\n.*?(\r?\n##|\s*$)', "`$1").TrimEnd()

# ----- meta -----
$meta = $null
if (Test-Path $metaPath) {
    try { $meta = Get-Content $metaPath -Raw -Encoding utf8 | ConvertFrom-Json } catch { }
}

# ----- frontmatter -----
$source = $basename
if ($meta -and $meta.source) { $source = $meta.source }
$sourceEscaped = $source -replace '"', '\"'
$fmLines = @('---')
$fmLines += "date: $(Get-Date -Format 'yyyy-MM-dd')"
$fmLines += "source: `"$sourceEscaped`""
if ($meta -and $meta.duration_hms) { $fmLines += "duration: `"$($meta.duration_hms)`"" }
if ($meta -and $meta.language)     { $fmLines += "language: $($meta.language)" }
if ($meta -and $meta.model)        { $fmLines += "whisper_model: $($meta.model)" }
$fmLines += "summarizer: $modelToUse"
if ($title) {
    $titleEscaped = $title -replace '"', '\"'
    $fmLines += "aliases: [`"$titleEscaped`"]"
}
$allTags = @('video-summary')
foreach ($t in $tags) {
    $slug = $t -replace '\s+', '-' -replace '[^\p{L}\p{N}\-_/]', ''
    if ($slug -and $slug.Length -gt 1) { $allTags += $slug.ToLower() }
}
$allTags = $allTags | Select-Object -Unique
$fmLines += "tags: [$($allTags -join ', ')]"
$fmLines += '---'
$fmLines += ''
$frontmatter = ($fmLines -join "`r`n") + "`r`n"

$transcriptLink = if (Test-Path $mdPath) { "> 📝 Full transcript: [[$basename.transcript]]`r`n`r`n" } else { '' }
$fullContent = $frontmatter + $transcriptLink + $cleanedBody + "`r`n"

# ----- write local + additional outputs -----
$localPath = Join-Path $SummaryDir "$basename.md"
Set-Content -Path $localPath -Value $fullContent -Encoding utf8
Write-Host "เขียน: $localPath"

foreach ($out in $Outputs) {
    if (-not $out.PSObject.Properties['path']) { continue }
    $outPath = [string]$out.path
    if (-not (Test-Path $outPath)) { continue }
    try {
        $dest = Join-Path $outPath "$basename.md"
        Set-Content -Path $dest -Value $fullContent -Encoding utf8
        Write-Host "เขียน output: $dest"
    } catch {
        Write-Host "WARNING: เขียน output ไม่สำเร็จ ($outPath): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ($title) { Write-Host "title: $title" }
if ($tags) { Write-Host "tags: $($tags -join ', ')" }
Write-Host 'เสร็จเรียบร้อย' -ForegroundColor Green
