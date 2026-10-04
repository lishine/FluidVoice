# Dictation startup timing

`dictation-timing.swift` checks a real recording and insertion in a disposable native
text field. It plays the existing developer fixture through the Mac speakers into the
selected microphone. Close other recording overlays and keep the Mac quiet.

Build the helper as an app bundle so macOS can retain its screen-capture/input access:

```sh
mkdir -p /tmp/DictationTiming.app/Contents/MacOS
cat > /tmp/DictationTiming.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.devpark.DictationTiming</string>
<key>CFBundleName</key><string>DictationTiming</string>
<key>CFBundleExecutable</key><string>DictationTiming</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
swiftc -O -parse-as-library tools/dictation-timing.swift \
  -o /tmp/DictationTiming.app/Contents/MacOS/DictationTiming
open --env FLUID_DICTATION_TIMING=1 /Applications/FluidVoice.app
/tmp/DictationTiming.app/Contents/MacOS/DictationTiming /tmp/fluid-visible.png \
  "$PWD/Tests/FluidDictationIntegrationTests/Resources/dictation_fixture.wav"
```

Use FluidVoice's Right Option hold shortcut, AI formatting off, and the model you
intend to measure. Grant the helper's Screen Recording and input-control access when
macOS asks. The installed FluidVoice build also needs its own existing Microphone and
Accessibility permissions; local signing changes can invalidate those permissions even
when Settings displays the switch as enabled. Launch FluidVoice using `open`, rather
than running its executable inside Terminal. Require actual focus-capture and insertion
success before accepting a result.

Output JSON contains key-posted monotonic time, first observed recording pixels,
window detection, Stop-to-text-change and fixture acceptance. Capture samples at 60 fps
on a private queue so measurement does not block the field's Accessibility responder.
Only FluidVoice's small windows in the display's bottom crop are captured. Inspect the
saved PNG to confirm it is the recording overlay. Results include synthetic-event
scheduling and screen-capture delivery; they do not measure physical key hardware or
the first microphone buffer. `audio-ready` means the audio engine/tap are ready.

Add `--stall-focus` as the third argument to make the disposable field's main thread
busy for two seconds just after key-down. This deliberately exercises slow focus
capture. In this mode use `visiblePixelSeconds`: `windowSeconds` is delayed by the
helper's main-thread stall and cannot measure appearance. Compare unmodified and
modified builds with the same compiler, flags, signature and permissions. Clear the
field on exit; no text is sent to another app or service by the helper.
