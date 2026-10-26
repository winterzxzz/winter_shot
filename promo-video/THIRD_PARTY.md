# Asset and tool provenance

- Product UI and app icon: supplied MacScreenShot repository assets, MIT-licensed app.
  Used only approved current screenshots, never old demo.gif/demo.mp4/demo-poster.png.
  Exact source hashes: `evidence/assets.json`.
- DM Sans Medium: bundled by the fframes generator; SIL Open Font License 1.1,
  copyright DM Sans Project Authors. Full notice: `licenses/DM-Sans-OFL.txt`.
- Kokoro-82M v1.0: Apache-2.0 open weights, model by hexgrad;
  https://huggingface.co/hexgrad/Kokoro-82M .
  ONNX distribution: https://github.com/thewh1teagle/kokoro-onnx .
  Exact downloaded URLs/hashes: `models/sources.json`.
- kokoro-onnx: MIT software; local ONNX Runtime CPU inference only.
- fframes, Skia, FFmpeg and their dependencies are rendering tools, not music assets.
  Cargo.lock and `evidence/python-packages.txt` identify the installed versions.
- Local Whisper base: pre-existing cached Systran/faster-whisper-base weights, used for
  verification only. No audio or source files were uploaded.
- No music, stock footage, cloud speech service, voice cloning, or third-party sound effects.
