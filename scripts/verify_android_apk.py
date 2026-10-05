#!/usr/bin/env python3
r"""Verify the packaged ARM64 APK and retain reproducible inspection artifacts.

Usage:
    python scripts/verify_android_apk.py --apk app-release.apk \
        --build-tools /opt/android-sdk/build-tools/36.0.0 \
        --report-dir build/ci-artifacts/verification

Only the APK's own native libraries are inspected. This does not run Gradle,
sign or modify the APK, or read a signing keystore. Node.js and Java must be
available; all Python dependencies are from the standard library.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
import zlib


REQUIRED_LIBRARIES = {
    "lib/arm64-v8a/libfqapi_core.so",
    "lib/arm64-v8a/libshortplay_crypto.so",
    "lib/arm64-v8a/libflutter.so",
    "lib/arm64-v8a/libapp.so",
}
MAX_ZIP_ENTRIES = 100_000
MAX_NATIVE_LIBRARIES = 256
MAX_LIBRARY_BYTES = 256 * 1024 * 1024
MAX_TOTAL_LIBRARY_BYTES = 512 * 1024 * 1024
COPY_CHUNK_BYTES = 1024 * 1024
COMMAND_TIMEOUT_SECONDS = 180


class VerificationError(Exception):
    """An APK or verification prerequisite did not satisfy the contract."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(COPY_CHUNK_BYTES), b""):
            digest.update(block)
    return digest.hexdigest()


def inside_directory(path: Path, directory: Path) -> bool:
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


def output_path(directory: Path, relative: str) -> Path:
    """Create controlled parents without following a symlink out of the report."""
    parts = relative.split("/")
    if not parts or any(part in ("", ".", "..") or "\\" in part or ":" in part
                        for part in parts):
        raise VerificationError(f"Unsafe report path: {relative!r}")
    parent = directory
    for part in parts[:-1]:
        parent = parent / part
        if parent.is_symlink():
            raise VerificationError(f"Report subdirectory is a symlink: {parent}")
        parent.mkdir(exist_ok=True)
        if not parent.is_dir() or not inside_directory(parent.resolve(), directory):
            raise VerificationError(f"Report path escapes its directory: {parent}")
    destination = parent / parts[-1]
    if destination.is_symlink() or not inside_directory(destination.resolve(), directory):
        raise VerificationError(f"Unsafe existing report file: {destination}")
    if destination.exists() and not destination.is_file():
        raise VerificationError(f"Report output is not a regular file: {destination}")
    return destination


def write_text(directory: Path, relative: str, content: str) -> None:
    destination = output_path(directory, relative)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n",
                                         dir=destination.parent, prefix=".apk-verify-",
                                         delete=False) as output:
            temporary = Path(output.name)
            output.write(content)
        # Replacing the directory entry also avoids overwriting an existing
        # hard link's target outside the report directory.
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def inspect_archive(archive: zipfile.ZipFile) -> list[zipfile.ZipInfo]:
    entries = archive.infolist()
    if len(entries) > MAX_ZIP_ENTRIES:
        raise VerificationError("APK has too many ZIP entries")
    seen = set()
    native_names = set()
    native_entries = []
    total_native_size = 0
    for entry in entries:
        name = entry.orig_filename
        if name != entry.filename or "\x00" in name or "\\" in name:
            raise VerificationError(f"Unsafe ZIP entry name: {name!r}")
        canonical = name[:-1] if entry.is_dir() else name
        parts = canonical.split("/")
        if any(part in ("", ".", "..") or ":" in part for part in parts):
            raise VerificationError(f"Unsafe ZIP entry path: {name!r}")
        if canonical in seen:
            raise VerificationError(f"Duplicate ZIP entry: {name!r}")
        seen.add(canonical)
        mode = entry.external_attr >> 16
        if stat.S_ISLNK(mode):
            raise VerificationError(f"ZIP symlinks are not allowed: {name!r}")
        if entry.flag_bits & 1:
            raise VerificationError(f"Encrypted ZIP entries are not allowed: {name!r}")
        if parts[0] == "lib" and len(parts) >= 2 and parts[1] != "arm64-v8a":
            raise VerificationError(f"Unexpected APK ABI: {parts[1]!r}")
        if not name.lower().endswith(".so"):
            continue
        if (entry.is_dir() or len(parts) != 3 or parts[:2] != ["lib", "arm64-v8a"]
                or re.fullmatch(r"lib[A-Za-z0-9_.+\-]+\.so", parts[2]) is None):
            raise VerificationError(f"Native library has an unsupported APK location: {name!r}")
        # The same report remains safe to generate on a case-insensitive host.
        if name.casefold() in native_names:
            raise VerificationError(f"Native ZIP paths collide by case: {name!r}")
        native_names.add(name.casefold())
        if stat.S_IFMT(mode) not in (0, stat.S_IFREG):
            raise VerificationError(f"Native library is not a regular ZIP file: {name!r}")
        if entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            raise VerificationError(f"Unsupported native ZIP compression: {name!r}")
        if entry.file_size <= 0 or entry.file_size > MAX_LIBRARY_BYTES:
            raise VerificationError(f"Native library size exceeds the allowed range: {name!r}")
        total_native_size += entry.file_size
        native_entries.append(entry)
        if len(native_entries) > MAX_NATIVE_LIBRARIES or total_native_size > MAX_TOTAL_LIBRARY_BYTES:
            raise VerificationError("APK native libraries exceed extraction limits")
    missing = REQUIRED_LIBRARIES.difference(entry.filename for entry in native_entries)
    if missing:
        raise VerificationError("APK is missing required ARM64 libraries: " + ", ".join(sorted(missing)))
    return sorted(native_entries, key=lambda entry: entry.filename)


def extract_library(archive: zipfile.ZipFile, entry: zipfile.ZipInfo,
                    report_dir: Path) -> tuple[Path, dict]:
    destination = output_path(report_dir, "native-libraries/" + entry.filename)
    digest = hashlib.sha256()
    written = 0
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="wb", dir=destination.parent,
                                         prefix=".apk-verify-", delete=False) as output:
            temporary = Path(output.name)
            with archive.open(entry, "r") as source:
                for block in iter(lambda: source.read(COPY_CHUNK_BYTES), b""):
                    written += len(block)
                    if written > entry.file_size or written > MAX_LIBRARY_BYTES:
                        raise VerificationError(f"Native ZIP entry exceeds its declared size: {entry.filename}")
                    output.write(block)
                    digest.update(block)
        if written != entry.file_size:
            raise VerificationError(f"Truncated native ZIP entry: {entry.filename}")
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return destination, {
        "path": entry.filename,
        "size_bytes": written,
        "sha256": digest.hexdigest(),
        "compression": "stored" if entry.compress_type == zipfile.ZIP_STORED else "deflated",
    }


def executable(name: str, directory: Path | None = None) -> str:
    if directory is None:
        resolved = shutil.which(name)
        if resolved:
            return resolved
    else:
        candidates = [directory / name]
        if os.name == "nt":
            candidates.insert(0, directory / (name + ".exe"))
        for candidate in candidates:
            if candidate.is_file():
                return str(candidate)
    raise VerificationError(f"Required executable was not found: {name}")


def run_logged(command: list[str], report_dir: Path, log_name: str,
               allowed_returncodes: tuple[int, ...] = ()) -> str:
    print(f"Checking {log_name.removesuffix('.log')}...", flush=True)
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, encoding="utf-8", errors="replace", shell=False,
                                check=False, timeout=COMMAND_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        captured = error.stdout or b""
        if isinstance(captured, bytes):
            captured = captured.decode("utf-8", errors="replace")
        write_text(report_dir, log_name, captured + "\nVerification command timed out.\n")
        raise VerificationError(f"Verification command timed out; see {log_name}") from error
    except OSError as error:
        write_text(report_dir, log_name, str(error) + "\n")
        raise VerificationError(f"Cannot run verification command; see {log_name}") from error
    write_text(report_dir, log_name, result.stdout)
    # A tolerated exit code is recorded in the log rather than hidden, so the
    # report still shows what the tool actually said about the package.
    if result.returncode != 0:
        if result.returncode in allowed_returncodes:
            write_text(report_dir, log_name,
                       result.stdout + f"\nAllowed exit code {result.returncode}.\n")
            return ""
        raise VerificationError(f"Verification command exited with {result.returncode}; see {log_name}")
    return result.stdout


def application_metadata(badging: str) -> dict:
    package_line = next((line for line in badging.splitlines() if line.startswith("package: ")), "")
    fields = dict(re.findall(r"(\w+)='([^']*)'", package_line))
    if not all(field in fields for field in ("name", "versionCode", "versionName")):
        raise VerificationError("aapt did not return a complete package/version description")
    if not fields["versionCode"].isdigit():
        raise VerificationError("aapt returned an invalid application version code")
    result = {
        "package_name": fields["name"],
        "version_code": int(fields["versionCode"]),
        "version_name": fields["versionName"],
    }
    for label, key in (("sdkVersion", "min_sdk"), ("targetSdkVersion", "target_sdk")):
        match = re.search(r"^" + label + r":'([^']*)'", badging, re.MULTILINE)
        if match:
            result[key] = match.group(1)
    return result


def certificate_digests(output: str) -> list[str]:
    values = re.findall(r"^Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F:]+)\s*$",
                        output, re.MULTILINE)
    digests = sorted({value.replace(":", "").lower() for value in values})
    if not digests or any(re.fullmatch(r"[0-9a-f]{64}", value) is None for value in digests):
        raise VerificationError("apksigner did not return a valid signer certificate SHA-256 digest")
    return digests


def sha256_argument(value: str) -> str:
    digest = value.strip().replace(":", "").lower()
    if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise argparse.ArgumentTypeError("Expected a 64-digit SHA-256 certificate digest")
    return digest


def verify(args: argparse.Namespace, report_dir: Path, report: dict) -> None:
    apk = Path(args.apk).expanduser().resolve(strict=True)
    build_tools = Path(args.build_tools).expanduser().resolve(strict=True)
    if not apk.is_file():
        raise VerificationError(f"APK is not a regular file: {apk}")
    if not build_tools.is_dir():
        raise VerificationError(f"Build-tools path is not a directory: {build_tools}")
    checker = Path(__file__).resolve().parent / "check_native_alignment.cjs"
    signer = build_tools / "lib" / "apksigner.jar"
    if not checker.is_file() or not signer.is_file():
        raise VerificationError("ELF checker or build-tools/lib/apksigner.jar is missing")
    node = executable("node")
    java = executable("java")
    zipalign = executable("zipalign", build_tools)
    aapt = executable("aapt", build_tools)

    size = apk.stat().st_size
    digest = sha256_file(apk)
    report["apk"] = {"name": apk.name, "size_bytes": size, "sha256": digest}
    write_text(report_dir, apk.name + ".sha256", f"{digest}  {apk.name}\n")

    libraries = []
    report["native_libraries"] = []
    with zipfile.ZipFile(apk, "r") as archive:
        entries = inspect_archive(archive)
        report["checks"]["zip_entries"] = "passed"
        for entry in entries:
            path, details = extract_library(archive, entry, report_dir)
            libraries.append(path)
            report["native_libraries"].append(details)
    report["checks"]["native_libraries"] = "passed"

    run_logged([node, str(checker), *(str(path) for path in libraries)],
               report_dir, "elf-alignment.log")
    report["checks"]["elf_16kb_alignment"] = "passed"
    run_logged([zipalign, "-c", "-P", "16", "-v", "4", str(apk)],
               report_dir, "zipalign.log")
    report["checks"]["zip_16kb_alignment"] = "passed"
    # A build made without the release keystore is unsigned, and apksigner
    # exits non-zero on such a package. That is an expected outcome rather than
    # a defect when the caller asks for an unsigned-tolerant verification, so
    # the signature block is reported as absent instead of aborting the run.
    if args.allow_unsigned:
        signature = run_logged([java, "-jar", str(signer), "verify", "--verbose",
                                "--print-certs", str(apk)], report_dir, "apksigner.log",
                               allowed_returncodes=(1,))
        signer_digests = [] if not signature else certificate_digests(signature)
    else:
        signature = run_logged([java, "-jar", str(signer), "verify", "--verbose",
                                "--print-certs", str(apk)], report_dir, "apksigner.log")
        signer_digests = certificate_digests(signature)
    report["signature"] = {
        "certificate_sha256": signer_digests,
        "signed": bool(signer_digests),
    }
    report["checks"]["signature"] = "passed" if signer_digests else "unsigned"
    if args.expected_signer_sha256 is not None:
        report["signature"]["expected_certificate_sha256"] = args.expected_signer_sha256
        if signer_digests != [args.expected_signer_sha256]:
            raise VerificationError("APK is not signed exclusively by the expected certificate")
        report["checks"]["expected_signer"] = "passed"
    elif not signer_digests:
        print("APK carries no signature; verified as an unsigned inspection build.",
              flush=True)
    badging = run_logged([aapt, "dump", "badging", str(apk)], report_dir, "aapt-badging.log")
    report["application"] = application_metadata(badging)
    report["checks"]["application_metadata"] = "passed"

    if apk.stat().st_size != size or sha256_file(apk) != digest:
        raise VerificationError("APK changed during verification; results cannot be trusted")
    report["checks"]["apk_unchanged"] = "passed"
    report["status"] = "passed"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--apk", required=True, help="Built APK to verify without modifying it")
    parser.add_argument("--build-tools", required=True, help="Android SDK build-tools version directory")
    parser.add_argument("--report-dir", required=True, help="Directory for verification logs, JSON, and extracted libraries")
    parser.add_argument("--expected-signer-sha256", type=sha256_argument,
                        help="Require the APK's sole signing certificate to have this SHA-256 digest")
    parser.add_argument("--allow-unsigned", action="store_true",
                        help=("Accept a package with no signature and report it as unsigned. "
                              "Every other check still runs. Use only where the release keystore "
                              "is unavailable, such as a fork or a local inspection build; an "
                              "unsigned package cannot be installed over a signed one."))
    args = parser.parse_args()
    if args.allow_unsigned and args.expected_signer_sha256 is not None:
        parser.error("--allow-unsigned contradicts --expected-signer-sha256: "
                     "a pinned certificate requires a signature")
    report_dir = Path(args.report_dir).expanduser().resolve()
    # An arbitrary input name could otherwise collide with a log/report name.
    # Keeping the original APK outside the output tree makes that impossible.
    if inside_directory(Path(args.apk).expanduser().resolve(), report_dir):
        print("APK must be outside the report directory so it cannot be overwritten", file=sys.stderr)
        return 1
    report = {"schema_version": 1, "status": "failed", "checks": {}}
    try:
        report_dir.mkdir(parents=True, exist_ok=True)
        if not report_dir.is_dir():
            raise VerificationError("Report path is not a directory")
        verify(args, report_dir, report)
    except (VerificationError, OSError, ValueError, zipfile.BadZipFile,
            RuntimeError, EOFError, zlib.error) as error:
        report["error"] = str(error)
        print(f"APK verification failed: {error}", file=sys.stderr)
    try:
        write_text(report_dir, "report.json", json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    except (VerificationError, OSError) as error:
        print(f"Cannot save verification report: {error}", file=sys.stderr)
        return 1
    if report["status"] != "passed":
        return 1
    print(f"Verified {report['apk']['name']}: {report['apk']['sha256']}")
    print(f"Report: {report_dir / 'report.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
