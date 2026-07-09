# ============================================================
#  VideoSummary.Common.ps1 — โค้ดกลางที่ใช้ร่วมกันระหว่าง
#  summarize-videos.ps1 และ resummarize.ps1
#
#  ประกอบด้วย: โหลด config, prompt templates, เลือก model,
#  เรียก LLM (Claude CLI / Gemini / OpenAI), แบ่ง chunk (map-reduce),
#  สกัด title/tags, สร้าง frontmatter, เขียน output เพิ่มเติม
#
#  วิธีใช้: dot-source จากสคริปต์หลัก
#    . (Join-Path $PSScriptRoot 'VideoSummary.Common.ps1')
#
#  หมายเหตุ: ไฟล์นี้ต้องเป็น UTF-8 with BOM (มีภาษาไทย)
# ============================================================

# Log fallback — สคริปต์หลักนิยามทับได้หลัง dot-source (เช่นเขียนลงไฟล์ log ด้วย)
function Log($msg) { Write-Host $msg }

# ===================== Config =====================
function Resolve-VSConfigPath {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit }
    if ($env:VIDEOSUMMARY_CONFIG) { return $env:VIDEOSUMMARY_CONFIG }
    return Join-Path $PSScriptRoot 'config.json'
}

# เข้าถึง config value แบบ dot-path พร้อม default
function Get-Cfg {
    param([string]$Path, $Default)
    $parts = $Path -split '\.'
    $cur = $script:config
    foreach ($p in $parts) {
        if ($null -eq $cur) { return $Default }
        $member = $cur.PSObject.Properties[$p]
        if (-not $member) { return $Default }
        $cur = $member.Value
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

# โหลด config แล้ว map เป็นตัวแปร script-scope ทั้งหมด — throw ถ้าไม่พบ/ไม่ครบ
function Initialize-VSConfig {
    param([string]$ConfigPathParam)
    $script:CfgFile = Resolve-VSConfigPath -Explicit $ConfigPathParam
    if (-not (Test-Path $script:CfgFile)) {
        throw "ไม่พบ config: $($script:CfgFile) — ก๊อป config.example.json -> config.json แล้วแก้ค่าให้ตรงระบบของคุณ"
    }
    $script:config = Get-Content $script:CfgFile -Raw -Encoding utf8 | ConvertFrom-Json

    $script:Base = Get-Cfg 'base' $null
    if (-not $script:Base) { throw 'config.base ไม่ได้ระบุ' }

    $script:PythonExe         = Get-Cfg 'python_exe' 'python'
    $script:ClaudeModel       = Get-Cfg 'claude_model' 'sonnet'
    $script:FileInUseGraceSec = [int](Get-Cfg 'file_in_use_grace_sec' 60)
    $script:EnableToast       = [bool](Get-Cfg 'enable_toast' $true)

    $script:EnableBusyCheck   = [bool](Get-Cfg 'busy_check.enable' $true)
    $script:MaxGpuUtilPercent = [int](Get-Cfg 'busy_check.max_gpu_util_percent' 40)
    $script:MaxGpuMemUsedMB   = [int](Get-Cfg 'busy_check.max_gpu_mem_mb' 4096)
    $script:MaxCpuPercent     = [int](Get-Cfg 'busy_check.max_cpu_percent' 70)
    $script:MaxDeferrals      = [int](Get-Cfg 'busy_check.max_deferrals' 3)

    $script:DoneRetentionDays = [int](Get-Cfg 'retention.done_days' 60)
    $script:LogRetentionDays  = [int](Get-Cfg 'retention.logs_days' 30)
    $script:MaxFailedAttempts = [int](Get-Cfg 'retry.max_failed_attempts' 3)

    $script:EnableModelTier   = [bool](Get-Cfg 'enable_model_tier' $true)
    $script:ModelTierShortSec = [int](Get-Cfg 'model_tier.short_sec' 300)
    $script:ModelTierLongSec  = [int](Get-Cfg 'model_tier.long_sec' 3600)
    $script:ModelShort        = [string](Get-Cfg 'model_tier.short' 'haiku')
    $script:ModelMedium       = [string](Get-Cfg 'model_tier.medium' 'sonnet')
    $script:ModelLong         = [string](Get-Cfg 'model_tier.long' 'opus')

    $script:LlmBackend        = [string](Get-Cfg 'llm_backend' 'claude')
    $script:GeminiApiKey      = [string](Get-Cfg 'gemini_api_key' '')
    $script:GeminiModel       = [string](Get-Cfg 'gemini_model' 'gemini-2.5-flash')
    $script:OpenAIApiKey      = [string](Get-Cfg 'openai_api_key' '')
    $script:OpenAIModel       = [string](Get-Cfg 'openai_model' 'gpt-4o-mini')
    $script:OpenAIBaseUrl     = [string](Get-Cfg 'openai_base_url' 'https://api.openai.com/v1')

    $script:ChunkThresholdChars = [int](Get-Cfg 'chunk_threshold_chars' 600000)
    $script:ChunkSizeChars      = [int](Get-Cfg 'chunk_size_chars' 200000)
    $script:SummaryTimestamps   = [bool](Get-Cfg 'summary_timestamps' $true)

    $script:Outputs = @()
    $rawOutputs = Get-Cfg 'outputs' @()
    if ($rawOutputs) { $script:Outputs = @($rawOutputs) }

    $script:MediaExtensions = @()
    $videoExts = Get-Cfg 'media_extensions.video' $null
    $audioExts = Get-Cfg 'media_extensions.audio' $null
    if ($videoExts) { $script:MediaExtensions += $videoExts }
    if ($audioExts) { $script:MediaExtensions += $audioExts }
    if ($script:MediaExtensions.Count -eq 0) {
        $script:MediaExtensions = @(
            '.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4v', '.flv', '.wmv',
            '.mp3', '.wav', '.m4a', '.aac', '.flac', '.ogg', '.opus', '.wma'
        )
    }
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

# คำสั่งเสริมเมื่อป้อน transcript ฉบับมีจุดเวลา — ให้สรุปอ้างเวลาได้
$TimestampInstruction = @'


--- เรื่องจุดเวลา ---
ข้อความถอดเสียงมีจุดเวลากำกับรูปแบบ **[HH:MM:SS]**
ให้แนบเวลาอ้างอิงท้ายประเด็นสำคัญแต่ละข้อในรูป [HH:MM:SS] (เวลาของช่วงที่พูดถึงประเด็นนั้น) เพื่อให้กดกลับไปดูช่วงนั้นในวิดีโอได้
'@

function Select-Prompt {
    param($VideoCfg)
    if ($VideoCfg -and $VideoCfg.ContainsKey('prompt') -and $VideoCfg['prompt']) { return [string]$VideoCfg['prompt'] }
    $mode = if ($VideoCfg -and $VideoCfg.ContainsKey('mode') -and $VideoCfg['mode']) { [string]$VideoCfg['mode'] } else { 'default' }
    if ($PromptModes.ContainsKey($mode)) { return $PromptModes[$mode] }
    Log "  WARNING: ไม่พบ prompt mode '$mode' — ใช้ default"
    return $PromptModes['default']
}

# ===================== Model selection =====================
function Select-Model {
    param($DurationSeconds, $ConfigModel)
    if ($ConfigModel) { return $ConfigModel }
    if (-not $script:EnableModelTier) { return $script:ClaudeModel }
    if (-not $DurationSeconds) { return $script:ClaudeModel }
    if ($DurationSeconds -lt $script:ModelTierShortSec) { return $script:ModelShort }
    if ($DurationSeconds -gt $script:ModelTierLongSec)  { return $script:ModelLong }
    return $script:ModelMedium
}

function Get-SummarizerLabel {
    param([string]$ModelToUse)
    switch ($script:LlmBackend) {
        'gemini' { return "gemini/$($script:GeminiModel)" }
        'openai' { return "openai/$($script:OpenAIModel)" }
        default  { return $ModelToUse }
    }
}

# ===================== Token estimate (ภาษาไทยโทเคนแน่นกว่าอังกฤษ ~2 เท่า) =====================
function Get-EstimatedTokens {
    param([string]$Text, [string]$Language)
    if (-not $Text) { return 0 }
    $divisor = if ($Language -eq 'th') { 2 } else { 4 }
    return [int]($Text.Length / $divisor)
}

# เกณฑ์แบ่ง chunk ใน config คิดจากอังกฤษ (~4 chars/token) — ไทยหดลงครึ่งหนึ่งกันโทเคนล้น
function Get-EffectiveChunkLimits {
    param([string]$Language)
    $factor = if ($Language -eq 'th') { 2 } else { 1 }
    return @{
        Threshold = [int]($script:ChunkThresholdChars / $factor)
        ChunkSize = [int]($script:ChunkSizeChars / $factor)
    }
}

# ===================== เลือก input ให้ LLM =====================
# ถ้าเปิด summary_timestamps และมี .transcript.md → ใช้ฉบับมีจุดเวลา (ตัด frontmatter + ลิงก์หัวไฟล์)
function Get-LLMInputText {
    param([string]$PlainText, [string]$TranscriptMdPath)
    if ($script:SummaryTimestamps -and $TranscriptMdPath -and (Test-Path $TranscriptMdPath)) {
        try {
            $md = Get-Content $TranscriptMdPath -Raw -Encoding utf8
            $body = $md -replace '(?s)^---.*?---\s*', ''
            $body = (($body -split "\r?\n") | Where-Object { $_ -notmatch '^\s*>' }) -join "`n"
            $body = $body.Trim()
            if ($body) { return @{ Text = $body; HasTimestamps = $true } }
        } catch { }
    }
    return @{ Text = $PlainText; HasTimestamps = $false }
}

# ===================== LLM (Claude / Gemini / OpenAI) =====================
# ตรวจความพร้อม backend — throw ถ้าไม่พร้อม, คืนข้อความไว้ log
function Initialize-LLMBackend {
    switch ($script:LlmBackend) {
        'claude' {
            $script:ClaudeExe = Find-ClaudeExe
            if (-not $script:ClaudeExe) { throw 'ไม่พบ Claude CLI' }
            return "Claude CLI: $($script:ClaudeExe)"
        }
        'gemini' {
            if (-not $script:GeminiApiKey) { throw 'llm_backend = gemini แต่ gemini_api_key ว่างใน config' }
            return "LLM backend: Gemini ($($script:GeminiModel))"
        }
        'openai' {
            if (-not $script:OpenAIApiKey) { throw 'llm_backend = openai แต่ openai_api_key ว่างใน config' }
            return "LLM backend: OpenAI ($($script:OpenAIModel) via $($script:OpenAIBaseUrl))"
        }
        default { throw "llm_backend '$($script:LlmBackend)' ไม่รู้จัก (รองรับ: claude, gemini, openai)" }
    }
}

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

# POST JSON พร้อมดึง error body จริงจาก API + retry บน 429/500/503 (ปัญหาชั่วคราวฝั่ง API)
function Invoke-JsonPost {
    param([string]$Url, [string]$Body, [hashtable]$Headers = @{}, [int]$MaxRetry = 5)
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
            if (($code -eq 429 -or $code -eq 500 -or $code -eq 503) -and $attempt -lt $MaxRetry) {
                $wait = [Math]::Min(120, [int]([Math]::Pow(2, $attempt) * 10))   # 20s, 40s, 80s, 120s
                Log ("    API ไม่ว่าง ($code) — รอ $wait วินาทีแล้วลองใหม่ (รอบ $attempt/$MaxRetry)")
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
    # เนื้อหาถูกบล็อกโดยระบบกรอง → บอกสาเหตุจริง ไม่ใช่ error งง ๆ
    if ($resp.promptFeedback -and $resp.promptFeedback.blockReason) {
        throw "Gemini บล็อกเนื้อหา (blockReason: $($resp.promptFeedback.blockReason))"
    }
    if (-not $resp.candidates) { throw 'Gemini ไม่คืนคำตอบ (ไม่มี candidates)' }
    $cand = $resp.candidates[0]
    $text = ($cand.content.parts | ForEach-Object { $_.text }) -join ''
    if ([string]::IsNullOrWhiteSpace($text)) {
        $fr = if ($cand.finishReason) { $cand.finishReason } else { 'ไม่ทราบ' }
        throw "Gemini คืนค่าว่างเปล่า (finishReason: $fr)"
    }
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
    if ($script:LlmBackend -eq 'openai') { return Invoke-OpenAIRequest -FullPrompt $FullPrompt }
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

# ===================== Summarize (ตรง + map-reduce) =====================
function Invoke-SingleSummary {
    param($PromptTemplate, $InputText, $Model, [bool]$WithTimestamps)
    $tpl = $PromptTemplate
    if ($WithTimestamps) { $tpl += $TimestampInstruction }
    $fullPrompt = $tpl + "`n`n--- ข้อความถอดเสียง ---`n" + $InputText
    return Invoke-LLM -FullPrompt $fullPrompt -Model $Model
}

function Split-IntoChunks {
    param([string]$Text, [bool]$ParagraphMode, [int]$ChunkSizeChars)
    # ParagraphMode = input มาจาก .transcript.md (ย่อหน้าคั่นด้วยบรรทัดว่าง) / ไม่งั้นตัดรายบรรทัด
    $splitPattern = if ($ParagraphMode) { "(?:`r?`n){2,}" } else { "(?:`r?`n)+" }
    $paragraphs = $Text -split $splitPattern | Where-Object { $_.Trim() }
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
    param($PromptTemplate, $InputText, [bool]$ParagraphMode, [int]$ChunkSize, $Model, [bool]$WithTimestamps)
    $chunks = Split-IntoChunks -Text $InputText -ParagraphMode $ParagraphMode -ChunkSizeChars $ChunkSize
    $n = $chunks.Count
    Log "  ใช้ map-reduce: แบ่งเป็น $n chunk"
    $tsLine = if ($WithTimestamps) {
        "`nข้อความมีจุดเวลากำกับรูปแบบ **[HH:MM:SS]** — ให้ระบุเวลาท้ายประเด็นที่เกี่ยวข้องในรูป [HH:MM:SS]"
    } else { '' }
    $partials = @()
    for ($i = 0; $i -lt $n; $i++) {
        Log ("    chunk {0}/{1} ({2:N0} chars)..." -f ($i + 1), $n, $chunks[$i].Length)
        $chunkPrompt = @"
นี่คือบางส่วนของถอดเสียงวิดีโอ/เสียงยาว (ส่วนที่ $($i + 1) จาก $n)
สรุปเฉพาะเนื้อหาในส่วนนี้เป็นภาษาไทยแบบ bullet points ครบทุกประเด็น
ห้ามใส่หัวข้อ Markdown ห้ามใส่คำนำหรือคำลงท้าย$tsLine

--- ข้อความถอดเสียง ส่วนที่ $($i + 1) ---
$($chunks[$i])
"@
        try { $partial = Invoke-LLM -FullPrompt $chunkPrompt -Model $Model }
        catch { throw "LLM ล้มเหลวที่ chunk $($i + 1): $($_.Exception.Message)" }
        $partials += "### ส่วนที่ $($i + 1)`n$partial"
    }
    Log '    รวมเป็นสรุปสุดท้าย...'
    $merged = $partials -join "`n`n"
    $tpl = $PromptTemplate
    if ($WithTimestamps) { $tpl += $TimestampInstruction }
    $finalPrompt = $tpl + @"


--- หมายเหตุ ---
ด้านล่างนี้คือสรุปย่อยจากแต่ละส่วน ให้สังเคราะห์เป็นสรุปเดียวตาม format ข้างบน — ไม่ต้องอ้างถึง "ส่วนที่ N"

--- สรุปย่อยจากแต่ละส่วน ---
$merged
"@
    try { $final = Invoke-LLM -FullPrompt $finalPrompt -Model $Model }
    catch { throw "LLM ล้มเหลวที่ขั้น merge: $($_.Exception.Message)" }
    return $final
}

# ===================== parse summary metadata =====================
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
    param([string]$SourceName, $Meta, $Title, $ExtraTags, $Model)
    $sourceEscaped = ($SourceName -replace '"', '\"')
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

# ===================== write output to additional destinations =====================
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

# ===================== toast =====================
function Send-Toast {
    param([string]$Title, [string]$Message)
    if (-not $script:EnableToast) { return }
    try {
        Import-Module BurntToast -ErrorAction Stop
        New-BurntToastNotification -Text $Title, $Message | Out-Null
    } catch {
        Log "  WARNING: ส่ง toast ไม่สำเร็จ: $($_.Exception.Message)"
    }
}
