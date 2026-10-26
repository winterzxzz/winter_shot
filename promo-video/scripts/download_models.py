from pathlib import Path
from urllib.request import urlretrieve
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
out = ROOT / "models"
out.mkdir(exist_ok=True)
base = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/"
receipts = []
for name in ["kokoro-v1.0.onnx", "voices-v1.0.bin"]:
    dest = out / name
    url = base + name
    if not dest.exists():
        print(f"Downloading {name}", flush=True)
        urlretrieve(url, dest)
    receipts.append({"file": name, "url": url, "bytes": dest.stat().st_size,
                     "sha256": hashlib.sha256(dest.read_bytes()).hexdigest()})
    print(receipts[-1], flush=True)
(out / "sources.json").write_text(json.dumps(receipts, indent=2) + "\n")
