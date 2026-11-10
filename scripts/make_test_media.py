#!/usr/bin/env python3
"""Build a synthetic media fixture for playback checks that must not depend on the network.

Device and playback checks used to need a real capture: something had to be pulled
from upstream, which drifts (captions, hosts, token lifetimes) and cannot be replayed
on a machine without an account. This script produces the same shapes from
ffmpeg's built-in sources instead: a short H.264/AAC clip, an HLS ladder over it,
and deterministic key material.

Everything lands under ``build/`` (gitignored) and is byte-identical across runs for
a given ``--seconds``/``--size``, so a fixture hash is a useful assertion rather than
a moving target.

Usage:
    python scripts/make_test_media.py --check          # is the toolchain present?
    python scripts/make_test_media.py                  # write build/test-media/
    python scripts/make_test_media.py --seconds 12 --size 640x360 --force

Requires ffmpeg and ffprobe on PATH (Windows: `winget install Gyan.FFmpeg`, or put
the unpacked `bin/` on PATH). ``--check`` reports what is missing and exits 3.

Exit codes:
    0  success (or the toolchain is present)
    1  the fixture could not be produced (bad output path, ffmpeg failed)
    2  a usage error: the arguments are wrong (argparse's own code)
    3  the toolchain is missing, so the work was skipped

The distinction between 2 and 3 matters to a caller: a wrong argument is a
failure to fix, while a missing ffmpeg is a reason to skip. argparse already
uses 2 for usage errors, so the "toolchain missing" code must not be 2.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "build" / "test-media"
KEY_MATERIAL = b"fqapp-test-media"  # deterministic, not a secret: it only unlocks this fixture


def parse_size(value: str) -> tuple[int, int]:
    try:
        width, height = (int(part) for part in value.lower().split("x", 1))
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"expected WIDTHxHEIGHT, got {value!r}") from error
    if width <= 0 or height <= 0 or width % 2 or height % 2:
        raise argparse.ArgumentTypeError("width and height must be positive even numbers (H.264 4:2:0)")
    return width, height


def who_works(tool: str) -> str | None:
    """Return the version banner when the tool exists and runs, else None."""
    executable = shutil.which(tool)
    if executable is None:
        return None
    try:
        result = subprocess.run([executable, "-version"], capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.splitlines()[0] if result.stdout else executable


def probe_duration(path: Path) -> float | None:
    """Duration in seconds, or None when ffprobe cannot tell us.

    A bare traceback would break this script's own rule that a failed tool is
    reported as "command + stderr tail", not a stack.
    """
    command = ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)]
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        return float(json.loads(result.stdout)["format"]["duration"])
    except subprocess.CalledProcessError as error:
        print(f"ffprobe failed ({error.returncode}):\n{' '.join(command)}\n{error.stderr[-2000:]}", file=sys.stderr)
    except (KeyError, ValueError) as error:
        print(f"ffprobe returned no usable duration for {path}: {error!r}", file=sys.stderr)
    return None


def run(arguments: list[str]) -> None:
    # The whole point is reproducibility: show the command on failure instead of
    # a bare CalledProcessError traceback.
    result = subprocess.run(arguments, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"ffmpeg failed ({result.returncode}):\n{' '.join(arguments)}\n{result.stderr[-2000:]}")


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_output(output: Path, force: bool) -> str | None:
    """Why the output path cannot be used, or None when it can.

    Checked before the toolchain probe on purpose: a wrong output path is a
    mistake in the invocation, not a missing dependency, and it must not be
    reported as "ffmpeg not found". Doing it here also keeps the behaviour
    testable on a machine without ffmpeg.
    """
    # `mkdir(exist_ok=True)` would raise a bare FileExistsError traceback
    # later, which is exactly the "give the command, not the stack" rule this
    # script applies to its tool failures.
    if output.exists() and not output.is_dir():
        return f"--output {output} exists and is not a directory"
    # The manifest is what makes the directory a "fixture". Counting the clip
    # as well keeps a half-written run from being treated as complete.
    if not force and (
        (output / "clear.mp4").exists()
        or (output / "clear.m3u8").exists()
        or (output / "fixture.json").exists()
    ):
        return f"{output} already holds a fixture; pass --force to rebuild"
    return None


def build(output: Path, seconds: int, size: tuple[int, int], force: bool) -> int:
    width, height = size
    clip = output / "clear.mp4"
    playlist = output / "clear.m3u8"
    manifest_path = output / "fixture.json"
    output.mkdir(parents=True, exist_ok=True)
    # A previous, longer fixture leaves segments the new playlist will not
    # reference; without this the manifest would advertise orphans and the
    # "fixture hash is an assertion" promise would not hold.
    for stale in output.glob("clear*.ts"):
        stale.unlink()
    # A manifest describing the old bytes is worse than no manifest: it makes an
    # in-progress or broken rebuild look valid.
    manifest_path.unlink(missing_ok=True)

    print(f"== clear.mp4 ({width}x{height}, {seconds}s, H.264 + AAC) ==")
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", f"testsrc2=size={width}x{height}:rate=25",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
        "-t", str(seconds),
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "25", "-threads", "1",
        "-c:a", "aac", "-b:a", "64k",
        "-movflags", "+faststart",
        str(clip),
    ])

    print("== clear.m3u8 (2s segments, copied, no re-encode) ==")
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(clip), "-c", "copy",
        "-hls_time", "2", "-hls_playlist_type", "vod",
        "-hls_segment_filename", str(output / "clear%03d.ts"),
        str(playlist),
    ])

    # Same shape as a decryption manifest: 16 raw key bytes plus a one-line pointer.
    key = output / "key.bin"
    key.write_bytes(hashlib.sha256(KEY_MATERIAL).digest()[:16])
    (output / "key-info.txt").write_text(f"{key.name}\n{key.resolve()}\n", encoding="utf-8")

    duration = probe_duration(clip)
    if duration is None or duration <= 0:
        print(f"ffprobe reads no duration from {clip}; the fixture is incomplete and has no manifest", file=sys.stderr)
        return 1

    segments = sorted(output.glob("clear*.ts"))
    manifest = {
        "clip": clip.name,
        "clip_sha256": sha256_of(clip),
        "clip_bytes": clip.stat().st_size,
        "duration_seconds": round(duration, 3),
        "hls_playlist": playlist.name,
        "hls_segments": {segment.name: segment.stat().st_size for segment in segments},
        "key": key.name,
        "key_sha256": sha256_of(key),
        # x264/aac output depends on the encoder build, so "reproducible" only
        # holds within one toolchain. Recording it is what makes a hash mismatch
        # diagnosable instead of mysterious.
        "ffmpeg": who_works("ffmpeg"),
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"duration: {manifest['duration_seconds']}s, {len(segments)} HLS segment(s)")
    print(f"clip sha256: {manifest['clip_sha256'][:16]}...")
    print(f"written: {output}")
    print("Nothing here is checked in: build/ is ignored. Delete the directory to start over.")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--seconds", type=int, default=6, help="clip length (default: 6)")
    parser.add_argument("--size", type=parse_size, default=(320, 180), help="WIDTHxHEIGHT (default: 320x180)")
    parser.add_argument("--force", action="store_true", help="overwrite an existing fixture")
    parser.add_argument("--check", action="store_true", help="only report whether ffmpeg and ffprobe are usable")
    options = parser.parse_args(argv)

    # Argument mistakes are reported before the toolchain probe: they are the
    # caller's own mistake, and they must not be masked by "ffmpeg not found"
    # on a machine that has no ffmpeg.
    if options.seconds <= 0:
        parser.error("--seconds must be positive")
    output = options.output.resolve()
    if not options.check:
        problem = check_output(output, options.force)
        if problem is not None:
            print(problem, file=sys.stderr)
            return 1

    versions = {tool: who_works(tool) for tool in ("ffmpeg", "ffprobe")}
    missing = [tool for tool, version in versions.items() if version is None]
    for tool, version in versions.items():
        print(f"{tool}: {version or 'NOT FOUND'}")
    if missing:
        print(
            f"missing: {', '.join(missing)}. Install them (Windows: winget install Gyan.FFmpeg) "
            "or put ffmpeg's bin/ on PATH; --check exits 3 so CI can skip instead of guessing.",
            file=sys.stderr,
        )
        # 3, not 2: argparse already uses 2 for a usage error, and a caller
        # that sees 2 must be able to tell "the arguments are wrong" from
        # "the tools are not installed".
        return 3
    if options.check:
        return 0
    return build(output, options.seconds, options.size, options.force)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
