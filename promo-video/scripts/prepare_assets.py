from pathlib import Path
from PIL import Image
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT.parent / "docs/assets"
MEDIA = ROOT / "media"
for directory in ["audio/raw", "audio/candidates", "evidence", "final", "scratch"]:
    (ROOT / directory).mkdir(parents=True, exist_ok=True)
receipt = []
for name in ["selector", "editor", "beautify", "studio", "preview", "notch", "hud"]:
    src = SOURCE / f"{name}.png"
    shutil.copy2(src, MEDIA / src.name)
    receipt.append({"source": str(src.relative_to(ROOT.parent)),
                    "sha256": hashlib.sha256(src.read_bytes()).hexdigest()})
icon = ROOT.parent / "MacScreenShot/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
shutil.copy2(icon, MEDIA / "app-icon.png")
receipt.append({"source": str(icon.relative_to(ROOT.parent)),
                "sha256": hashlib.sha256(icon.read_bytes()).hexdigest()})
crops = {
    "editor-tools.png": ("editor", (545, 86, 1760, 174)),
    "editor-detail.png": ("editor", (620, 264, 1960, 738)),
    "beauty-canvas.png": ("beautify", (363, 192, 1968, 1240)),
    "studio-canvas.png": ("studio", (121, 181, 1240, 943)),
    "studio-timeline.png": ("studio", (15, 1030, 1985, 1245)),
    "studio-controls.png": ("studio", (1430, 110, 1985, 1020)),
}
for dest, (name, box) in crops.items():
    Image.open(SOURCE / f"{name}.png").crop(box).save(MEDIA / dest)
(ROOT / "evidence/assets.json").write_text(json.dumps(receipt, indent=2) + "\n")
