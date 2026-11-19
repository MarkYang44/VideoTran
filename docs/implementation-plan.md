# VideoTran implementation plan

- [x] Verify caption timing, SRT, PCM segmentation, and bounded prefetch with Swift tests.
- [x] Build an arm64 menu bar app for macOS 15+ with a selectable process tap, floating captions, and on-device Japanese-to-Simplified Chinese translation. Use whisper-cli on macOS 15 and provide the system recognizer as an alternative on macOS 26+.
- [x] Add local MP4/MKV reading via FFmpeg. Translate existing Japanese text subtitles first and otherwise prefetch audio. Render IINA captions against the player's clock and export complete SRT files.
- [x] Build and sign the development app and package the IINA plugin. Test with generated media and report independently whether OS permissions, translation, and real-player synchronization were verified.

## Acceptance

- Apple silicon, macOS 27.0.1. The signed arm64 package targets macOS 15.
- IINA 1.4.4, QuickTime Player, and VLC 3.0.24 each produced live bilingual text from generated Japanese audio.
- An isolated IINA profile exercised the plugin's real bridge and video overlay APIs. A test wrapper invoked the normal menu handler and recorded rendered captions. Pause held the cue, seeks at 2.5, 4.5 and 6.6 seconds selected the expected lines, and a seek to 0.5 seconds cleared them. A no-subtitle MKV with a 2-second audio offset yielded a first cue at 1.98 seconds.
- The App exported two cues from an MP4 with an embedded Japanese text track and preserved the timestamps. Direct translation and QuickTime/VLC live tests retained profanity in the sample. Low-volume IINA live playback missed the first word once while the original audio-track decode recognized it.
- The M1 latency benchmark, real drama/anime accuracy, full-screen visual coverage, multiple displays, and the macOS 15 Whisper runtime remain unverified.
