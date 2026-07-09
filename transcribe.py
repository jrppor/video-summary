"""
ถอดเสียงวิดีโอเป็นไฟล์ข้อความ ด้วย faster-whisper

ใช้งาน:
  python transcribe.py <video1> <output_txt1> [<video2> <output_txt2> ...]
  รับเป็นคู่ ๆ — โหลดโมเดลครั้งเดียวสำหรับทุกไฟล์ในรอบ batch

คุณสมบัติ:
  - Atomic write: เขียนเป็น .tmp ก่อน แล้ว rename เมื่อเสร็จ (ป้องกัน partial file)
  - สร้าง 3 ไฟล์ต่อ 1 วิดีโอ:
      <name>.txt              ข้อความ plain (ใช้ feed เข้า Claude)
      <name>.transcript.md    Markdown มี frontmatter + timestamps + paragraphs (สำหรับ Obsidian)
      <name>.meta.json        metadata (duration, language ฯลฯ)
  - Per-file isolation: ถ้าไฟล์หนึ่งล้มเหลว ไฟล์อื่นยังถูกประมวลผลต่อ
  - Exit code 0 ถ้าสำเร็จทุกไฟล์, 1 ถ้ามีไฟล์ใดล้มเหลว
"""
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from faster_whisper import WhisperModel

# บังคับให้ stdout/stderr ใช้ UTF-8 เพื่อให้แสดงภาษาไทยถูกต้องเวลาเขียน log
sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# ===================== การตั้งค่า (แก้ได้) =====================
MODEL_SIZE        = "large-v3"
DEVICE            = "cuda"            # "cuda" = ใช้ GPU / "cpu" = ใช้ CPU
COMPUTE_TYPE      = "float16"         # ทางเลือก: "int8_float16" เร็วขึ้น ~30% / VRAM ลดลงครึ่งหนึ่ง / ความแม่นใกล้เคียง
BEAM_SIZE         = 5
USE_VAD           = True              # ข้ามช่วงเงียบในวิดีโอ — เร่งความเร็วได้มาก
CONDITION_ON_PREV = False             # False = กันอาการหลอนวนซ้ำประโยคเดิมในไฟล์ยาว (คุ้มกว่าบริบทต่อเนื่องเล็กน้อยที่เสียไป)
PARAGRAPH_GAP_SEC = 2.5               # ตัด paragraph ใหม่เมื่อช่วงเงียบระหว่าง segment > วินาทีนี้
# ==============================================================


def format_duration(seconds: float) -> str:
    """แปลงวินาทีเป็น HH:MM:SS"""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def atomic_write(path: Path, content: str) -> None:
    """เขียนเป็น .tmp แล้ว rename — ป้องกัน partial file"""
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, path)


def build_transcript_markdown(all_segments, info, source_name: str) -> str:
    """สร้าง Markdown ฉบับฟอร์แมต — frontmatter + timestamp + paragraphs"""
    # group consecutive segments into paragraphs based on silence gap
    paragraphs = []
    current = None
    prev_end = 0.0
    for seg in all_segments:
        text = seg.text.strip()
        if not text:
            continue
        gap = seg.start - prev_end
        if current is None or gap > PARAGRAPH_GAP_SEC:
            if current is not None:
                paragraphs.append(current)
            current = {"start": seg.start, "texts": [text]}
        else:
            current["texts"].append(text)
        prev_end = seg.end
    if current is not None:
        paragraphs.append(current)

    # frontmatter + body
    source_stem = Path(source_name).stem
    source_escaped = source_name.replace('"', '\\"')
    lines = [
        "---",
        f"date: {datetime.now().strftime('%Y-%m-%d')}",
        f'source: "{source_escaped}"',
        f'duration: "{format_duration(info.duration)}"',
        f"language: {info.language}",
        f"model: {MODEL_SIZE}",
        "type: transcript",
        "tags: [video-transcript]",
        "---",
        "",
        f"> 📋 Summary: [[{source_stem}]]",
        "",
    ]
    for p in paragraphs:
        ts = format_duration(p["start"])
        body = " ".join(p["texts"])
        lines.append(f"**[{ts}]**  {body}")
        lines.append("")
    return "\n".join(lines)


def transcribe_one(model: WhisperModel, input_path: Path, output_path: Path) -> bool:
    """ถอดเสียงไฟล์เดียว — return True ถ้าสำเร็จ"""
    if not input_path.exists():
        print(f"  FAIL: ไม่พบไฟล์ input: {input_path}", file=sys.stderr)
        return False

    # paths
    tmp_path = output_path.with_suffix(output_path.suffix + ".tmp")
    meta_path = output_path.with_suffix(".meta.json")
    md_path = output_path.with_name(output_path.stem + ".transcript.md")

    try:
        print(f"--- เริ่มถอดเสียง: {input_path.name}", file=sys.stderr)
        segments, info = model.transcribe(
            str(input_path),
            beam_size=BEAM_SIZE,
            vad_filter=USE_VAD,
            vad_parameters=dict(min_silence_duration_ms=500) if USE_VAD else None,
            condition_on_previous_text=CONDITION_ON_PREV,
        )
        print(
            f"  ภาษา: {info.language} "
            f"(confidence {info.language_probability:.2f}, "
            f"duration {info.duration:.1f}s)",
            file=sys.stderr,
        )

        output_path.parent.mkdir(parents=True, exist_ok=True)
        all_segments = []
        count = 0
        # เขียน .txt แบบ atomic + เก็บ segments ไว้สร้าง .transcript.md
        with tmp_path.open("w", encoding="utf-8") as f:
            for seg in segments:
                all_segments.append(seg)
                text = seg.text.strip()
                if text:
                    f.write(text + "\n")
                    count += 1
                if count and count % 50 == 0:
                    print(f"  ...{count} segments, ถึงเวลา {seg.end:.0f}s", file=sys.stderr)
        os.replace(tmp_path, output_path)

        # สร้าง formatted transcript markdown (atomic)
        md_content = build_transcript_markdown(all_segments, info, input_path.name)
        atomic_write(md_path, md_content)

        # sidecar metadata
        meta = {
            "source": input_path.name,
            "duration_seconds": round(info.duration, 1),
            "duration_hms": format_duration(info.duration),
            "language": info.language,
            "language_probability": round(info.language_probability, 3),
            "model": MODEL_SIZE,
            "compute_type": COMPUTE_TYPE,
            "segments": count,
        }
        meta_path.write_text(
            json.dumps(meta, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

        print(f"  OK: {count} segments → {output_path.name} + {md_path.name}", file=sys.stderr)
        return True

    except Exception as e:
        print(f"  FAIL: {input_path.name}: {e}", file=sys.stderr)
        # ล้าง .tmp ทั้งของ .txt และ .transcript.md (ถ้ามี) เพื่อไม่ให้รบกวนรอบถัดไป
        for p in (tmp_path, md_path.with_suffix(md_path.suffix + ".tmp")):
            if p.exists():
                try:
                    p.unlink()
                except OSError:
                    pass
        return False


def main() -> int:
    args = sys.argv[1:]
    if len(args) < 2 or len(args) % 2 != 0:
        print(
            "Usage: python transcribe.py <video1> <output_txt1> "
            "[<video2> <output_txt2> ...]",
            file=sys.stderr,
        )
        return 2

    pairs = [(Path(args[i]), Path(args[i + 1])) for i in range(0, len(args), 2)]

    print(
        f"โหลดโมเดล {MODEL_SIZE} ({DEVICE}, {COMPUTE_TYPE}) สำหรับ {len(pairs)} ไฟล์...",
        file=sys.stderr,
    )
    model = WhisperModel(MODEL_SIZE, device=DEVICE, compute_type=COMPUTE_TYPE)

    failed = 0
    for input_path, output_path in pairs:
        if not transcribe_one(model, input_path, output_path):
            failed += 1

    total = len(pairs)
    print(
        f"\nสรุป batch: สำเร็จ {total - failed} / ล้มเหลว {failed}",
        file=sys.stderr,
    )
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
