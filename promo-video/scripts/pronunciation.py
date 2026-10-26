from pathlib import Path
import soundfile as sf
from kokoro_onnx import Kokoro
import onnxruntime as ort
from speech import trimmed

root = Path(__file__).resolve().parents[1]
opts = ort.SessionOptions()
opts.intra_op_num_threads = 4
engine = Kokoro.from_session(
    ort.InferenceSession(str(root / "models/kokoro-v1.0.onnx"), sess_options=opts,
                         providers=["CPUExecutionProvider"]),
    str(root / "models/voices-v1.0.bin"))
out = root / "audio/pronunciation"
out.mkdir(exist_ok=True)
for name, text in [
    ("brand-joined", "Meet Mac Screenshot. A better way to capture what matters."),
    ("brand-pause", "Meet Mac, Screen Shot. A better way to capture what matters."),
    ("privacy", "One permission. No account. No telemetry. Everything you capture stays on your Mac."),
]:
    audio, sr = engine.create(text, voice="af_heart", speed=.90, lang="en-us")
    audio = trimmed(audio, sr)
    sf.write(out / f"{name}.wav", audio, sr, subtype="PCM_24")
    print(name, len(audio) / sr, text, flush=True)
