from pathlib import Path
import argparse
import json
import time
import numpy as np
import soundfile as sf
from kokoro_onnx import Kokoro
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[1]
SAMPLE = ("Meet Mac Screen Shot. A better way to capture what matters. "
          "Press Command Shift Four, and make every detail clear.")
LINES = [
    ("Hook", "Meet Mac Screen Shot. A better way to capture what matters."),
    ("Capture", "Press Command Shift Four. Your screen freezes. Click a window, or drag an area."),
    ("Annotate", "Make your point with nine annotation tools. Every edit stays editable."),
    ("Beautify", "Add a gradient, rounded corners, and a soft shadow. Ready to share."),
    ("Record", "Record your display, a window, or just the area you need."),
    ("Studio", "Then shape your take in the optional studio editor. Auto zoom. A smooth synthetic cursor."),
    ("Export", "Beautiful backdrops. And sixty frames per second export."),
    ("History", "Your screenshots and recordings, together. Right in your library and notch history."),
    ("Privacy", "One permission. No account. No telemetry. Everything you capture stays on your Mac."),
    ("CTA", "Free. Open source. Yours. Download Mac Screen Shot on GitHub."),
]

def trimmed(audio, sr):
    # Preserve consonant tails and natural internal pauses.
    active = np.flatnonzero(np.abs(audio) > 10 ** (-48 / 20))
    if not len(active):
        raise RuntimeError("Silent synthesis")
    start = max(0, active[0] - int(sr * .07))
    end = min(len(audio), active[-1] + int(sr * .14))
    data = audio[start:end].copy()
    fade = min(int(sr * .006), len(data) // 4)
    data[:fade] *= np.linspace(0, 1, fade)
    data[-fade:] *= np.linspace(1, 0, fade)
    return data

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["candidates", "narration"])
    args = parser.parse_args()
    opts = ort.SessionOptions()
    opts.intra_op_num_threads = 4
    opts.inter_op_num_threads = 1
    session = ort.InferenceSession(str(ROOT / "models/kokoro-v1.0.onnx"),
                                  sess_options=opts, providers=["CPUExecutionProvider"])
    engine = Kokoro.from_session(session, str(ROOT / "models/voices-v1.0.bin"))
    tasks = ([(v, SAMPLE, v, "audio/candidates") for v in ["af_heart", "af_bella", "am_michael"]]
             if args.mode == "candidates" else
             [(f"{i:02d}-{scene.lower()}", text, "af_heart", "audio/raw")
              for i, (scene, text) in enumerate(LINES)])
    receipt = []
    speed = .94 if args.mode == "candidates" else .90
    for name, text, voice, folder in tasks:
        start = time.monotonic()
        samples, sr = engine.create(text, voice=voice, speed=speed, lang="en-us")
        samples = trimmed(samples, sr)
        dest = ROOT / folder / f"{name}.wav"
        dest.parent.mkdir(parents=True, exist_ok=True)
        sf.write(dest, samples, sr, subtype="PCM_24")
        item = {"name": name, "text": text, "voice": voice, "speed": speed,
                "sample_rate": sr, "duration": len(samples) / sr,
                "peak_dbfs": float(20 * np.log10(max(1e-10, np.max(np.abs(samples))))),
                "clipped_samples": int(np.sum(np.abs(samples) >= 1)),
                "synthesis_seconds": round(time.monotonic() - start, 2),
                "path": str(dest.relative_to(ROOT))}
        receipt.append(item)
        print(json.dumps(item), flush=True)
    (ROOT / f"evidence/{args.mode}.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if args.mode == "narration":
        (ROOT / "final/voiceover.txt").write_text(
            "\n\n".join(text for _, text in LINES) + "\n")

if __name__ == "__main__":
    main()
