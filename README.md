# VideoSummary — Auto-summarize Video/Audio to Thai Markdown

ระบบสรุปวิดีโอหรือไฟล์เสียงเป็นภาษาไทยอัตโนมัติบน Windows
**ถอดเสียง (faster-whisper) → สรุปด้วย Claude → ไฟล์ Markdown ใส่ Obsidian/โฟลเดอร์ที่เลือก**

> Drop ไฟล์ในโฟลเดอร์ inbox → ระบบทำงานเอง → ได้ summary `.md` + transcript `.md` พร้อม YAML frontmatter, smart title (aliases) และ auto-tag

## Features

- 🎬 รองรับทั้ง **วิดีโอ** (mp4/mkv/mov/avi/webm/...) และ **เสียง** (mp3/wav/m4a/flac/ogg/...)
- 🧠 ใช้ **faster-whisper large-v3** (GPU CUDA) — เร็วประมาณ 6× realtime บน RTX 3070
- 📝 สรุปด้วย **Claude CLI** (sonnet/opus/haiku) — ใช้ subscription quota ของผู้ใช้ ไม่มีค่า API แยก
- 🎯 **เลือก model ตามความยาว** อัตโนมัติ (haiku/sonnet/opus)
- 📄 **Map-reduce** สำหรับ transcript ยาว (>150k tokens) — แบ่งสรุปทีละส่วนแล้ว merge
- 🏷️ **Smart title + auto-tags** — Claude เสนอชื่อเรื่อง + tag เอง ใส่ใน YAML frontmatter (Obsidian alias/graph)
- 📂 **Multiple output destinations** — เซฟ summary ไปหลาย path พร้อมกัน (local + Obsidian vault + Dropbox + …)
- 🎛️ **Per-video config sidecar** — override model/prompt mode ต่อไฟล์ผ่าน `<name>.config.json`
- 🛡️ **Retry budget + failed folder** — ไฟล์ที่ล้มเหลวเกินจำนวนถูกย้ายไป `failed\` พร้อมเหตุผล
- 🧹 **Auto-cleanup** — done >60 วัน + logs >30 วัน ลบอัตโนมัติ
- 🚦 **Busy-check** — ถ้าเครื่องทำงานหนัก (GPU/CPU/VRAM เกิน threshold) ข้ามรอบ ไม่แย่งทรัพยากร
- 🔔 **Toast notification** เมื่อจบรอบ (BurntToast)

## Prerequisites

- **Windows 10/11** + PowerShell 5.1+
- **Python 3.10+** พร้อม `faster-whisper`: `pip install faster-whisper`
- **NVIDIA GPU** + CUDA (แนะนำ; CPU ก็ทำงานได้แต่ช้ามาก) — แก้ `DEVICE = "cpu"` ใน `transcribe.py`
- **Claude Code CLI** ([install guide](https://docs.claude.com/en/docs/claude-code/quickstart)) + active subscription
- **BurntToast** (optional, สำหรับ toast): `Install-Module BurntToast -Scope CurrentUser`
- **ffmpeg** ใน PATH (faster-whisper เรียกใช้)

## Setup

### 1. Clone

```powershell
git clone https://github.com/<your-user>/VideoSummary.git C:\Coding\VideoSummary
cd C:\Coding\VideoSummary
```

### 2. สร้าง config

```powershell
Copy-Item config.example.json config.json
```

แก้ `config.json`:
- `base` — โฟลเดอร์เก็บข้อมูล (สร้างให้อัตโนมัติ) เช่น `C:\Users\me\VideoSummary`
- `python_exe` — full path ของ `python.exe` ของคุณ
- `outputs` — path ของ Obsidian vault หรือโฟลเดอร์อื่นที่อยากเซฟ summary ด้วย (ใส่ `[]` ถ้าไม่ต้องการ)

### 3. ทดสอบครั้งแรก

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\summarize-videos.ps1
```

จะสร้าง subfolder ใต้ `base` ให้: `inbox\`, `summaries\`, `transcripts\`, `done\`, `failed\`, `logs\`, `state\`

### 4. ใช้งาน

หย่อนไฟล์ลง `<base>\inbox\` แล้วรันคำสั่งข้างบนอีกครั้ง

## Scheduling (Optional)

รันทุกเสาร์-อาทิตย์ 22:30 retry ทุกชั่วโมงถึง 06:30:

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Coding\VideoSummary\summarize-videos.ps1"'

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday,Sunday -At 22:30
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At 22:30 -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Hours 8)).Repetition

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName 'VideoSummary-Weekend' `
    -Action $action -Trigger $trigger -Settings $settings -Description 'Auto video summarization'
```

## Output

ต่อ 1 ไฟล์จะได้:

```
<base>\summaries\<name>.md           # สรุปภาษาไทย (canonical)
<base>\transcripts\<name>.txt        # transcript plain (ใช้ feed Claude)
<base>\transcripts\<name>.transcript.md  # transcript จัด paragraph + timestamp
<base>\transcripts\<name>.meta.json   # duration, language, model
<base>\done\<name>.<ext>              # ไฟล์ต้นฉบับ (auto-delete หลัง 60 วัน)
```

+ ก๊อป summary (และ optional transcript) ไปทุก path ใน `config.outputs`

ตัวอย่างเนื้อหา summary:

```markdown
---
date: 2026-06-14
source: "lecture-001.mp4"
duration: "00:42:18"
language: en
whisper_model: large-v3
summarizer: sonnet
aliases: ["การโน้มน้าวใจและการให้เหตุผล"]
tags: [video-summary, persuasion, lecture, communication]
---

> 📝 Full transcript: [[lecture-001.transcript]]

## หัวข้อเรื่อง
การโน้มน้าวใจและการให้เหตุผล

## ภาพรวม
...
```

## Per-Video Config Override

หย่อน sidecar `<name>.config.json` ใน inbox คู่กับไฟล์:

```json
{
  "model": "opus",
  "mode": "meeting"
}
```

หรือ prompt เอง:

```json
{
  "prompt": "สรุปสั้น 3 ประโยค ไม่ต้องมี bullet"
}
```

Mode ที่มีให้: `default`, `lecture`, `meeting`

## Re-summarize

อยากเปลี่ยน prompt/model แล้วลองใหม่ — ไม่ต้องถอดเสียงใหม่:

```powershell
.\resummarize.ps1 "Recording 2026-06-13 215814"
.\resummarize.ps1 "Recording 2026-06-13 215814" -Model opus
.\resummarize.ps1 "Recording 2026-06-13 215814" -Mode lecture
.\resummarize.ps1 "Recording 2026-06-13 215814" -Prompt "สรุปสั้น 3 ประโยค"
```

## เปลี่ยน LLM Backend

แก้ `config.json` แค่ 1-2 บรรทัด ไม่ต้องแตะโค้ด:

**Claude** (default — ใช้ Claude CLI + subscription):
```json
"llm_backend": "claude",
"claude_model": "sonnet"
```

**Gemini** (ฟรี — ต้องมี API key จาก [aistudio.google.com/apikey](https://aistudio.google.com/apikey)):
```json
"llm_backend": "gemini",
"gemini_api_key": "AIza...",
"gemini_model": "gemini-2.0-flash"
```

**OpenAI** (ใช้ API key จาก [platform.openai.com](https://platform.openai.com)):
```json
"llm_backend": "openai",
"openai_api_key": "sk-...",
"openai_model": "gpt-4o-mini"
```

> `openai_base_url` เปลี่ยนได้ — รองรับ provider ที่ใช้ OpenAI format เช่น Groq (`https://api.groq.com/openai/v1`)

## Configuration Reference

ดู [`config.example.json`](config.example.json) — comments อธิบายทุก key

| Key | Default | Description |
|---|---|---|
| `base` | (required) | โฟลเดอร์เก็บ data |
| `python_exe` | `"python"` | path ของ python.exe |
| `llm_backend` | `"claude"` | backend สรุป: `claude` / `gemini` / `openai` |
| `gemini_api_key` | `""` | API key สำหรับ Gemini |
| `gemini_model` | `"gemini-2.0-flash"` | Gemini model |
| `openai_api_key` | `""` | API key สำหรับ OpenAI |
| `openai_model` | `"gpt-4o-mini"` | OpenAI model |
| `openai_base_url` | `"https://api.openai.com/v1"` | endpoint (เปลี่ยนเพื่อใช้ Groq ฯลฯ) |
| `claude_model` | `"sonnet"` | Claude model (ใช้ตอน backend = claude) |
| `enable_model_tier` | `true` | เลือก Claude model จาก duration อัตโนมัติ |
| `outputs` | `[]` | array ของ output destinations |
| `retention.done_days` | `60` | ลบไฟล์ใน done\ เก่ากว่า |
| `retention.logs_days` | `30` | ลบ log เก่ากว่า |
| `retry.max_failed_attempts` | `3` | ล้มเหลวเกินนี้ย้าย failed\ |
| `busy_check.*` | — | thresholds GPU/CPU/VRAM |
| `chunk_threshold_chars` | `600000` | transcript ใหญ่กว่านี้ใช้ map-reduce |
| `file_in_use_grace_sec` | `60` | ข้ามไฟล์ที่ถูกแก้ภายใน N วินาที |

config สามารถระบุที่อยู่ได้ 3 ทาง (ลำดับ priority):
1. `-ConfigPath <path>` — argument
2. `$env:VIDEOSUMMARY_CONFIG` — environment variable
3. `<script_dir>\config.json` — default

## Whisper Tweaks

แก้ใน [`transcribe.py`](transcribe.py):
- `MODEL_SIZE` — `large-v3` (แม่นสุด) / `medium` / `small` (เร็วขึ้น)
- `DEVICE` — `cuda` / `cpu`
- `COMPUTE_TYPE` — `float16` / `int8_float16` (เร็วขึ้น 30%) / `int8`
- `USE_VAD` — ข้ามช่วงเงียบ
- `PARAGRAPH_GAP_SEC` — เงียบกี่วินาทีตัด paragraph ใน transcript.md

## Folder Layout

```
C:\Coding\VideoSummary\        # repo (code)
  ├─ summarize-videos.ps1
  ├─ resummarize.ps1
  ├─ transcribe.py
  ├─ config.example.json      # template (committed)
  ├─ config.json              # ของคุณ (gitignored)
  ├─ .gitignore
  └─ README.md

<config.base>\                  # data (ไม่ขึ้น Git)
  ├─ inbox\                    # หย่อนไฟล์ที่นี่
  ├─ summaries\                # ผลลัพธ์ canonical
  ├─ transcripts\              # raw + formatted
  ├─ done\                     # ไฟล์ที่ทำเสร็จ
  ├─ failed\                   # ไฟล์ที่ล้มเหลวเกิน budget
  ├─ logs\                     # log ต่อรอบ
  └─ state\                    # attempt counter + lock
```

## Troubleshooting

**toast ไม่ขึ้น** → `Install-Module BurntToast -Scope CurrentUser`

**ไฟล์ใน `failed\`** → ดู `<name>.reason.txt` ในโฟลเดอร์เดียวกัน แก้แล้วย้ายกลับ `inbox\` + ลบ `state\<name>.attempts`

**`state\.running` ค้าง** → ปกติลบอัตโนมัติเมื่อจบรอบ ถ้า script crash จะถือว่าเก่าเกิน 6 ชม. และ override

**Thai เพี้ยน / parse error** → ตรวจ encoding ทุก `.ps1` ต้องเป็น **UTF-8 with BOM** (PowerShell 5.1 อ่าน UTF-8 ไม่มี BOM เป็น Windows-1252)

**Whisper ช้า** → ตั้ง `COMPUTE_TYPE = "int8_float16"` ใน `transcribe.py` หรือลด `MODEL_SIZE` เป็น `medium`

## Notes

- ระบบสรุปจาก **เสียงพูด** เท่านั้น — ไม่มี frame analysis
- ทุก `.ps1` ต้องเป็น **UTF-8 with BOM** (Thai ไม่งั้นเพี้ยน)
- ใช้โควต้า Claude subscription ของผู้ใช้ — ไม่มีค่า API แยก
