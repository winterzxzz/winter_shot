# MacScreenShot promo

An original 1920×1080, 60 fps product film built with fframes 1.3 and Skia/Metal.
See `DESIGN.md` for art direction and source qualifications, and `final/HANDOFF.md`
for final evidence and audio settings.

## Reproduce

Use this directory as the working directory. Every Cargo command must set:

```sh
export PATH="/Users/winterzxzz/.cargo/bin:$PATH"
export CARGO_TARGET_DIR="/Users/winterzxzz/Documents/Local/AppMobiles/winter_shot/promo-video/target"
```

The same target is pinned in `.cargo/config.toml`. Python tools are isolated in `.venv/`.

```sh
.venv/bin/python scripts/prepare_assets.py
.venv/bin/python scripts/download_models.py
.venv/bin/python scripts/speech.py candidates
.venv/bin/python scripts/transcribe.py audio/candidates evidence/candidates-asr.json
.venv/bin/python scripts/speech.py narration
.venv/bin/python scripts/process_audio.py
.venv/bin/python scripts/transcribe.py audio/processed evidence/narration-asr.json
cargo build --release
cargo run --release -- timeline
cargo run --release -- inspect --fail-on warning
cargo run --release -- strip -n 20 -o evidence/overview.png
cargo run --release -- frame Hook@2s,Studio@3s,CTA@3s
cargo run --release -- preview 0s
cargo run --release -- render -o scratch/fframes-master.mp4
.venv/bin/python scripts/finalize.py
.venv/bin/python scripts/transcribe.py final evidence/final-asr.json
```

`src/lib.rs` owns the scenes, camera moves, typography and scene-relative voice placement.
`src/timing.rs` is generated from measured per-scene narration duration.
`media/` holds copies and crops of only the approved current screenshots, plus the app icon
and the generator's bundled DM Sans font. Audio is loaded at runtime from `audio/processed/`.

No unit or snapshot tests are used. Validation is fframes inspection, rendered frames and
contact sheets, FFmpeg audio measurement, ffprobe, and local Whisper transcription.

No music, no cloud speech, no publishing, and no interactions with the running app.
