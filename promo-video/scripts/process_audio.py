from pathlib import Path
import json
import math
import re
import subprocess
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]
FFMPEG = "/opt/homebrew/bin/ffmpeg"
FILTER = ("highpass=f=75,lowpass=f=11000,"
          "equalizer=f=280:t=q:w=1.0:g=-1.2,"
          "equalizer=f=3200:t=q:w=1.0:g=0.6,"
          "deesser=i=0.08:m=0.2:f=0.6,"
          "acompressor=threshold=0.10:ratio=2:attack=12:release=120:makeup=1")

def loudness(stderr):
    match = re.findall(r'\{\s*"input_i".*?\}', stderr, re.S)
    if not match:
        raise RuntimeError(stderr[-3000:])
    return json.loads(match[-1])

def run(args):
    p = subprocess.run([FFMPEG, "-hide_banner", "-nostdin", "-y", *args],
                       capture_output=True, text=True)
    if p.returncode:
        raise RuntimeError(p.stderr)
    return p.stderr

def main():
    (ROOT / "audio/processed").mkdir(exist_ok=True)
    lines = json.loads((ROOT / "evidence/narration.json").read_text())
    timing = []
    start = 0
    for i, item in enumerate(lines):
        source = ROOT / item["path"]
        dest = ROOT / "audio/processed" / source.name
        first = run(["-i", str(source), "-af", FILTER + ",loudnorm=I=-16:TP=-2:LRA=7:print_format=json",
                     "-f", "null", "-"])
        measure = loudness(first)
        norm = (f"loudnorm=I=-16:TP=-2:LRA=7:measured_I={measure['input_i']}:"
                f"measured_TP={measure['input_tp']}:measured_LRA={measure['input_lra']}:"
                f"measured_thresh={measure['input_thresh']}:offset={measure['target_offset']}:"
                "linear=true:print_format=json")
        second = run(["-i", str(source), "-af", FILTER + "," + norm,
                      "-ar", "48000", "-ac", "1", "-c:a", "pcm_s24le", str(dest)])
        (ROOT / "evidence" / f"{source.stem}-processing.txt").write_text(second)
        duration = sf.info(dest).duration
        scene_duration = math.ceil(max(7.0 if i == 9 else 4.5, duration + 1.18) * 10) / 10
        scene_name = item["name"].split("-", 1)[1].capitalize()
        if i == 9:
            scene_name = "CTA"
        # fframes overlap is 19 frames, added to the incoming scene duration.
        scene_start = start - (19 / 60 if i else 0)
        timing.append({"scene": scene_name, "start": scene_start,
                       "voice_start": scene_start + .62, "voice_duration": duration,
                       "duration_contribution": scene_duration, "audio": dest.name,
                       "text": item["text"]})
        start += scene_duration
        print(json.dumps(timing[-1]), flush=True)
    (ROOT / "evidence/scene-timing.json").write_text(json.dumps(timing, indent=2) + "\n")
    rust = "pub const CUES: &[(&str, f32, &str)] = &[\n"
    rust += "".join(f'    ("{s["scene"]}", {s["duration_contribution"]:.1f}, "{s["audio"]}"),\n'
                    for s in timing)
    rust += "];\n"
    (ROOT / "src/timing.rs").write_text(rust)
    (ROOT / "evidence/audio-chain.json").write_text(
        json.dumps({"filters": FILTER, "per_scene_target_lufs": -16, "per_scene_true_peak": -2,
                    "output_sample_rate": 48000, "final_normalization": "post-encode two-pass loudnorm"}, indent=2) + "\n")

if __name__ == "__main__":
    main()
