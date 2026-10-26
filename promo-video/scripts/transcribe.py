from pathlib import Path
import argparse
import json
from faster_whisper import WhisperModel

ROOT = Path(__file__).resolve().parents[1]
CACHED = Path("/Users/winterzxzz/.cache/huggingface/hub/models--Systran--faster-whisper-base/"
              "snapshots/ebe41f70d5b6dfa9166e2c581c45c9c0cfc57b66")
parser = argparse.ArgumentParser()
parser.add_argument("folder")
parser.add_argument("report")
args = parser.parse_args()
model = WhisperModel(str(CACHED), device="cpu", compute_type="int8", cpu_threads=4,
                     local_files_only=True)
out = []
for file in sorted((ROOT / args.folder).glob("*.wav")):
    segments, info = model.transcribe(str(file), language="en", beam_size=5,
                                      word_timestamps=True, vad_filter=False,
                                      condition_on_previous_text=False)
    segments = list(segments)
    item = {"file": str(file.relative_to(ROOT)), "duration": info.duration,
            "text": "".join(s.text for s in segments).strip(),
            "segments": [{"start": s.start, "end": s.end, "text": s.text,
                          "words": [{"word": w.word, "start": w.start, "end": w.end,
                                     "probability": w.probability} for w in s.words]}
                         for s in segments]}
    print(json.dumps(item), flush=True)
    out.append(item)
(ROOT / args.report).write_text(json.dumps(out, indent=2) + "\n")
