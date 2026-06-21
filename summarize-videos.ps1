# ============================================================
#  ระบบสรุปวิดีโอ/เสียงอัตโนมัติ
#  ขั้นตอน: ถอดเสียง (faster-whisper) -> สรุปภาษาไทย (Claude) -> ไฟล์ .md
#
#  Config:
#    -ConfigPath <path>           ผ่าน parameter (สูงสุด)
#    $env:VIDEOSUMMARY_CONFIG     ผ่าน environment variable
#    <script_dir>\config.json     ค่า default (ถ้าไม่ระบุข้างต้น)
# ============================================================

[CmdletBinding()]
param([string]$ConfigPath)

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
    Write-Host "  วิธีแก้: ก๊อป config.example.json -> config.json แล้วแก้ค่าให้ตรงระบบของคุณ" -ForegroundColor Yellow
    exit 1
}

$config = Get-Content $cfgFile -Raw -Encoding utf8 | ConvertFrom-Json

# helper: เข้าถึง config value แบบ dot-path พร้อม default
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

# ===================== Map config -> vars =====================
$Base              = Get-Cfg 'base' $null
if (-not $Base) {
    Write-Host "ERROR: config.base ไม่ได้ระบุ" -ForegroundColor Red
    exit 1
}

$PythonExe         = Get-Cfg 'python_exe' 'python'
$ClaudeModel       = Get-Cfg 'claude_model' 'sonnet'
$FileInUseGraceSec = [int](Get-Cfg 'file_in_use_grace_sec' 60)
$EnableToast       = [bool](Get-Cfg 'enable_toast' $true)

$EnableBusyCheck   = [bool](Get-Cfg 'busy_check.enable' $true)
$MaxGpuUtilPercent = [int](Get-Cfg 'busy_check.max_gpu_util_percent' 40)
$MaxGpuMemUsedMB   = [int](Get-Cfg 'busy_check.max_gpu_mem_mb' 4096)
$MaxCpuPercent     = [int](Get-Cfg 'busy_check.max_cpu_percent' 70)

$DoneRetentionDays = [int](Get-Cfg 'retention.done_days' 60)
$LogRetentionDays  = [int](Get-Cfg 'retention.logs_days' 30)
$MaxFailedAttempts = [int](Get-Cfg 'retry.max_failed_attempts' 3)

$EnableModelTier   = [bool](Get-Cfg 'enable_model_tier' $true)
$ModelTierShortSec = [int](Get-Cfg 'model_tier.short_sec' 300)
$ModelTierLongSec  = [int](Get-Cfg 'model_tier.long_sec' 3600)
$ModelShort        = [string](Get-Cfg 'model_tier.short' 'haiku')
$ModelMedium       = [string](Get-Cfg 'model_tier.medium' 'sonnet')
$ModelLong         = [string](Get-Cfg 'model_tier.long' 'opus')

$LlmBackend        = [string](Get-Cfg 'llm_backend' 'claude')
$GeminiApiKey      = [string](Get-Cfg 'gemini_api_key' '')
$GeminiModel       = [string](Get-Cfg 'gemini_model' 'gemini-2.5-flash')
$OpenAIApiKey      = [string](Get-Cfg 'openai_api_key' '')
$OpenAIModel       = [string](Get-Cfg 'openai_model' 'gpt-4o-mini')
$OpenAIBaseUrl     = [string](Get-Cfg 'openai_base_url' 'https://api.openai.com/v1')

$ChunkThresholdChars = [int](Get-Cfg 'chunk_threshold_chars' 600000)
$ChunkSizeChars      = [int](Get-Cfg 'chunk_size_chars' 200000)

# Outputs (array of destinations beyond local summaries\)
$Outputs = @()
$rawOutputs = Get-Cfg 'outputs' @()
if ($rawOutputs) { $Outputs = @($rawOutputs) }

# Media extensions
$MediaExtensions = @()
$videoExts = Get-Cfg 'media_extensions.video' $null
$audioExts = Get-Cfg 'media_extensions.audio' $null
if ($videoExts) { $MediaExtensions += $videoExts }
if ($audioExts) { $MediaExtensions += $audioExts }
if ($MediaExtensions.Count -eq 0) {
    $MediaExtensions = @(
        '.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4v', '.flv', '.wmv',
        '.mp3', '.wav', '.m4a', '.aac', '.flac', '.ogg', '.opus', '.wma'
    )
}

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
(แท็กหัวข้อ 2-5 อัน คั่นด้วย comma เช่น: programming, career, learning-english — สำคัญมาก ต้องมีบรรทัดนี้)

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

# ===================== Path setup =====================
$InboxDir      = Join-Path $Base 'inbox'
$SummaryDir    = Join-Path $Base 'summaries'
$TranscriptDir = Join-Path $Base 'transcripts'
$DoneDir       = Join-Path $Base 'done'
$FailedDir     = Join-Path $Base 'failed'
$LogDir        = Join-Path $Base 'logs'
$StateDir      = Join-Path $Base 'state'

foreach ($d in @($InboxDir, $SummaryDir, $TranscriptDir, $DoneDir, $FailedDir, $LogDir, $StateDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ----- log -----
$timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$LogFile = Join-Path $LogDir "run_$timestamp.log"
function Log($msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

# ============================================================
#  Helpers
# ============================================================

# Path script directory ใช้สำหรับหา transcribe.py
$ScriptDir = $PSScriptRoot
$TranscribePy = Join-Path $ScriptDir 'transcribe.py'
if (-not (Test-Path $TranscribePy)) {
    Log "ERROR: ไม่พบ transcribe.py ใน $ScriptDir"
    exit 1
}

# ----- lock file -----
$LockFile = Join-Path $StateDir '.running'
$LockStaleHours = 6

function Test-RunningLock {
    if (-not (Test-Path $LockFile)) { return $false }
    $age = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    if ($age.TotalHours -gt $LockStaleHours) {
        Log "พบ lock file เก่าค้าง ($([int]$age.TotalHours) ชม.) — ลบและรันต่อ"
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
        return $false
    }
    return $true
}
function Set-RunningLock { Set-Content -Path $LockFile -Value "$PID $(Get-Date -Format 'o')" -Encoding utf8 }
function Remove-RunningLock { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue }

# ----- cleanup -----
function Invoke-Cleanup {
    $deletedDone = 0; $deletedLogs = 0
    $cutoffDone = (Get-Date).AddDays(-$DoneRetentionDays)
    $cutoffLogs = (Get-Date).AddDays(-$LogRetentionDays)

    Get-ChildItem $DoneDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoffDone } |
        ForEach-Object {
            try { Remove-Item $_.FullName -Force; $deletedDone++ } catch { }
        }
    Get-ChildItem $LogDir -File -Filter 'run_*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoffLogs -and $_.FullName -ne $LogFile } |
        ForEach-Object {
            try { Remove-Item $_.FullName -Force; $deletedLogs++ } catch { }
        }
    if ($deletedDone -gt 0 -or $deletedLogs -gt 0) {
        Log ("ลบไฟล์เก่า: done {0} ไฟล์ (>{1}d), logs {2} ไฟล์ (>{3}d)" -f `
            $deletedDone, $DoneRetentionDays, $deletedLogs, $LogRetentionDays)
    }
}

# ----- attempt counter -----
function Get-AttemptPath($videoName) { Join-Path $StateDir ($videoName + '.attempts') }
function Get-AttemptCount($videoName) {
    $p = Get-AttemptPath $videoName
    if (-not (Test-Path $p)) { return 0 }
    try { return [int](Get-Content $p -Raw -Encoding utf8).Trim() } catch { return 0 }
}
function Set-AttemptCount($videoName, $count) { Set-Content -Path (Get-AttemptPath $videoName) -Value $count -Encoding utf8 }
function Clear-AttemptCount($videoName) { Remove-Item (Get-AttemptPath $videoName) -Force -ErrorAction SilentlyContinue }

function Move-ToFailed($video, $reason) {
    try {
        $dst = Join-Path $FailedDir $video.Name
        Move-Item -Path $video.FullName -Destination $dst -Force
        $reasonFile = Join-Path $FailedDir ($video.BaseName + '.reason.txt')
        Set-Content -Path $reasonFile -Value "ล้มเหลว $MaxFailedAttempts ครั้ง — $reason" -Encoding utf8
        Clear-AttemptCount $video.Name
        Log "  -> ย้าย $($video.Name) ไป failed\ (ล้มเหลวเกิน $MaxFailedAttempts ครั้ง)"
    } catch {
        Log "  WARNING: ย้ายไป failed\ ไม่สำเร็จ: $($_.Exception.Message)"
    }
}

# ----- per-video config sidecar -----
function Read-VideoConfig($video) {
    $cfgPath = Join-Path $InboxDir ($video.BaseName + '.config.json')
    if (-not (Test-Path $cfgPath)) { return @{} }
    try {
        $obj = Get-Content $cfgPath -Raw -Encoding utf8 | ConvertFrom-Json
        $result = @{}
        foreach ($prop in $obj.PSObject.Properties) { $result[$prop.Name] = $prop.Value }
        return $result
    } catch {
        Log "  WARNING: อ่าน video config.json ไม่สำเร็จ: $($_.Exception.Message)"
        return @{}
    }
}

function Select-Model {
    param($DurationSeconds, $ConfigModel)
    if ($ConfigModel) { return $ConfigModel }
    if (-not $EnableModelTier) { return $ClaudeModel }
    if (-not $DurationSeconds) { return $ClaudeModel }
    if ($DurationSeconds -lt $ModelTierShortSec) { return $ModelShort }
    if ($DurationSeconds -gt $ModelTierLongSec)  { return $ModelLong }
    return $ModelMedium
}

function Select-Prompt {
    param($VideoCfg)
    if ($VideoCfg.ContainsKey('prompt') -and $VideoCfg['prompt']) { return [string]$VideoCfg['prompt'] }
    $mode = if ($VideoCfg.ContainsKey('mode')) { [string]$VideoCfg['mode'] } else { 'default' }
    if ($PromptModes.ContainsKey($mode)) { return $PromptModes[$mode] }
    Log "  WARNING: ไม่พบ prompt mode '$mode' — ใช้ default"
    return $PromptModes['default']
}

function Get-EstimatedTokens($text) {
    if (-not $text) { return 0 }
    return [int]($text.Length / 4)
}

# ----- LLM (Claude / Gemini / OpenAI) -----
# POST JSON พร้อมดึง error body จริงจาก API + retry บน 429/503 (rate limit ชั่วคราว)
function Invoke-JsonPost {
    param([string]$Url, [string]$Body, [hashtable]$Headers = @{}, [int]$MaxRetry = 3)
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-RestMethod -Uri $Url -Method POST -Body $Body `
                -ContentType 'application/json; charset=utf-8' -Headers $Headers
        } catch {
            $code = $null; $bodyText = $null
            $r = $_.Exception.Response
            if ($r) {
                try { $code = [int]$r.StatusCode } catch { }
                try {
                    $reader = New-Object System.IO.StreamReader($r.GetResponseStream())
                    $bodyText = $reader.ReadToEnd()
                } catch { }
            }
            if (($code -eq 429 -or $code -eq 503) -and $attempt -lt $MaxRetry) {
                $wait = [int]([Math]::Pow(2, $attempt) * 10)   # 20s, 40s
                Log ("    rate limit ($code) — รอ $wait วินาทีแล้วลองใหม่ (รอบ $attempt/$MaxRetry)")
                Start-Sleep -Seconds $wait
                continue
            }
            $detail = if ($bodyText) { $bodyText.Trim() } else { $_.Exception.Message }
            throw "HTTP $code - $detail"
        }
    }
}

function Invoke-GeminiRequest {
    param([string]$FullPrompt)
    if (-not $script:GeminiApiKey) { throw 'gemini_api_key ไม่ได้ตั้งใน config' }
    $body = @{
        contents = @(@{ parts = @(@{ text = $FullPrompt }) })
    } | ConvertTo-Json -Depth 10 -Compress
    $url = "https://generativelanguage.googleapis.com/v1beta/models/$($script:GeminiModel):generateContent?key=$($script:GeminiApiKey)"
    $resp = Invoke-JsonPost -Url $url -Body $body
    $text = $resp.candidates[0].content.parts[0].text
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'Gemini คืนค่าว่างเปล่า' }
    return $text
}

function Invoke-OpenAIRequest {
    param([string]$FullPrompt)
    if (-not $script:OpenAIApiKey) { throw 'openai_api_key ไม่ได้ตั้งใน config' }
    $body = @{
        model    = $script:OpenAIModel
        messages = @(@{ role = 'user'; content = $FullPrompt })
    } | ConvertTo-Json -Depth 5 -Compress
    $headers = @{ Authorization = "Bearer $($script:OpenAIApiKey)" }
    $resp = Invoke-JsonPost -Url "$($script:OpenAIBaseUrl)/chat/completions" -Body $body -Headers $headers
    $text = $resp.choices[0].message.content
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'OpenAI คืนค่าว่างเปล่า' }
    return $text
}

function Invoke-LLM {
    param([string]$FullPrompt, [string]$Model)
    if ($script:LlmBackend -eq 'gemini') { return Invoke-GeminiRequest -FullPrompt $FullPrompt }
    if ($script:LlmBackend -eq 'openai')  { return Invoke-OpenAIRequest -FullPrompt $FullPrompt }
    # เก็บ stderr ลงไฟล์ชั่วคราว เพื่อให้เห็นสาเหตุจริงตอน fail (เช่น 401 auth)
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        $out = ($FullPrompt | & $script:ClaudeExe -p --model $Model 2>$tmpErr) -join "`r`n"
        $errText = (Get-Content $tmpErr -Raw -Encoding utf8 -ErrorAction SilentlyContinue)
    } finally {
        Remove-Item $tmpErr -Force -ErrorAction SilentlyContinue
    }
    if ($LASTEXITCODE -ne 0) {
        $detail = if ($errText) { $errText.Trim() } else { "exit code $LASTEXITCODE" }
        throw "Claude ล้มเหลว: $detail"
    }
    if ([string]::IsNullOrWhiteSpace($out)) { throw 'Claude คืนค่าว่างเปล่า' }
    return $out
}

function Invoke-ClaudeSummary {
    param($PromptTemplate, $Transcript, $Model)
    $fullPrompt = $PromptTemplate + "`n`n--- ข้อความถอดเสียง ---`n" + $Transcript
    return Invoke-LLM -FullPrompt $fullPrompt -Model $Model
}

function Split-IntoChunks {
    param($PlainText, $TranscriptMdPath)
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

function Invoke-ChunkedSummary {
    param($PromptTemplate, $Transcript, $TranscriptMdPath, $Model)
    $chunks = Split-IntoChunks -PlainText $Transcript -TranscriptMdPath $TranscriptMdPath
    $n = $chunks.Count
    Log "  ใช้ map-reduce: แบ่งเป็น $n chunk"
    $partials = @()
    for ($i = 0; $i -lt $n; $i++) {
        Log ("    chunk {0}/{1} ({2:N0} chars)..." -f ($i + 1), $n, $chunks[$i].Length)
        $chunkPrompt = @"
นี่คือบางส่วนของถอดเสียงวิดีโอ/เสียงยาว (ส่วนที่ $($i + 1) จาก $n)
สรุปเฉพาะเนื้อหาในส่วนนี้เป็นภาษาไทยแบบ bullet points ครบทุกประเด็น
ห้ามใส่หัวข้อ Markdown ห้ามใส่คำนำหรือคำลงท้าย

--- ข้อความถอดเสียง ส่วนที่ $($i + 1) ---
$($chunks[$i])
"@
        try { $partial = Invoke-LLM -FullPrompt $chunkPrompt -Model $Model }
        catch { throw "LLM ล้มเหลวที่ chunk $($i + 1): $($_.Exception.Message)" }
        $partials += "### ส่วนที่ $($i + 1)`n$partial"
    }
    Log '    รวมเป็นสรุปสุดท้าย...'
    $merged = $partials -join "`n`n"
    $finalPrompt = $PromptTemplate + @"


--- หมายเหตุ ---
ด้านล่างนี้คือสรุปย่อยจากแต่ละส่วน ให้สังเคราะห์เป็นสรุปเดียวตาม format ข้างบน — ไม่ต้องอ้างถึง "ส่วนที่ N"

--- สรุปย่อยจากแต่ละส่วน ---
$merged
"@
    try { $final = Invoke-LLM -FullPrompt $finalPrompt -Model $Model }
    catch { throw "LLM ล้มเหลวที่ขั้น merge: $($_.Exception.Message)" }
    return $final
}

# ----- parse summary metadata -----
function Get-SummaryMetadata {
    param([string]$Summary)
    $title = $null; $tags = @()
    # title: รองรับทั้ง "## หัวข้อเรื่อง" + บรรทัดถัดไป (Claude) และ "## <ชื่อเรื่อง>" ตรงๆ (Gemini)
    if ($Summary -match '(?m)^##\s*หัวข้อเรื่อง\s*\r?\n+\s*(.+?)\s*\r?\n') {
        $title = $Matches[1].Trim() -replace '^\*+|\*+$', ''
    }
    if (-not $title) {
        $sectionLabels = 'ภาพรวม|ประเด็นสำคัญ|ข้อสรุป|แท็ก|คำศัพท์|ตัวอย่าง|สิ่งที่ควร|วาระ|ข้อตัดสินใจ|Action|คำถาม'
        foreach ($line in ($Summary -split "\r?\n")) {
            if ($line -match '^##\s*(.+?)\s*$') {
                $h = $Matches[1].Trim() -replace '^\*+|\*+$', ''
                if ($h -and $h -notmatch '^หัวข้อเรื่อง' -and $h -notmatch "^($sectionLabels)") {
                    $title = $h; break
                }
            }
        }
    }
    if ($Summary -match '(?ms)^##\s*แท็ก\s*\r?\n+(.+?)(\r?\n##|\r?\n*$)') {
        $tagLine = $Matches[1].Trim()
        $rawTags = $tagLine -split '[,\n]' | ForEach-Object { ($_ -replace '^[\s\-\*•#]+', '').Trim() }
        $tags = $rawTags | Where-Object { $_ -and $_.Length -le 40 } | Select-Object -Unique
    }
    $cleanedBody = $Summary -replace '(?ms)\r?\n*##\s*แท็ก\s*\r?\n.*?(\r?\n##|\s*$)', "`$1"
    return @{ Title = $title; Tags = $tags; Body = $cleanedBody.TrimEnd() }
}

function ConvertTo-TagSlug($s) {
    $t = $s -replace '\s+', '-'
    # \p{M} = สระ/วรรณยุกต์ไทย (combining marks) ต้องเก็บไว้ ไม่งั้น "กีฬา" -> "กฬา"
    $t = $t -replace '[^\p{L}\p{M}\p{N}\-_/]', ''
    return $t.ToLower()
}

function Build-Frontmatter {
    param($Video, $Meta, $Title, $ExtraTags, $Model)
    $sourceEscaped = ($Video.Name -replace '"', '\"')
    $lines = @('---')
    $lines += "date: $(Get-Date -Format 'yyyy-MM-dd')"
    $lines += "source: `"$sourceEscaped`""
    if ($Meta -and $Meta.duration_hms) { $lines += "duration: `"$($Meta.duration_hms)`"" }
    if ($Meta -and $Meta.language)     { $lines += "language: $($Meta.language)" }
    if ($Meta -and $Meta.model)        { $lines += "whisper_model: $($Meta.model)" }
    if ($Model) { $lines += "summarizer: $Model" }
    if ($Title) {
        $titleEscaped = $Title -replace '"', '\"'
        $lines += "aliases: [`"$titleEscaped`"]"
    }
    $allTags = @('video-summary')
    if ($ExtraTags) {
        foreach ($t in $ExtraTags) {
            $slug = ConvertTo-TagSlug $t
            if ($slug -and $slug.Length -gt 1) { $allTags += $slug }
        }
    }
    $allTags = $allTags | Select-Object -Unique
    $lines += "tags: [$($allTags -join ', ')]"
    $lines += '---'
    $lines += ''
    return ($lines -join "`r`n") + "`r`n"
}

# ----- toast -----
function Send-CompletionToast {
    param([int]$Success, [int]$Failed, [int]$Skipped, [int]$Failed_Final)
    if (-not $EnableToast) { return }
    try {
        Import-Module BurntToast -ErrorAction Stop
        $parts = @("สำเร็จ $Success")
        if ($Failed       -gt 0) { $parts += "ล้มเหลว $Failed" }
        if ($Skipped      -gt 0) { $parts += "ข้าม $Skipped" }
        if ($Failed_Final -gt 0) { $parts += "ย้าย failed\ $Failed_Final" }
        $msg = $parts -join ' / '
        New-BurntToastNotification -Text 'VideoSummary เสร็จแล้ว', $msg | Out-Null
    } catch {
        Log "  WARNING: ส่ง toast ไม่สำเร็จ: $($_.Exception.Message)"
    }
}

# ----- busy check -----
function Get-MachineBusyReason {
    $samples = 3
    $gpuUtilVals = @(); $gpuMemVals = @(); $cpuVals = @()
    for ($i = 0; $i -lt $samples; $i++) {
        try {
            $line = (& nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
            if ($line -match '(\d+)\s*,\s*(\d+)') {
                $gpuUtilVals += [int]$Matches[1]
                $gpuMemVals  += [int]$Matches[2]
            }
        } catch { }
        try {
            $load = (Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average
            if ($null -ne $load) { $cpuVals += [int]$load }
        } catch { }
        if ($i -lt $samples - 1) { Start-Sleep -Seconds 1 }
    }
    $reasons = @()
    if ($cpuVals.Count -gt 0) {
        $cpuAvg = [int](($cpuVals | Measure-Object -Average).Average)
        Log ("  ภาระ CPU เฉลี่ย: {0}%" -f $cpuAvg)
        if ($cpuAvg -gt $MaxCpuPercent) { $reasons += "CPU $cpuAvg% (เกิน $MaxCpuPercent%)" }
    }
    if ($gpuUtilVals.Count -gt 0) {
        $gpuUtilAvg = [int](($gpuUtilVals | Measure-Object -Average).Average)
        $gpuMemMax  = [int](($gpuMemVals | Measure-Object -Maximum).Maximum)
        Log ("  ภาระ GPU เฉลี่ย: {0}% / VRAM ใช้สูงสุด: {1}MB" -f $gpuUtilAvg, $gpuMemMax)
        if ($gpuUtilAvg -gt $MaxGpuUtilPercent) { $reasons += "GPU util $gpuUtilAvg% (เกิน $MaxGpuUtilPercent%)" }
        if ($gpuMemMax  -gt $MaxGpuMemUsedMB)   { $reasons += "GPU VRAM ${gpuMemMax}MB (เกิน ${MaxGpuMemUsedMB}MB)" }
    } else {
        Log '  หมายเหตุ: อ่านค่า GPU ไม่ได้ (nvidia-smi) — ข้ามการเช็ค GPU'
    }
    if ($reasons.Count -gt 0) { return ($reasons -join ', ') }
    return $null
}

# ----- find Claude CLI -----
function Find-ClaudeExe {
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
    return @($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)[0]
}

# ----- write output to additional destinations -----
function Write-AdditionalOutputs {
    param($Outputs, $Name, $FullContent, $TranscriptMdPath, $HasTranscriptMd)
    foreach ($out in $Outputs) {
        $outPath = $null
        if ($out.PSObject.Properties['path']) { $outPath = [string]$out.path }
        if (-not $outPath) { continue }
        if (-not (Test-Path $outPath)) {
            Log "  WARNING: ไม่พบ output path: $outPath"
            continue
        }
        try {
            $destSummary = Join-Path $outPath "$Name.md"
            Set-Content -Path $destSummary -Value $FullContent -Encoding utf8
            Log "  บันทึก output: $destSummary"

            $copyTranscript = $false
            if ($out.PSObject.Properties['copy_transcript']) {
                $copyTranscript = [bool]$out.copy_transcript
            }
            if ($copyTranscript -and $HasTranscriptMd) {
                $destTranscript = Join-Path $outPath "$Name.transcript.md"
                Copy-Item -Path $TranscriptMdPath -Destination $destTranscript -Force
                Log "  บันทึก transcript: $destTranscript"
            }
        } catch {
            Log "  WARNING: เขียน output ไม่สำเร็จ ($outPath): $($_.Exception.Message)"
        }
    }
}

# ============================================================
#  MAIN
# ============================================================

Log '===== เริ่มรอบการทำงาน ====='
Log "config: $cfgFile"
Log "base:   $Base"

if (Test-RunningLock) {
    Log 'พบ instance อื่นรันอยู่ (lock file สด) — ออกเลย'
    Log '===== จบรอบการทำงาน (รันซ้อน) ====='
    exit 0
}
Set-RunningLock

try {

Invoke-Cleanup

$ClaudeExe = $null
if ($LlmBackend -eq 'claude') {
    $ClaudeExe = Find-ClaudeExe
    if (-not $ClaudeExe) {
        Log 'ERROR: ไม่พบ Claude CLI — หยุดการทำงาน'
        Send-CompletionToast -Success 0 -Failed 0 -Skipped 0 -Failed_Final 0
        exit 1
    }
    Log "Claude CLI: $ClaudeExe"
} elseif ($LlmBackend -eq 'gemini') {
    if (-not $GeminiApiKey) {
        Log 'ERROR: llm_backend = gemini แต่ gemini_api_key ว่างใน config'
        Send-CompletionToast -Success 0 -Failed 0 -Skipped 0 -Failed_Final 0
        exit 1
    }
    Log "LLM backend: Gemini ($GeminiModel)"
} elseif ($LlmBackend -eq 'openai') {
    if (-not $OpenAIApiKey) {
        Log 'ERROR: llm_backend = openai แต่ openai_api_key ว่างใน config'
        Send-CompletionToast -Success 0 -Failed 0 -Skipped 0 -Failed_Final 0
        exit 1
    }
    Log "LLM backend: OpenAI ($OpenAIModel via $OpenAIBaseUrl)"
} else {
    Log "ERROR: llm_backend '$LlmBackend' ไม่รู้จัก (รองรับ: claude, gemini, openai)"
    exit 1
}

# clean .tmp ค้าง
Get-ChildItem $TranscriptDir -Filter '*.tmp' -ErrorAction SilentlyContinue | ForEach-Object {
    Log "ลบไฟล์ .tmp ค้าง: $($_.Name)"
    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
}

# inbox + grace period
$allInbox = @(Get-ChildItem $InboxDir -File -ErrorAction SilentlyContinue |
    Where-Object { $MediaExtensions -contains $_.Extension.ToLower() })
$now = Get-Date
$videos  = @(); $skipped = 0
foreach ($v in $allInbox) {
    $ageSec = ($now - $v.LastWriteTime).TotalSeconds
    if ($ageSec -lt $FileInUseGraceSec) {
        Log ("  ข้าม (เพิ่งถูกแก้ {0:N0}s ที่แล้ว): $($v.Name)" -f $ageSec)
        $skipped++
    } else {
        $videos += $v
    }
}

if ($videos.Count -eq 0) {
    if ($skipped -gt 0) { Log "ไม่มีไฟล์พร้อมประมวลผล (ข้าม $skipped ไฟล์)" }
    else                { Log 'ไม่พบไฟล์ใน inbox — จบงานรอบนี้' }
    Log '===== จบรอบการทำงาน ====='
    Send-CompletionToast -Success 0 -Failed 0 -Skipped $skipped -Failed_Final 0
    exit 0
}
Log ('พบไฟล์พร้อมประมวลผล {0} ไฟล์ (ข้าม {1})' -f $videos.Count, $skipped)

if ($EnableBusyCheck) {
    Log 'ตรวจสอบภาระเครื่อง...'
    $busyReason = Get-MachineBusyReason
    if ($busyReason) {
        Log "เครื่องทำงานหนัก ($busyReason) — ข้ามรอบนี้"
        Log '===== จบรอบการทำงาน (เลื่อนออกไป) ====='
        exit 0
    }
    Log '  เครื่องว่างพอ — เริ่มงานได้'
}

# ============================================================
#  PHASE A: ถอดเสียง batch
# ============================================================
$needTranscribe = @($videos | Where-Object {
    -not (Test-Path (Join-Path $TranscriptDir "$($_.BaseName).txt"))
})
$alreadyHave = $videos.Count - $needTranscribe.Count
if ($alreadyHave -gt 0) { Log "พบ transcript เดิม $alreadyHave ไฟล์ — ข้าม" }

if ($needTranscribe.Count -gt 0) {
    Log "เริ่มถอดเสียง batch: $($needTranscribe.Count) ไฟล์..."
    $pyArgs = @($TranscribePy)
    foreach ($v in $needTranscribe) {
        $pyArgs += $v.FullName
        $pyArgs += (Join-Path $TranscriptDir "$($v.BaseName).txt")
    }
    & $PythonExe @pyArgs
    if ($LASTEXITCODE -ne 0) {
        Log "  WARNING: การถอดเสียง batch มีไฟล์ที่ล้มเหลว (exit code $LASTEXITCODE)"
    }
}

# ============================================================
#  PHASE B: สรุป + เขียนไฟล์
# ============================================================
$success = 0; $failed = 0; $failed_final = 0

foreach ($video in $videos) {
    $name = $video.BaseName
    Log "--- ประมวลผล: $($video.Name) ---"
    try {
        $transcriptPath = Join-Path $TranscriptDir "$name.txt"
        $transcriptMd   = Join-Path $TranscriptDir "$name.transcript.md"

        if (-not (Test-Path $transcriptPath)) { throw 'ไม่พบ transcript (ถอดเสียงล้มเหลว)' }
        $transcript = Get-Content $transcriptPath -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($transcript)) { throw 'transcript ว่างเปล่า (ไฟล์อาจไม่มีเสียง)' }

        $meta = $null
        $metaPath = Join-Path $TranscriptDir "$name.meta.json"
        if (Test-Path $metaPath) {
            try { $meta = Get-Content $metaPath -Raw -Encoding utf8 | ConvertFrom-Json } catch { }
        }

        $videoCfg = Read-VideoConfig $video
        $durationSec = if ($meta -and $meta.duration_seconds) { [double]$meta.duration_seconds } else { 0 }
        $configModel = if ($videoCfg.ContainsKey('model')) { [string]$videoCfg['model'] } else { $null }
        $modelToUse = Select-Model -DurationSeconds $durationSec -ConfigModel $configModel
        $summarizerLabel = switch ($LlmBackend) {
            'gemini' { "gemini/$GeminiModel" }
            'openai' { "openai/$OpenAIModel" }
            default  { $modelToUse }
        }
        $promptTpl = Select-Prompt -VideoCfg $videoCfg

        $est = Get-EstimatedTokens $transcript
        Log ("  transcript: {0:N0} chars (~{1:N0} tokens), model: {2}" -f $transcript.Length, $est, $summarizerLabel)

        Log '  ส่งให้ LLM สรุปเป็นภาษาไทย...'
        if ($transcript.Length -gt $ChunkThresholdChars) {
            $summary = Invoke-ChunkedSummary -PromptTemplate $promptTpl -Transcript $transcript `
                -TranscriptMdPath $transcriptMd -Model $modelToUse
        } else {
            $summary = Invoke-ClaudeSummary -PromptTemplate $promptTpl -Transcript $transcript -Model $modelToUse
        }

        $extracted = Get-SummaryMetadata -Summary $summary
        if ($extracted.Title) { Log ("  title: " + $extracted.Title) }
        if ($extracted.Tags -and $extracted.Tags.Count -gt 0) { Log ("  tags: " + ($extracted.Tags -join ', ')) }
        $body = $extracted.Body

        $hasTranscriptMd = Test-Path $transcriptMd
        $transcriptLink = if ($hasTranscriptMd) { "> 📝 Full transcript: [[$name.transcript]]`r`n`r`n" } else { '' }

        $frontmatter = Build-Frontmatter -Video $video -Meta $meta `
            -Title $extracted.Title -ExtraTags $extracted.Tags -Model $summarizerLabel
        $fullContent = $frontmatter + $transcriptLink + $body + "`r`n"

        # local (canonical)
        $localPath = Join-Path $SummaryDir "$name.md"
        Set-Content -Path $localPath -Value $fullContent -Encoding utf8
        Log "  บันทึก local: $localPath"

        # additional outputs from config
        Write-AdditionalOutputs -Outputs $Outputs -Name $name `
            -FullContent $fullContent -TranscriptMdPath $transcriptMd -HasTranscriptMd $hasTranscriptMd

        # move video + sidecar config to done
        Move-Item -Path $video.FullName -Destination (Join-Path $DoneDir $video.Name) -Force
        $cfgInbox = Join-Path $InboxDir ($video.BaseName + '.config.json')
        if (Test-Path $cfgInbox) {
            Move-Item -Path $cfgInbox -Destination (Join-Path $DoneDir ($video.BaseName + '.config.json')) -Force
        }
        Log '  ย้ายไฟล์ไป done เรียบร้อย'
        Clear-AttemptCount $video.Name
        $success++
    }
    catch {
        $errMsg = $_.Exception.Message
        Log "  ERROR: $errMsg"
        $failed++
        $attempts = (Get-AttemptCount $video.Name) + 1
        Set-AttemptCount $video.Name $attempts
        Log ("  attempt {0}/{1}" -f $attempts, $MaxFailedAttempts)
        if ($attempts -ge $MaxFailedAttempts) {
            Move-ToFailed -video $video -reason $errMsg
            $failed_final++
        }
    }
}

Log ('===== จบรอบ: สำเร็จ {0} / ล้มเหลว {1} / ข้าม {2} / failed {3} =====' -f `
    $success, $failed, $skipped, $failed_final)
Send-CompletionToast -Success $success -Failed $failed -Skipped $skipped -Failed_Final $failed_final

}
finally {
    Remove-RunningLock
}
