#!/usr/bin/env python3
"""Validate the distributable archive without changing the app or build inputs."""

import argparse
from datetime import datetime, timezone
import hashlib
from pathlib import Path, PurePosixPath
import platform
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unicodedata
import zipfile

from package_notices import bundled_index


ROOT = Path(__file__).resolve().parents[1]
EXECUTABLES = ("Serein", "serein-process-host", "serein-browser-mcp", "serein-agent", "serein-mac-provisioner")
FRAMEWORK = PurePosixPath("Contents/Frameworks/Sparkle.framework")
# Sparkle 2.10.0's versioned framework layout, preserved by build.sh's ditto archive.
# No other app, resource, or nested framework link is accepted.
FRAMEWORK_LINKS = {
    str(FRAMEWORK / name): "Versions/Current/" + name
    for name in ("Autoupdate", "Headers", "Modules", "PrivateHeaders", "Resources",
                 "Sparkle", "Updater.app", "XPCServices")
}
FRAMEWORK_LINKS[str(FRAMEWORK / "Versions/Current")] = "B"
# transcribe.cpp 0.4.2's framework (the dictation model's engine), held to the same rule.
SPEECH_FRAMEWORK = PurePosixPath("Contents/Frameworks/CTranscribe.framework")
FRAMEWORK_LINKS.update({
    str(SPEECH_FRAMEWORK / name): "Versions/Current/" + name
    for name in ("CTranscribe", "Headers", "Modules", "Resources")
})
FRAMEWORK_LINKS[str(SPEECH_FRAMEWORK / "Versions/Current")] = "A"


UPDATE_FEED = {
    "SUFeedURL": "https://github.com/codejunkie99/Serein-Bot/releases/latest/download/appcast.xml",
    "SUPublicEDKey": "Cvu8zrIxWdP+DO1H6jtbfTbFjMtncUu8lTj/w9rKIvU=",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def framework_link(directory, relative):
    path = directory / relative
    target = str(path.readlink())
    require(FRAMEWORK_LINKS.get(relative) == target,
            f"Unexpected framework symlink: {relative} -> {target}")
    # strict resolution rejects dangling links and cycles. The exact target allowlist also
    # rules out absolute links and '..', even when they happen to resolve inside the app.
    resolved = path.resolve(strict=True)
    # The framework the link is in: Contents/Frameworks/<name>.framework.
    framework = directory.joinpath(*PurePosixPath(relative).parts[:3]).resolve(strict=True)
    require(resolved != framework and resolved.is_relative_to(framework),
            f"Framework symlink escapes its framework: {relative}")
    return target


def files(directory, *, framework_links=False):
    require(directory.is_dir(), f"Missing directory: {directory}")
    result = {}
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory).as_posix()
        if path.is_symlink():
            require(framework_links, f"Unexpected symlink: {path}")
            result[relative] = ("symlink", framework_link(directory, relative))
        elif path.is_file():
            result[relative] = ("file", digest(path))
    require(result, f"Empty directory: {directory}")
    return result


def match(left, right, label, *, framework_links=False):
    left_files = files(left, framework_links=framework_links)
    right_files = files(right, framework_links=framework_links)
    changed = sorted(key for key in left_files.keys() | right_files.keys()
                     if left_files.get(key) != right_files.get(key))
    require(not changed, f"{label} mismatch: {', '.join(changed[:8])}")


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    require(result.returncode == 0,
            f"Command failed: {' '.join(map(str, args))}\n{result.stdout}{result.stderr}")
    return result.stdout + result.stderr


def extract(archive, destination):
    entries = archive.infolist()
    # macOS volumes commonly fold case and Unicode normalization. Reject aliases before
    # writing, so an alternate spelling cannot replace or become a parent of a link.
    canonical = lambda name: unicodedata.normalize("NFD", name).casefold()
    seen = {}
    links = {}
    for entry in entries:
        name = entry.filename.rstrip("/")
        parts = name.split("/")
        require(name and entry.orig_filename == entry.filename
                and not entry.filename.startswith("/") and "\\" not in name
                and ":" not in name and all(part not in ("", ".", "..") for part in parts)
                and parts[0] == "Serein.app"
                and not any(part in ("__MACOSX", ".DS_Store") for part in parts),
                f"Unsafe archive path: {entry.filename!r}")
        key = canonical(name)
        require(key not in seen, f"Duplicate archive path: {name}")
        mode = entry.external_attr >> 16
        kind = stat.S_IFMT(mode)
        require(kind in (0, stat.S_IFDIR if entry.is_dir() else stat.S_IFREG)
                or (kind == stat.S_IFLNK and not entry.is_dir()),
                f"Unsupported archive entry type: {name}")
        seen[key] = entry.is_dir()
        if kind == stat.S_IFLNK:
            relative = PurePosixPath(name).relative_to("Serein.app").as_posix()
            expected = FRAMEWORK_LINKS.get(relative)
            require(expected is not None and entry.file_size == len(expected.encode("utf-8")),
                    f"Unexpected archive symlink: {name}")
            target = archive.read(entry).decode("utf-8")
            require(target == expected, f"Unexpected archive symlink: {name} -> {target}")
            links[name] = target
    require(entries, "Empty archive")
    for entry in entries:
        for parent in PurePosixPath(entry.filename).parents:
            require(seen.get(canonical(str(parent)), True),
                    f"Archive path has a non-directory parent: {entry.filename}")
    bad_crc = archive.testzip()
    require(bad_crc is None, f"ZIP CRC failed: {bad_crc}")
    require(destination.is_dir() and not destination.is_symlink() and not any(destination.iterdir()),
            "Extraction destination must be an empty real directory")
    for entry in entries:
        path = destination.joinpath(*PurePosixPath(entry.filename).parts)
        if entry.filename in links:
            continue
        elif entry.is_dir():
            path.mkdir(parents=True, exist_ok=True)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(entry) as source, path.open("xb") as target:
                shutil.copyfileobj(source, target)
            path.chmod((entry.external_attr >> 16) & 0o777)
    # No file is ever written through a symlink: links are created only after all regular
    # entries, and the inventory above rejects children beneath every non-directory entry.
    app = destination / "Serein.app"
    for name, target in links.items():
        path = destination.joinpath(*PurePosixPath(name).parts)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target)
    for name in links:
        framework_link(app, PurePosixPath(name).relative_to("Serein.app").as_posix())
    for entry in sorted(entries, key=lambda item: len(PurePosixPath(item.filename).parts), reverse=True):
        if entry.is_dir():
            destination.joinpath(*PurePosixPath(entry.filename).parts).chmod(
                (entry.external_attr >> 16) & 0o777)
    return len(entries)


def validate(archive_path):
    archive_hash = digest(archive_path)
    lines = ["SEREIN_FINAL_PACKAGE_VALIDATION",
             f"VALIDATED_AT {datetime.now(timezone.utc).isoformat()}",
             f"ZIP_SHA256 {archive_hash}", f"ZIP_BYTES {archive_path.stat().st_size}"]
    with tempfile.TemporaryDirectory(prefix="serein-package-check-") as temporary:
        with zipfile.ZipFile(archive_path) as archive:
            count = extract(archive, Path(temporary))
        app = Path(temporary) / "Serein.app"
        lines += ["ZIP_INTEGRITY PASS", "ZIP_PATH_SAFETY PASS",
                  f"ZIP_INVENTORY PASS entries {count}"]
        command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
        lines.append("EXTRACTED_SIGNATURE PASS")
        signing = command("/usr/bin/codesign", "-d", "--verbose=4", str(app))
        # Local rebuilds may reuse the installed app's Developer ID to retain Mac grants.
        if "Signature=adhoc" in signing:
            signer = "ad-hoc"
        elif "Authority=Apple Development: " in signing:
            signer = "Apple Development"
        elif "Authority=Developer ID Application: " in signing:
            signer = "Developer ID Application"
        else:
            raise ValueError("Expected an ad-hoc, Apple Development or Developer ID Application signature")
        lines.append(f"SIGNING_IDENTITY_CONFIRMED PASS {signer}")
        match(app, archive_path.parent / "Serein.app", "Dist app", framework_links=True)
        lines.append("DIST_APP_EXACT_FILE_MATCH PASS")
        architectures = set(command("/usr/bin/lipo", "-archs", str(app / "Contents/MacOS/Serein")).split())
        require(architectures and architectures <= {"arm64", "x86_64"}, f"Unexpected app architectures: {architectures}")
        label = "universal" if len(architectures) == 2 else next(iter(architectures))
        if archive_path.name.startswith("Serein-Free-macOS-"):
            require(archive_path.name == f"Serein-Free-macOS-{label}.zip", "Archive name disagrees with app architecture")
        flags = ["--arch", "arm64", "--arch", "x86_64"] if label == "universal" else []
        bin_dir = Path(subprocess.check_output(
            ["swift", "build", "-c", "release", *flags, "--show-bin-path"], cwd=ROOT, text=True, timeout=30).strip())
        resources = app / "Contents/Resources"
        bundle = resources / "Serein_Serein.bundle"
        match(bundle, bin_dir / "Serein_Serein.bundle", "Release resources")
        lines.append("RELEASE_RESOURCE_BUNDLE_MATCH PASS")
        require(not any("clerk" in path.name.lower() for path in app.rglob("*")), "Unexpected Clerk payload")
        binary = (app / "Contents/MacOS/Serein").read_bytes()
        for marker in (b"api-production-64cde60c.up.railway.app", b"/api/billing/checkout",
                       b"/api/billing/portal", b"/api/computer/link", b"serein://account/paid",
                       b"clerk.serein.pro"):
            require(marker not in binary, f"Commercial client marker in Free executable: {marker!r}")
        lines.append("FREE_CLIENT_BOUNDARY PASS")
        match(resources / "licenses", ROOT / "docs/licenses", "Third-party licenses")
        require((resources / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8") == bundled_index(resources),
                "Bundled third-party index differs from the Free notices")
        native_resources = bundle / "Contents/Resources"
        if native_resources.is_dir():
            for name in ("cua-driver", "cua-driver-amd64"):
                require(not (bundle / "Computer" / name).exists(),
                        f"CU driver outside the runtime resource directory: {name}")
            bundle = native_resources
        for name in ("cloud-entry.sh", "serein-gate.py"):
            require(not (bundle / "Computer" / name).exists(), f"Unexpected managed-cloud resource: {name}")
        for folder in ("Fonts", "Icons"):
            match(bundle / folder, ROOT / "Sources/Serein" / folder, folder)
            lines.append(f"CURRENT_SOURCE_{folder.upper()}_MATCH PASS")
        for name in ("PageKit.js", "DarkPages.js"):
            require(digest(bundle / name) == digest(ROOT / "Sources/Serein" / name),
                    f"Current script mismatch: {name}")
            lines.append(f"CURRENT_SOURCE_SCRIPT_{name} PASS")
        for name in ("Fonts/licenses/Geist-OFL.txt", "Fonts/licenses/Geist-NOTICES.md",
                     "Icons/NOTICE.txt", "Icons/Zeron-MIT.txt", "Icons/CC-BY-4.0.txt"):
            require((bundle / name).is_file() and (bundle / name).stat().st_size > 0,
                    f"Missing license/notice: {name}")
        require((bundle / "Icons/Zeron-MIT.txt").read_bytes()
                == (ROOT / "docs/licenses/Zeron-MIT.txt").read_bytes(),
                "Bundled Zeron license differs from repository notice")
        # Cua Driver's licence and notices ship beside it whenever the binary does.
        require((bundle / "Computer/cua-driver-license.txt").read_bytes()
                == (ROOT / "docs/licenses/Cua-MIT.txt").read_bytes(),
                "Bundled Cua licence differs from repository notice")
        if any((bundle / "Computer" / name).exists() for name in ("cua-driver", "cua-driver-amd64")):
            require((bundle / "Computer/cua-driver-notices.md").is_file(), "Missing license/notice: Computer/cua-driver-notices.md")
            require(digest(bundle / "Computer/cua-driver-crates.md") ==
                    digest(ROOT / "Sources/Serein/Computer/cua-driver-crates.md"),
                    "Bundled Cua dependency notices differ from repository notice")
        lines.append("LICENSE_INVENTORY PASS")
        guest = app / "Contents/Resources/MacGuest/Serein Computer.app"
        guest_executable = guest / "Contents/MacOS/serein-mac-guest"
        require(guest_executable.is_file() and guest_executable.stat().st_mode & 0o111,
                "Missing native Mac guest executable")
        require(set(command("/usr/bin/lipo", "-archs", str(guest_executable)).split()) == architectures,
                "Unexpected native Mac guest architecture")
        command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(guest))
        with (guest / "Contents/Info.plist").open("rb") as stream:
            guest_info = plistlib.load(stream)
        require(guest_info.get("CFBundleIdentifier") == "pro.serein.computer-guest",
                "Unexpected native Mac guest identity")
        require((guest / "Contents/Resources/terminal-mac-MIT.txt").read_bytes()
                == (ROOT / "docs/licenses/terminal-mac-MIT.txt").read_bytes(),
                "Native Mac guest licence differs from repository notice")
        lines.append("NATIVE_MAC_GUEST PASS signature, identity, architecture, licence")
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        for key, expected in {"CFBundleIdentifier": "local.serein.browser",
                              "CFBundleName": "Serein", "CFBundleDisplayName": "Serein Free",
                              "CFBundleExecutable": "Serein", "CFBundlePackageType": "APPL",
                              "LSMinimumSystemVersion": "14.0"}.items():
            require(info.get(key) == expected, f"Unexpected {key}: {info.get(key)!r}")
        lines.append("APP_INFO PASS")
        require("CFBundleURLTypes" not in info, "Free must omit CFBundleURLTypes")
        feed = {key: info[key] for key in UPDATE_FEED if key in info}
        require(feed in ({}, UPDATE_FEED), f"Update feed must be absent (local build) or exactly {UPDATE_FEED}: {feed}")
        daemon = "pro.serein.mac-provisioner.plist"
        require(digest(app / "Contents/Library/LaunchDaemons" / daemon) == digest(ROOT / "scripts" / daemon),
                "Provisioner registration differs from its source")
        lines.append("UPDATE_FEED_AND_HELPER_REGISTRATION PASS")
        for name in EXECUTABLES:
            executable = app / "Contents/MacOS" / name
            require(executable.is_file() and executable.stat().st_mode & 0o111,
                    f"Missing executable permissions: {name}")
            lines.append(f"EXECUTABLE_{name} PASS")
            slices = set(command("/usr/bin/lipo", "-archs", str(executable)).split())
            require(slices == architectures, f"Unexpected architectures: {name} {slices}")
            lines.append(f"ARCH_{name} PASS {label}")
        release_time = (bin_dir / "Serein").stat().st_mtime_ns
        sources = list((ROOT / "Sources").rglob("*.swift"))
        require(sources, "No Swift source files found")
        newer = [str(path.relative_to(ROOT)) for path in sources
                 if path.stat().st_mtime_ns > release_time]
        require(not newer, f"Source newer than release binary: {', '.join(newer)}")
        lines.append("SOURCE_MTIME_FRESHNESS PASS")
    require(digest(archive_path) == archive_hash, "Archive changed during validation")
    lines += [
        "DIST_METADATA_BOUNDARY File matching ignores filesystem xattrs. Only the fresh archive extraction receives strict signature verification; cloud-backed dist metadata is not asserted.",
        "SCOPE Validates the current release archive and local source/resource inputs. No GUI, real browser-profile import, provider or phone/device checks were run. Signed executable payloads were not normalized against unsigned release files; extracted app files match dist exactly.",
        "RESULT PASS for ZIP integrity, safe paths, extracted code signature, file/resource/source-asset equivalence, licenses, executable architecture, source freshness and Free registration. Notarization and native/device acceptance are outside this check.",
    ]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, default=ROOT / f"dist/Serein-Free-macOS-{platform.machine()}.zip")
    parser.add_argument("--report", type=Path, help="Write a text report only after every check passes")
    args = parser.parse_args()
    try:
        if args.report:
            output = args.report.resolve()
            protected = (ROOT / "Sources", ROOT / ".build", ROOT / "dist", ROOT / "scripts", ROOT / "docs/licenses")
            require(not any(output.is_relative_to(path) for path in protected)
                    and output != args.archive.resolve() and output.suffix == ".txt",
                    "Report must be a .txt file outside the archive, app, build and source inputs")
        report = validate(args.archive.resolve())
        if args.report:
            args.report.write_text(report, encoding="utf-8")
        sys.stdout.write(report)
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
