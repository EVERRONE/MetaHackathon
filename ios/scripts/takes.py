#!/usr/bin/env python3
"""Puts the demo video's takes together on the Mac.

Pip records each take on the iPhone (settings, "Demo video", "Record takes for the video"): its
screen (screen.mov, HEVC, up to 30 fps), its voice as it was played (pip.caf, digital), the
microphone after voice processing (mic.caf: the user, without Pip's voice) and take.json (how they
line up, and what was said and shown when). All three start at the take's first frame.

  python3 scripts/takes.py pull [folder]
      Copies every take from the iPhone (default: ~/Movies/Pip takes). The takes show the home:
      they never go into the repository.
  python3 scripts/takes.py build <take folder>...
      Per take: <take>.mp4 (the screen at a steady 30 fps with both voices), <take>-pip.wav and
      <take>-you.wav (each voice alone, lined up, levelled), <take>-pip.srt and <take>-you.srt
      (subtitles from what was said, timed on the voices) and <take>-timeline.txt.
  python3 scripts/takes.py sync <take folder> <camera clip> [--write]
      Finds where a second camera's clip lies on the take, by its sound (both voices, heard in the
      room), and keeps it in the take's sync.json; --write also makes <clip>-synced.mp4, which
      starts with the take.

Needs ffmpeg and ffprobe, and Xcode's devicectl for pull.
"""
import array
import cmath
import json
import math
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

DEVICE = os.environ.get("PIP_DEVICE", "00008130-000161E43450001C")
BUNDLE = os.environ.get("PIP_BUNDLE", "be.unveil.pip.dev")
DEFAULT_FOLDER = Path.home() / "Movies" / "Pip takes"
# Each voice is brought to this loudness (EBU R128) before the two are mixed: speech at the same
# level, with room for both (the mix peaks below -1 dBFS).
SPEECH_LUFS = -18.0
RATE = 48000
# Log lines kept in the timeline: what Pip decided, not the per-frame trackers.
NOISY = re.compile(r"^(tokens |edgetam (check|shown)|space: \d+ live|say: |  cue )")


def run(cmd, binary=False):
    return subprocess.run(cmd, capture_output=True, text=not binary)


def ffmpeg(*args):
    r = run(["ffmpeg", "-hide_banner", "-nostdin", "-y", *map(str, args)])
    if r.returncode != 0:
        sys.exit("ffmpeg failed: " + " ".join(map(str, args))[:300] + "\n" + r.stderr[-1500:])
    return r.stderr


def duration(path):
    r = run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(path)])
    try:
        return float(r.stdout.strip())
    except ValueError:
        return 0.0


def clock(t):
    t = max(0.0, t)
    return "%02d:%04.1f" % (int(t // 60), t % 60)


# MARK: pull

def devicectl(*args):
    return run(["xcrun", "devicectl", "device", *args, "--device", DEVICE, "--domain-type", "appDataContainer",
                "--domain-identifier", BUNDLE])


def phone_files(sub):
    """The files (not folders) under Documents/<sub> on the iPhone, relative to it."""
    r = devicectl("info", "files", "--subdirectory", sub)
    names = []
    for line in r.stdout.splitlines():
        parts = re.split(r"\s{2,}", line.strip())
        if len(parts) >= 3 and "Readable" in parts[1] and "Directory" not in parts[1]:
            names.append(parts[0])
    return names


def pull(folder):
    folder = Path(folder).expanduser()
    folder.mkdir(parents=True, exist_ok=True)
    files = phone_files("Documents/takes")
    takes = sorted({f.split("/")[0] for f in files if f.endswith("/take.json")})
    if not takes:
        print("No finished takes on the iPhone.")
        return
    for take in takes:
        local = folder / take
        if (local / "take.json").exists():
            print(f"{take}: already in {local}")
            continue
        local.mkdir(exist_ok=True)
        # take.json last: a take is complete here once it is.
        mine = sorted((f for f in files if f.startswith(take + "/")), key=lambda f: f.endswith("take.json"))
        ok = True
        for f in mine:
            name = f.split("/", 1)[1]
            r = devicectl("copy", "from", "--source", f"Documents/takes/{f}", "--destination", str(local / name))
            if r.returncode != 0 or not (local / name).exists():
                ok = False
                print(f"{take}/{name}: not copied: {(r.stderr or r.stdout).strip()[-300:]}")
                break
        print(f"{take}: {'copied to ' + str(local) if ok else 'incomplete, try again'}")


# MARK: build

def loudness(path):
    """Integrated loudness (LUFS) of a file's audio; None when it is silent."""
    err = ffmpeg("-i", path, "-af", "ebur128=framelog=quiet", "-f", "null", "-")
    found = re.findall(r"I:\s+(-?[\d.]+) LUFS", err)
    if not found:
        return None
    value = float(found[-1])
    return None if value <= -69 else value


def sounds(path, total, noise=-42, least=0.3):
    """The stretches of a file that are not silent, as (start, end) seconds."""
    err = ffmpeg("-i", path, "-af", f"silencedetect=noise={noise}dB:d={least}", "-f", "null", "-")
    starts = [float(x) for x in re.findall(r"silence_start: (-?[\d.]+)", err)]
    ends = [float(x) for x in re.findall(r"silence_end: (-?[\d.]+)", err)]
    out, t = [], 0.0
    for i, s in enumerate(starts):
        if s > t + 0.05:
            out.append((t, s))
        t = ends[i] if i < len(ends) else total
    if t < total - 0.05:
        out.append((t, total))
    return out


def stem(src, out, seconds, shift, highpass=False):
    """`src` as mono 48 kHz, moved by `shift` seconds (later when positive), as long as the take,
    levelled to SPEECH_LUFS. Returns the gain applied (dB), or None when it holds no sound."""
    moved = f"adelay={int(round(shift * RATE))}S:all=1" if shift >= 0 else f"atrim=start={-shift:.4f},asetpts=PTS-STARTPTS"
    chain = f"aresample={RATE},pan=mono|c0=c0,{moved}" + (",highpass=f=70" if highpass else "") + f",apad,atrim=0:{seconds:.3f}"
    raw = out.with_name("." + out.name)
    ffmpeg("-i", src, "-af", chain, "-ar", RATE, "-ac", 1, "-c:a", "pcm_s16le", raw)
    level = loudness(raw)
    gain = 0.0 if level is None else max(-20.0, min(30.0, SPEECH_LUFS - level))
    ffmpeg("-i", raw, "-af", f"volume={gain:.2f}dB", "-c:a", "pcm_s16le", out)
    raw.unlink()
    return None if level is None else gain


def wrap(text, width=42):
    """Subtitle lines of at most `width` characters, by words."""
    lines, line = [], ""
    for word in text.split():
        if line and len(line) + 1 + len(word) > width:
            lines.append(line)
            line = word
        else:
            line = (line + " " + word).strip()
    if line:
        lines.append(line)
    return lines


def two_lines(text, width=42):
    """`text` on one line, or on two of about equal length."""
    if len(text) <= width:
        return [text]
    words = text.split()
    best = None
    for i in range(1, len(words)):
        a, b = " ".join(words[:i]), " ".join(words[i:])
        if len(a) <= width and len(b) <= width and (best is None or max(len(a), len(b)) < max(map(len, best))):
            best = [a, b]
    return best or wrap(text, width)


def pieces(text, width=42):
    """A text as subtitles of at most two lines each: whole sentences together while they fit, a
    longer sentence in runs of about equal length, so no piece is a lone word."""
    out = []
    for sentence in re.split(r"(?<=[.!?])\s+", text.strip()):
        if not sentence:
            continue
        if out and len(two_lines(out[-1] + " " + sentence, width)) <= 2:
            out[-1] += " " + sentence
            continue
        words = sentence.split()
        k = 1
        while True:
            target = len(sentence) / k
            runs, run = [], []
            for w in words:
                if run and len(runs) < k - 1 and len(" ".join(run + [w])) > target:
                    runs.append(" ".join(run))
                    run = [w]
                else:
                    run.append(w)
            runs.append(" ".join(run))
            if all(len(two_lines(r, width)) <= 2 for r in runs) or k >= len(words):
                break
            k += 1
        out.extend(runs)
    return out or [text]


def srt_time(t):
    ms = int(round(max(0.0, t) * 1000))
    return "%02d:%02d:%02d,%03d" % (ms // 3600000, ms // 60000 % 60, ms // 1000 % 60, ms % 1000)


def write_srt(path, cues):
    """`cues`: (start, end, text). A long text is split into pieces of two lines, timed by length."""
    blocks = []
    for start, end, text in cues:
        parts = pieces(text)
        total = sum(len(p) for p in parts) or 1
        t = start
        for p in parts:
            d = (end - start) * len(p) / total
            blocks.append((t, t + d, "\n".join(two_lines(p))))
            t += d
    with open(path, "w") as f:
        for i, (s, e, text) in enumerate(blocks, 1):
            f.write(f"{i}\n{srt_time(s)} --> {srt_time(e)}\n{text}\n\n")


def build(folder):
    d = Path(folder).expanduser()
    meta = json.loads((d / "take.json").read_text())
    name = meta["take"]
    screen = d / "screen.mov"
    seconds = duration(screen) or meta.get("seconds", 0)
    latency = meta.get("latency", {})
    # Pip's voice reaches the speaker the output latency after it is played; the microphone's
    # sound was in the room the input latency before it arrived.
    pip_shift, mic_shift = latency.get("output", 0.0), -latency.get("input", 0.0)
    print(f"{name}: {clock(seconds)}, {meta['video']['frames']} frames ({meta['video']['dropped']} dropped)")

    stems = {}
    for key, src, shift in (("pip", d / "pip.caf", pip_shift), ("you", d / "mic.caf", mic_shift)):
        if not src.exists():
            print(f"  no {src.name}")
            continue
        out = d / f"{name}-{key}.wav"
        gain = stem(src, out, seconds, shift, highpass=key == "you")
        stems[key] = out
        print(f"  {out.name}: " + ("silent" if gain is None else f"levelled by {gain:+.1f} dB"))

    mix = d / f".{name}-mix.wav"
    if len(stems) == 2:
        ffmpeg("-i", stems["pip"], "-i", stems["you"], "-filter_complex",
               "[0:a][1:a]amix=inputs=2:normalize=0:duration=longest,alimiter=limit=0.89:level=false",
               "-c:a", "pcm_s16le", mix)
    elif stems:
        shutil.copy(next(iter(stems.values())), mix)
    video = d / f"{name}.mp4"
    args = ["-i", screen]
    if stems:
        args += ["-i", mix, "-map", "0:v:0", "-map", "1:a:0", "-c:a", "aac", "-b:a", "256k", "-ac", 2]
    # ReplayKit's frames use the full range (0-255); video players, editors and YouTube expect the
    # video range (16-235) and show a full-range file too dark and too bright where they ignore its tag.
    ffmpeg(*args, "-vf", "fps=30,scale=out_range=tv", "-c:v", "libx264", "-preset", "fast", "-crf", 15,
           "-pix_fmt", "yuv420p", "-color_range", "tv", "-t", f"{seconds:.3f}", "-movflags", "+faststart", video)
    if mix.exists():
        mix.unlink()
    print(f"  {video.name}: the screen at 30 fps with both voices")

    events = meta.get("events", [])
    # Pip: from each sentence's start as heard until its voice stops before the next one.
    pip_sounds = sounds(stems["pip"], seconds) if "pip" in stems else []
    said = [(e["t"] + pip_shift, e["text"]) for e in events if e["kind"] == "pip"]
    pip_cues = []
    for i, (start, text) in enumerate(said):
        limit = said[i + 1][0] if i + 1 < len(said) else start + 15
        ends = [e for s, e in pip_sounds if s < limit and e > start]
        end = min(max(ends), limit) if ends else min(start + 0.06 * len(text) + 0.5, limit)
        pip_cues.append((start, max(end, start + 0.8), text))
    write_srt(d / f"{name}-pip.srt", pip_cues)
    # The user: what the speech service heard, timed on the microphone's sound before it.
    you_sounds = sounds(stems["you"], seconds, noise=-38) if "you" in stems else []
    you_cues = []
    began = None
    for e in events:
        if e["kind"] == "you.start":
            began = e["t"]
        elif e["kind"] == "you":
            heard = e["t"]
            since = (began if began is not None and heard - began < 20 else heard - 6) - 1.0
            near = [(s, en) for s, en in you_sounds if en > since and s < heard]
            if near:
                start, end = near[0][0], min(near[-1][1], heard)
            else:
                start, end = max(since + 1.0, heard - 3), heard
            you_cues.append((start, max(end, start + 0.8), e["text"]))
            began = None
    write_srt(d / f"{name}-you.srt", you_cues)
    print(f"  subtitles: {len(pip_cues)} of Pip's sentences, {len(you_cues)} of yours")

    lines = [f"Take {name}, {clock(seconds)}",
             f"video: {meta['video']} ",
             f"audio: {meta.get('audio')}",
             f"latency: {latency}"]
    if meta.get("problems"):
        lines.append(f"problems: {meta['problems']}")
    lines.append("")
    for e in events:
        kind, text, t = e["kind"], e["text"], e["t"]
        if kind == "log" and NOISY.search(text):
            continue
        if kind == "pip":
            t += pip_shift
        label = {"pip": "Pip", "you": "you", "echo": "echo", "cue": "shown", "log": "  ·"}.get(kind)
        if label:
            lines.append(f"{clock(t)}  {label:5} {text}")
    (d / f"{name}-timeline.txt").write_text("\n".join(lines) + "\n")
    print(f"  {name}-timeline.txt")


# MARK: sync

def pcm(path, rate):
    r = run(["ffmpeg", "-hide_banner", "-nostdin", "-i", str(path), "-vn", "-ac", "1", "-ar", str(rate), "-f", "f32le", "-"], binary=True)
    a = array.array("f")
    a.frombytes(r.stdout[: len(r.stdout) // 4 * 4])
    return a


def onsets(samples, rate, hop=0.01):
    """How much the sound rises every `hop` seconds (log energy): alike for the same speech
    recorded by different microphones and at different levels."""
    n = int(rate * hop)
    energy = []
    for i in range(0, len(samples) - n, n):
        s = 0.0
        for x in samples[i:i + n]:
            s += x * x
        energy.append(math.log10(s / n + 1e-9))
    rises = [0.0] + [max(0.0, energy[i] - energy[i - 1]) for i in range(1, len(energy))]
    mean = sum(rises) / max(1, len(rises))
    return [r - mean for r in rises]


def fft(a, invert=False):
    a = list(a)
    n = len(a)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    size = 2
    while size <= n:
        half = size // 2
        step = cmath.exp((2j if invert else -2j) * math.pi / size)
        twiddles = [1 + 0j] * half
        for k in range(1, half):
            twiddles[k] = twiddles[k - 1] * step
        for start in range(0, n, size):
            for k in range(half):
                u = a[start + k]
                v = a[start + k + half] * twiddles[k]
                a[start + k] = u + v
                a[start + k + half] = u - v
        size <<= 1
    return [x / n for x in a] if invert else a


def offset(take_audio, clip_audio, rate=8000, hop=0.01):
    """Seconds into the clip where the take begins, and how clearly (best peak / next best)."""
    a, b = onsets(pcm(take_audio, rate), rate, hop), onsets(pcm(clip_audio, rate), rate, hop)
    if len(a) < 100 or len(b) < 100:
        sys.exit(f"No sound to line up with in {take_audio if len(a) < 100 else clip_audio}.")
    n = 1
    while n < len(a) + len(b):
        n <<= 1
    fa, fb = fft(a + [0.0] * (n - len(a))), fft(b + [0.0] * (n - len(b)))
    corr = [x.real for x in fft([y * x.conjugate() for x, y in zip(fa, fb)], invert=True)]
    best = max(range(n), key=lambda i: corr[i])
    # Parabolic interpolation between the neighbouring lags.
    l, c, r = corr[best - 1], corr[best], corr[(best + 1) % n]
    frac = 0.5 * (l - r) / (l - 2 * c + r) if (l - 2 * c + r) != 0 else 0.0
    lag = best if best < n // 2 else best - n
    away = int(0.5 / hop)
    rest = max(v for i, v in enumerate(corr) if min(abs(i - best), n - abs(i - best)) > away)
    return (lag + frac) * hop, (c / rest if rest > 0 else float("inf"))


def sync(folder, clip, write):
    d = Path(folder).expanduser()
    meta = json.loads((d / "take.json").read_text())
    name = meta["take"]
    take_video = d / f"{name}.mp4"
    if not take_video.exists():
        build(d)
    clip = Path(clip).expanduser()
    if not clip.exists():
        sys.exit(f"No such clip: {clip}")
    seconds, clarity = offset(take_video, clip)
    fps = 30
    where = (f"the take begins {seconds:.3f} s into the clip" if seconds >= 0
             else f"the clip begins {-seconds:.3f} s into the take")
    print(f"{clip.name}: {where} (frame {round(abs(seconds) * fps)} at 30 fps); "
          f"{'clear' if clarity >= 1.5 else 'UNSURE, check by eye'} ({clarity:.1f}x the next best)")
    record = d / "sync.json"
    known = json.loads(record.read_text()) if record.exists() else {}
    known[clip.name] = {"takeStartsInClip": round(seconds, 3), "clarity": round(clarity, 2)}
    record.write_text(json.dumps(known, indent=2) + "\n")
    if write:
        out = clip.with_name(clip.stem + "-synced.mp4")
        if seconds >= 0:
            args = ["-ss", f"{seconds:.3f}", "-i", clip]
        else:
            ms = int(round(-seconds * 1000))
            args = ["-i", clip, "-vf", f"tpad=start_duration={-seconds:.3f}:color=black", "-af", f"adelay={ms}:all=1"]
        ffmpeg(*args, "-c:v", "hevc_videotoolbox", "-b:v", "40M", "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "256k", out)
        print(f"  {out.name}: starts with the take")


def main(argv):
    if len(argv) < 2 or argv[1] not in ("pull", "build", "sync"):
        print(__doc__)
        return 1
    if argv[1] == "pull":
        pull(argv[2] if len(argv) > 2 else DEFAULT_FOLDER)
    elif argv[1] == "build":
        for folder in argv[2:]:
            build(folder)
    else:
        if len(argv) < 4:
            print(__doc__)
            return 1
        sync(argv[2], argv[3], "--write" in argv[4:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
