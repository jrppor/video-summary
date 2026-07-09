# ============================================================
#  ระบบสรุปวิดีโอ/เสียงอัตโนมัติ
#  ขั้นตอน: ถอดเสียง (faster-whisper) -> สรุปภาษาไทย (LLM) -> ไฟล์ .md
#
#  โค้ดกลาง (prompt / LLM / chunking / frontmatter) อยู่ใน VideoSummary.Common.ps1
#
#  Parameters:
#    -ConfigPath <path>           ระบุ config เอง (สูงสุด)
#    -Force                       ข้ามการเช็คภาระเครื่อง (สำหรับรันมือ)
#
#  Config:
#    -ConfigPath <path>           ผ่าน parameter (สูงสุด)
#    $env:VIDEOSUMMARY_CONFIG     ผ่าน environment variable
#    <script_dir>\config.json     ค่า default (ถ้าไม่ระบุข้างต้น)
# ============================================================

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ===================== โหลดโค้ดกลาง + config =====================
. (Join-Path $PSScriptRoot 'VideoSummary.Common.ps1')

try {
    Initialize-VSConfig -ConfigPathParam $ConfigPath
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

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

# ----- log (นิยามทับ fallback จากไฟล์กลาง — เขียนลงไฟล์ด้วย) -----
$timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$LogFile = Join-Path $LogDir "run_$timestamp.log"
function Log($msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

# ============================================================
#  Helpers (เฉพาะสคริปต์หลัก)
# ============================================================

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

# ----- deferral counter (เลื่อนรอบเพราะเครื่องไม่ว่าง) -----
$DeferralFile = Join-Path $StateDir 'deferral.count'
function Get-DeferralCount {
    if (-not (Test-Path $DeferralFile)) { return 0 }
    try { return [int](Get-Content $DeferralFile -Raw -Encoding utf8).Trim() } catch { return 0 }
}
function Set-DeferralCount($n) { Set-Content -Path $DeferralFile -Value $n -Encoding utf8 }
function Clear-DeferralCount { Remove-Item $DeferralFile -Force -ErrorAction SilentlyContinue }

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

# ----- completion toast -----
function Send-CompletionToast {
    param([int]$Success, [int]$Failed, [int]$Skipped, [int]$Failed_Final)
    $parts = @("สำเร็จ $Success")
    if ($Failed       -gt 0) { $parts += "ล้มเหลว $Failed" }
    if ($Skipped      -gt 0) { $parts += "ข้าม $Skipped" }
    if ($Failed_Final -gt 0) { $parts += "ย้าย failed\ $Failed_Final" }
    Send-Toast -Title 'VideoSummary เสร็จแล้ว' -Message ($parts -join ' / ')
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

# ============================================================
#  MAIN
# ============================================================

Log '===== เริ่มรอบการทำงาน ====='
Log "config: $CfgFile"
Log "base:   $Base"
if ($Force) { Log 'โหมด -Force: ข้ามการเช็คภาระเครื่อง' }

if (Test-RunningLock) {
    Log 'พบ instance อื่นรันอยู่ (lock file สด) — ออกเลย'
    Log '===== จบรอบการทำงาน (รันซ้อน) ====='
    exit 0
}
Set-RunningLock

try {

Invoke-Cleanup

try {
    $backendInfo = Initialize-LLMBackend
    Log $backendInfo
} catch {
    Log "ERROR: $($_.Exception.Message) — หยุดการทำงาน"
    Send-CompletionToast -Success 0 -Failed 0 -Skipped 0 -Failed_Final 0
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
    exit 0
}
Log ('พบไฟล์พร้อมประมวลผล {0} ไฟล์ (ข้าม {1})' -f $videos.Count, $skipped)

# ============================================================
#  PHASE A: ถอดเสียง batch
#  เช็คภาระเครื่องเฉพาะขั้นนี้ — ขั้นสรุป (เรียก API) แทบไม่กินเครื่อง
# ============================================================
$needTranscribe = @($videos | Where-Object {
    -not (Test-Path (Join-Path $TranscriptDir "$($_.BaseName).txt"))
})
$alreadyHave = $videos.Count - $needTranscribe.Count
if ($alreadyHave -gt 0) { Log "พบ transcript เดิม $alreadyHave ไฟล์ — ข้ามการถอดเสียง" }

$lowPriority = $false
if ($needTranscribe.Count -gt 0 -and $EnableBusyCheck -and -not $Force) {
    Log 'ตรวจสอบภาระเครื่อง (ก่อนถอดเสียง)...'
    $busyReason = Get-MachineBusyReason
    if ($busyReason) {
        $priorDeferrals = Get-DeferralCount
        if ($priorDeferrals -ge $MaxDeferrals) {
            # เลื่อนมาครบเพดานแล้ว — รันเลยแบบลดความสำคัญ ไม่ปล่อยให้ค้างข้ามสัปดาห์
            Log "เครื่องทำงานหนัก ($busyReason) แต่เลื่อนมาแล้ว $priorDeferrals รอบ (เพดาน $MaxDeferrals) — รันต่อแบบลดความสำคัญ"
            $lowPriority = $true
            Clear-DeferralCount
        } else {
            $n = $priorDeferrals + 1
            Set-DeferralCount $n
            Log "เครื่องทำงานหนัก ($busyReason) — เลื่อนการถอดเสียง $($needTranscribe.Count) ไฟล์ (ครั้งที่ $n/$MaxDeferrals)"
            Send-Toast -Title 'VideoSummary เลื่อนรอบ' `
                -Message "เครื่องไม่ว่าง ($busyReason) — เลื่อนถอดเสียง $($needTranscribe.Count) ไฟล์ (ครั้งที่ $n/$MaxDeferrals)"
            # ตัดไฟล์ที่ยังไม่มี transcript ออกจากรอบนี้ — ไฟล์ที่มี transcript แล้วยังสรุปต่อได้
            $videos = @($videos | Where-Object { Test-Path (Join-Path $TranscriptDir "$($_.BaseName).txt") })
            $needTranscribe = @()
            if ($videos.Count -eq 0) {
                Log '===== จบรอบการทำงาน (เลื่อนออกไป) ====='
                exit 0
            }
        }
    } else {
        Log '  เครื่องว่างพอ — เริ่มงานได้'
        Clear-DeferralCount
    }
}

if ($needTranscribe.Count -gt 0) {
    Log "เริ่มถอดเสียง batch: $($needTranscribe.Count) ไฟล์..."
    if ($lowPriority) {
        # โปรเซสลูก (python) สืบทอด priority class จากโปรเซสนี้
        try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' }
        catch { Log "  WARNING: ลดความสำคัญโปรเซสไม่สำเร็จ: $($_.Exception.Message)" }
    }
    try {
        $pyArgs = @($TranscribePy)
        foreach ($v in $needTranscribe) {
            $pyArgs += $v.FullName
            $pyArgs += (Join-Path $TranscriptDir "$($v.BaseName).txt")
        }
        & $PythonExe @pyArgs
        if ($LASTEXITCODE -ne 0) {
            Log "  WARNING: การถอดเสียง batch มีไฟล์ที่ล้มเหลว (exit code $LASTEXITCODE)"
        }
    } finally {
        if ($lowPriority) {
            try { (Get-Process -Id $PID).PriorityClass = 'Normal' } catch { }
        }
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
        $summarizerLabel = Get-SummarizerLabel -ModelToUse $modelToUse
        $promptTpl = Select-Prompt -VideoCfg $videoCfg

        $lang = if ($meta -and $meta.language) { [string]$meta.language } else { '' }
        $limits = Get-EffectiveChunkLimits -Language $lang
        $inputInfo = Get-LLMInputText -PlainText $transcript -TranscriptMdPath $transcriptMd

        $est = Get-EstimatedTokens -Text $inputInfo.Text -Language $lang
        Log ("  transcript: {0:N0} chars (~{1:N0} tokens, lang: {2}), model: {3}" -f `
            $inputInfo.Text.Length, $est, $(if ($lang) { $lang } else { '?' }), $summarizerLabel)
        if ($inputInfo.HasTimestamps) { Log '  ใช้ transcript ฉบับมี timestamp — สรุปอ้างจุดเวลาได้' }

        Log '  ส่งให้ LLM สรุปเป็นภาษาไทย...'
        if ($inputInfo.Text.Length -gt $limits.Threshold) {
            $summary = Invoke-ChunkedSummary -PromptTemplate $promptTpl -InputText $inputInfo.Text `
                -ParagraphMode $inputInfo.HasTimestamps -ChunkSize $limits.ChunkSize `
                -Model $modelToUse -WithTimestamps $inputInfo.HasTimestamps
        } else {
            $summary = Invoke-SingleSummary -PromptTemplate $promptTpl -InputText $inputInfo.Text `
                -Model $modelToUse -WithTimestamps $inputInfo.HasTimestamps
        }

        $extracted = Get-SummaryMetadata -Summary $summary
        if ($extracted.Title) { Log ("  title: " + $extracted.Title) }
        if ($extracted.Tags -and $extracted.Tags.Count -gt 0) { Log ("  tags: " + ($extracted.Tags -join ', ')) }
        $body = $extracted.Body

        $hasTranscriptMd = Test-Path $transcriptMd
        $transcriptLink = if ($hasTranscriptMd) { "> 📝 Full transcript: [[$name.transcript]]`r`n`r`n" } else { '' }

        $frontmatter = Build-Frontmatter -SourceName $video.Name -Meta $meta `
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
