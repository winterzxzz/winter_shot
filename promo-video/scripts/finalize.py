from pathlib import Path
import json
import re
import subprocess
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
FFMPEG = "/opt/homebrew/bin/ffmpeg"
SOURCE = ROOT / "scratch/fframes-master.mp4"
OUTPUT = ROOT / "final/MacScreenShot-promo.mp4"

def run(command):
    p = subprocess.run(command, capture_output=True, text=True)
    if p.returncode:
        raise RuntimeError(p.stderr)
    return p

def measure(file, target=-16):
    p = run([FFMPEG, "-hide_banner", "-nostdin", "-i", str(file), "-vn",
             "-af", f"loudnorm=I={target}:TP=-1.5:LRA=7:print_format=json", "-f", "null", "-"])
    blocks = re.findall(r'\{\s*"input_i".*?\}', p.stderr, re.S)
    if not blocks:
        raise RuntimeError(p.stderr)
    return json.loads(blocks[-1]), p.stderr

first, first_log = measure(SOURCE)
(ROOT / "evidence/master-loudness.txt").write_text(first_log)
norm = (f"loudnorm=I=-16:TP=-1.5:LRA=7:measured_I={first['input_i']}:"
        f"measured_TP={first['input_tp']}:measured_LRA={first['input_lra']}:"
        f"measured_thresh={first['input_thresh']}:offset={first['target_offset']}:"
        "linear=true:print_format=json")
p = run([FFMPEG, "-hide_banner", "-nostdin", "-y", "-i", str(SOURCE),
         "-map", "0:v:0", "-map", "0:a:0", "-c:v", "copy", "-af", norm,
         "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-movflags", "+faststart",
         "-metadata", "title=MacScreenShot — Your screen. Beautifully told.",
         "-metadata", "comment=Built with fframes; on-device Kokoro narration; MIT app.",
         str(OUTPUT)])
(ROOT / "evidence/final-encode.txt").write_text(p.stderr)
final, final_log = measure(OUTPUT)
(ROOT / "evidence/final-loudness.txt").write_text(final_log)
probe = run(["/opt/homebrew/bin/ffprobe", "-v", "error", "-show_streams", "-show_format",
             "-of", "json", str(OUTPUT)])
meta = json.loads(probe.stdout)
(ROOT / "evidence/final-ffprobe.json").write_text(json.dumps(meta, indent=2) + "\n")
summary = {"integrated_lufs": float(final["input_i"]),
           "true_peak_dbtp": float(final["input_tp"]), "lra_lu": float(final["input_lra"]),
           "duration": float(meta["format"]["duration"]), "bytes": int(meta["format"]["size"]),
           "streams": [{k: s[k] for k in ["codec_name", "codec_type", "width", "height",
                                         "r_frame_rate", "nb_frames", "sample_rate", "channels",
                                         "pix_fmt", "duration"] if k in s}
                       for s in meta["streams"]]}
(ROOT / "evidence/final-metrics.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2), flush=True)
if summary["true_peak_dbtp"] > -1 or abs(summary["integrated_lufs"] + 16) > .7:
    raise RuntimeError("Final AAC loudness target not met")

timing = json.loads((ROOT / "evidence/scene-timing.json").read_text())
frames = ROOT / "scratch/encoded-frames"
frames.mkdir(exist_ok=True)
sheet = Image.new("RGB", (1440, 5 * 447 + 110), "#090811")
draw = ImageDraw.Draw(sheet)
font = ImageFont.truetype(str(ROOT / "media/DMSans-Medium.ttf"), 23)
heading = ImageFont.truetype(str(ROOT / "media/DMSans-Medium.ttf"), 35)
draw.text((28, 20), "MacScreenShot / Your screen. Beautifully told.", font=heading, fill="#F6F3FF")
draw.text((30, 67), f"{summary['duration']:.2f}s  ·  1920 × 1080  ·  60 fps  ·  Final encoded frames",
          font=font, fill="#B5AEC8")
for index, scene in enumerate(timing):
    at = scene["start"] + max(1.5, scene["duration_contribution"] * .55)
    file = frames / f"{index:02d}.png"
    run([FFMPEG, "-hide_banner", "-nostdin", "-y", "-ss", str(at), "-i", str(OUTPUT),
         "-frames:v", "1", "-vf", "scale=704:396", "-update", "1", str(file)])
    x, y = 8 + (index % 2) * 720, 110 + (index // 2) * 447
    sheet.paste(Image.open(file), (x, y))
    draw.text((x + 14, y + 404), f"{index + 1:02d}  {scene['scene']}  /  {at:.2f}s",
              font=font, fill="#B5AEC8")
sheet.save(ROOT / "final/contact-sheet.png")
run([FFMPEG, "-hide_banner", "-nostdin", "-y", "-i", str(OUTPUT), "-vn",
     "-c:a", "pcm_s24le", str(ROOT / "final/voiceover.wav")])
