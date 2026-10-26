# MacScreenShot promo, peer handoff

Rendered and self-checked on 2026-10-26. Lead acceptance is still required.
Beads issue `psf796356c0d-4wo` remains in progress and must not be closed by this peer.

## Deliverables

Base: `/Users/winterzxzz/Documents/Local/AppMobiles/winter_shot/promo-video/`

| Artifact | Path |
|---|---|
| Final video | `final/MacScreenShot-promo.mp4` |
| Narration script | `final/voiceover.txt` |
| Final encoded-frame contact sheet | `final/contact-sheet.png` |
| Final decoded narration/mix WAV | `final/voiceover.wav` |
| fframes project | `Cargo.toml`, `Cargo.lock`, `src/`, `media/` |
| Design brief | `DESIGN.md` |
| Voice comparison | `evidence/voice-selection.md`, `audio/candidates/` |
| Reproduction instructions | `README.md` |

## Picture and sound

- Video: **1920×1080, 60 fps, H.264, yuv420p, 3,606 frames, 60.100 seconds**.
- Container: **60.116 seconds**, 17,067,152 bytes. AAC padding explains the small duration difference.
- Audio: AAC, 48 kHz, stereo, 192 kb/s requested.
- Final decoded AAC: **−16.00 LUFS integrated**, **−4.77 dBTP true peak**, **3.10 LU loudness range**.
- Original voice-only treatment. No music or sound-effect licensing dependencies.
- Final video is fast-start MP4. Visuals were rendered by fframes/Skia Metal; FFmpeg copied
  the H.264 stream without recompression while mastering and muxing the final AAC.

## Narration

Meet Mac Screen Shot. A better way to capture what matters.

Press Command Shift Four. Your screen freezes. Click a window, or drag an area.

Make your point with nine annotation tools. Every edit stays editable.

Add a gradient, rounded corners, and a soft shadow. Ready to share.

Record your display, a window, or just the area you need.

Then shape your take in the optional studio editor. Auto zoom. A smooth synthetic cursor.

Beautiful backdrops. And sixty frames per second export.

Your screenshots and recordings, together. Right in your library and notch history.

One permission. No account. No telemetry. Everything you capture stays on your Mac.

Free. Open source. Yours. Download Mac Screen Shot on GitHub.

## Voice choice and processing

**Kokoro-82M v1.0**, full-precision ONNX, **kokoro-onnx 0.6.1**, stock US-English
female voice **af_heart**, final speed **0.90**. CPU inference on this Mac, no cloud TTS.
Raw synthesis: 24 kHz, mono, saved as 24-bit PCM.

Three voices synthesized the same short line at speed 0.94:

| Voice | Duration | Raw peak | Clipped samples | Published voice-data grade |
|---|---:|---:|---:|---|
| af_heart, selected | 7.275 s | −6.85 dBFS | 0 | A |
| af_bella | 7.402 s | −3.81 dBFS | 0 | A− |
| am_michael | 7.721 s | −7.55 dBFS | 0 | C+ |

Heart was selected for its stronger documented voice-data quality, clean headroom and
verified test-line coverage, not because the agent could listen to and rank the samples.
Bella was a credible alternate female voice; Michael provided a slower male alternative.
The 0.90 final pass gives more deliberate pacing. These model-card grades are not listening
scores. macOS basic `say` and unverified OmniVoice/Kitten caches were considered but not used.

Processing, applied separately to each scene:

1. Trim only outer silence at a −48 dB amplitude threshold, preserving 70 ms before and
   140 ms after detected signal; 6 ms de-click fades. Internal model pauses retained.
2. High-pass 75 Hz, low-pass 11 kHz; EQ −1.2 dB at 280 Hz and +0.6 dB at 3.2 kHz.
3. Light FFmpeg de-esser: intensity 0.08, maximum 0.2, frequency parameter 0.6.
4. Compression: threshold 0.10, ratio 2:1, attack 12 ms, release 120 ms.
5. Per-line two-pass loudness normalization; processed PCM at 48 kHz.
6. Scene-relative placement at 0.62 seconds, paced from measured line durations.
7. Final two-pass mastering to −16 LUFS, followed by AAC decode/re-measurement.

Exact filters: `evidence/audio-chain.json`. All generations, raw and processed WAVs, timings,
transcripts and sample comparisons remain inside the project.

## Personally observed validation

- `cargo build --release` passed using fframes 1.3.0 and Rust 1.99.0.
- Initial generated fframes 1.2 build failed because a transitive media 1.3 dependency used
  a different SVG type. Aligning the fframes crates to 1.3.0 fixed it.
- `inspect --fail-on warning`: **260 sampled frames, zero findings**.
- Full-size annotation/studio/CTA frames and all ten six-frame motion strips inspected.
- Opening transition strip inspected; no empty or flashing handoff.
- Contact sheet extracted from the final encoded MP4 inspected, all ten scenes present.
- fframes audio: no missing tracks, zero clipped samples; scene loudness within **0.36 LU**.
- FFmpeg decoded the entire final MP4 successfully, empty error log.
- ffprobe confirmed H.264/AAC, dimensions, fps, frame count and durations.
- Local faster-whisper base/int8 checked every processed line and the final decoded AAC.
  All intended content was recovered aside from product-name spelling and Right/Write.
- Eight approved source image hashes still match their inputs.
- No test suite was created or run, per the fframes skill. No native preview was launched;
  its complete command was offered to Human.

Evidence: `evidence/{inspect.json,timeline.json,fframes-audio.json,final-metrics.json,
final-ffprobe.json,final-loudness.txt,decode-check.log,narration-asr.json,final-asr.json,
visual-review.md}` and `evidence/motion-*.png`.

## Installed tools and locations

- New isolated Python environment: `promo-video/.venv/`.
  kokoro-onnx 0.6.1, ONNX Runtime 1.31.0, faster-whisper 1.2.1, CTranslate2 4.8.4,
  bundled espeakng-loader 0.2.4, SoundFile, NumPy, SciPy, Pillow and dependencies.
  Exact inventory: `evidence/python-packages.txt`.
- Kokoro model/voice weights: `promo-video/models/`, approximately 354 MB.
  URLs and SHA-256 values: `models/sources.json`.
- fframes 1.3 Rust dependencies fetched through Cargo into the existing user Cargo cache,
  `/Users/winterzxzz/.cargo/registry/`; compiled video binary/build output in
  `promo-video/target/`. `CARGO_TARGET_DIR` explicitly set there and pinned in
  `.cargo/config.toml`.
- Python dependency cache: `promo-video/.cache/uv/`.
- Reused, not newly installed: cargo-fframes, Rust, uv, Homebrew FFmpeg/ffprobe 8.1,
  existing uv CPython 3.11.15 and cached faster-whisper-base weights.
- No Homebrew/system-wide installs. No paid/account service. No uploads or publishing.

## Unknowns and residual risk

- **Human listening remains necessary.** This interface does not provide auditory
  perception. Naturalness, warmth and subtle synthetic artifacts were not personally heard.
- Whisper repeatedly spells the brand as “Max Green Shot” or “Max Greenshot.” Two alternate
  text/pause variants did not fix its spelling. The spoken source remains “Mac Screen Shot.”
  Brand pronunciation should be checked by a listener; ASR spelling alone is inconclusive.
- “Right” is transcribed as its homophone “Write” in the history sentence.
- These are animated supplied screenshots, not live interaction recordings. The supplied
  selector came from a current-source harness; the studio image uses staged demo content.
- “On-device” and privacy language concern capture processing. The app can check GitHub
  for updates, as disclosed in the refreshed README.
- No app behavior was tested. The running MacScreenShot app was never touched or quit.

## Ownership

Only `promo-video/` contains this peer's new repository work. Existing README/docs changes
were preserved. No commits. No other agent was created or managed. No acceptance claimed.
The issue stays assigned and open for Lead review; this peer stops at handoff.
