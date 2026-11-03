"""Builds the thresh command for every platform a release ships it for,
and packs each into zig-out/release: a .tar.gz, or a .zip for Windows,
holding one directory, thresh-<version>-<platform>/, with the binary, the
license, the notices and a short README.txt. ReleaseSafe, as
`zig build --release` builds it. Linux's binary has no libc to link, so
one build runs on every distribution, glibc or musl. The archives are
written byte for byte the same from the same binaries.

    python3 -I tools/release_archives.py                   # every platform
    python3 -I tools/release_archives.py linux-x86_64      # some
"""

import gzip
import io
import os
import re
import subprocess
import sys
import tarfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "zig-out", "release-build")
OUT = os.path.join(ROOT, "zig-out", "release")

# A platform as a download names it: the target Zig builds for (macOS 13,
# as the wheels are) and the binary's name.
PLATFORMS = {
    "macos-arm64": ("aarch64-macos.13.0", "thresh"),
    "macos-x86_64": ("x86_64-macos.13.0", "thresh"),
    "linux-x86_64": ("x86_64-linux-musl", "thresh"),
    "linux-arm64": ("aarch64-linux-musl", "thresh"),
    "windows-x86_64": ("x86_64-windows", "thresh.exe"),
    "windows-arm64": ("aarch64-windows", "thresh.exe"),
}

README = """\
thresh {version}

thresh checks a CSV, TSV or pipe-delimited file before it reaches your
database. It works out how the file is written and what its columns hold,
then sets aside every row that does not fit, with its line number and the
reason. The good rows carry on.

Put {binary} somewhere on your PATH, or run it from here:

    {run} describe orders.csv --reject out --report out

{binary} --help lists every command and option. The documentation, with
examples of what thresh says about real-world files:

    https://github.com/kmoneil/thresh
{extra}"""

MACOS = """
If macOS says thresh "cannot be opened" because it comes from the
internet, clear that once from Terminal, in this directory:

    xattr -d com.apple.quarantine thresh
"""


def version() -> str:
    with open(os.path.join(ROOT, "build.zig.zon"), encoding="utf-8") as f:
        m = re.search(r'\.version\s*=\s*"([^"]+)"', f.read())
    if not m:
        sys.exit("release_archives.py: no .version in build.zig.zon")
    return m.group(1)


def build(platform: str) -> bytes:
    target, binary = PLATFORMS[platform]
    prefix = os.path.join(BUILD, platform)
    cmd = ["zig", "build", "--release", "-Dtarget=" + target, "-p", prefix]
    print("  " + " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=ROOT, check=True)
    with open(os.path.join(prefix, "bin", binary), "rb") as f:
        return f.read()


def contents(platform: str, v: str, exe: bytes) -> list:
    """The archive's files, (path, bytes, mode), in the order written."""
    _, binary = PLATFORMS[platform]
    top = "thresh-%s-%s/" % (v, platform)
    windows = platform.startswith("windows")
    readme = README.format(
        version=v,
        binary=binary,
        run=binary if windows else "./thresh",
        extra=MACOS if platform.startswith("macos") else "",
    )
    if windows:
        readme = readme.replace("\n", "\r\n")
    files = [(top + binary, exe, 0o755)]
    for name in ("LICENSE", "NOTICE"):
        with open(os.path.join(ROOT, name), "rb") as f:
            files.append((top + name, f.read(), 0o644))
    files.append((top + "README.txt", readme.encode(), 0o644))
    return files


def tar_gz(files: list) -> bytes:
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as t:
        top = files[0][0].split("/")[0]
        d = tarfile.TarInfo(top)
        d.type, d.mode, d.mtime = tarfile.DIRTYPE, 0o755, 0
        t.addfile(d)
        for path, data, mode in files:
            ti = tarfile.TarInfo(path)
            ti.size, ti.mode, ti.mtime = len(data), mode, 0
            t.addfile(ti, io.BytesIO(data))
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=0, filename="") as g:
        g.write(raw.getvalue())
    return out.getvalue()


def zip_(files: list) -> bytes:
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for path, data, mode in files:
            zi = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            zi.external_attr = (0o100000 | mode) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)
    return out.getvalue()


def main(argv: list) -> int:
    platforms = argv or list(PLATFORMS)
    unknown = [p for p in platforms if p not in PLATFORMS]
    if unknown:
        print("release_archives.py: no platform %s; the platforms are %s" % (unknown[0], ", ".join(PLATFORMS)), file=sys.stderr)
        return 2
    v = version()
    os.makedirs(OUT, exist_ok=True)
    for platform in platforms:
        print(platform, flush=True)
        files = contents(platform, v, build(platform))
        windows = platform.startswith("windows")
        name = "thresh-%s-%s%s" % (v, platform, ".zip" if windows else ".tar.gz")
        data = zip_(files) if windows else tar_gz(files)
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(data)
        print("  zig-out/release/%s, %d KB" % (name, len(data) // 1024), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
