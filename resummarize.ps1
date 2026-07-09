# ============================================================
#  Re-summarize: สรุปไฟล์ใหม่จาก transcript ที่มีอยู่
#  โค้ดกลาง (prompt / LLM / chunking / frontmatter) อยู่ใน VideoSummary.Common.ps1
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

    [string]$Model,

    [ValidateSet('default', 'lecture', 'meeting')]
    [string]$Mode,

    [string]$Prompt,

    [string]$ConfigPath
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

$TranscriptDir = Join-Path $Base 'transcripts'
$SummaryDir    = Join-Path $Base 'summaries'
if (-not (Test-Path $SummaryDir)) { New-Item -ItemType Directory -Path $SummaryDir -Force | Out-Null }

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

# ----- meta -----
$meta = $null
if (Test-Path $metaPath) {
    try { $meta = Get-Content $metaPath -Raw -Encoding utf8 | ConvertFrom-Json } catch { }
}

# ----- prompt + model (model tier ตาม duration เหมือนสคริปต์หลัก ถ้าไม่ระบุ -Model) -----
$promptTpl =
    if ($Prompt) { $Prompt }
    elseif ($Mode) { $PromptModes[$Mode] }
    else { $PromptModes['default'] }

$durationSec = if ($meta -and $meta.duration_seconds) { [double]$meta.duration_seconds } else { 0 }
$modelToUse = Select-Model -DurationSeconds $durationSec -ConfigModel $Model

# ----- backend -----
try {
    $backendInfo = Initialize-LLMBackend
    Write-Host $backendInfo
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ----- call LLM -----
$summarizerLabel = Get-SummarizerLabel -ModelToUse $modelToUse
$lang = if ($meta -and $meta.language) { [string]$meta.language } else { '' }
$limits = Get-EffectiveChunkLimits -Language $lang
$inputInfo = Get-LLMInputText -PlainText $transcript -TranscriptMdPath $mdPath

$est = Get-EstimatedTokens -Text $inputInfo.Text -Language $lang
Write-Host "transcript: $($inputInfo.Text.Length) chars (~$est tokens, lang: $(if ($lang) { $lang } else { '?' }))"
Write-Host "backend: $LlmBackend | model: $summarizerLabel"
if ($inputInfo.HasTimestamps) { Write-Host 'ใช้ transcript ฉบับมี timestamp — สรุปอ้างจุดเวลาได้' }

if ($inputInfo.Text.Length -gt $limits.Threshold) {
    $summary = Invoke-ChunkedSummary -PromptTemplate $promptTpl -InputText $inputInfo.Text `
        -ParagraphMode $inputInfo.HasTimestamps -ChunkSize $limits.ChunkSize `
        -Model $modelToUse -WithTimestamps $inputInfo.HasTimestamps
} else {
    Write-Host 'ส่งให้ LLM สรุป...'
    $summary = Invoke-SingleSummary -PromptTemplate $promptTpl -InputText $inputInfo.Text `
        -Model $modelToUse -WithTimestamps $inputInfo.HasTimestamps
}

# ----- extract title + tags + frontmatter -----
$extracted = Get-SummaryMetadata -Summary $summary

$source = $basename
if ($meta -and $meta.source) { $source = $meta.source }

$frontmatter = Build-Frontmatter -SourceName $source -Meta $meta `
    -Title $extracted.Title -ExtraTags $extracted.Tags -Model $summarizerLabel

$hasTranscriptMd = Test-Path $mdPath
$transcriptLink = if ($hasTranscriptMd) { "> 📝 Full transcript: [[$basename.transcript]]`r`n`r`n" } else { '' }
$fullContent = $frontmatter + $transcriptLink + $extracted.Body + "`r`n"

# ----- write local + additional outputs -----
$localPath = Join-Path $SummaryDir "$basename.md"
Set-Content -Path $localPath -Value $fullContent -Encoding utf8
Write-Host "เขียน: $localPath"

Write-AdditionalOutputs -Outputs $Outputs -Name $basename `
    -FullContent $fullContent -TranscriptMdPath $mdPath -HasTranscriptMd $hasTranscriptMd

if ($extracted.Title) { Write-Host "title: $($extracted.Title)" }
if ($extracted.Tags)  { Write-Host "tags: $($extracted.Tags -join ', ')" }
Write-Host 'เสร็จเรียบร้อย' -ForegroundColor Green
