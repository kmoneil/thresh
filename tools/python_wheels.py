"""Builds threshio's wheels into zig-out/wheels: for each platform, libthresh
built by Zig (ReleaseSafe, without debug information) beside
python/src/threshio. ctypes needs no CPython ABI, so each is tagged
py3-none-<platform>. libthresh links libc, so Linux has a wheel for glibc
(built against 2.17, which manylinux2014 is) and one for musl. The wheels
are written byte for byte the same from the same libraries.

    python3 -I tools/python_wheels.py                  # every platform
    python3 -I tools/python_wheels.py aarch64-macos    # some

(The shape of this script is dateparsa's tools/python_wheels.py.)
"""

import base64
import hashlib
import io
import os
import re
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIBS = os.path.join(ROOT, "zig-out", "wheel-libs")
OUT = os.path.join(ROOT, "zig-out", "wheels")

# A platform: the target Zig builds for, the wheel's platform tags, where
# the build puts the shared library, and the name the package loads it by.
PLATFORMS = {
    "x86_64-linux-gnu": ("x86_64-linux-gnu.2.17", "manylinux_2_17_x86_64.manylinux2014_x86_64", "lib/libthresh.so", "libthresh.so"),
    "aarch64-linux-gnu": ("aarch64-linux-gnu.2.17", "manylinux_2_17_aarch64.manylinux2014_aarch64", "lib/libthresh.so", "libthresh.so"),
    "x86_64-linux-musl": ("x86_64-linux-musl", "musllinux_1_2_x86_64", "lib/libthresh.so", "libthresh.so"),
    "aarch64-linux-musl": ("aarch64-linux-musl", "musllinux_1_2_aarch64", "lib/libthresh.so", "libthresh.so"),
    "x86_64-macos": ("x86_64-macos.13.0", "macosx_13_0_x86_64", "lib/libthresh.dylib", "libthresh.dylib"),
    "aarch64-macos": ("aarch64-macos.13.0", "macosx_13_0_arm64", "lib/libthresh.dylib", "libthresh.dylib"),
    "x86_64-windows": ("x86_64-windows", "win_amd64", "bin/libthresh.dll", "libthresh.dll"),
    "aarch64-windows": ("aarch64-windows", "win_arm64", "bin/libthresh.dll", "libthresh.dll"),
}

SUMMARY = (
    "Know a delimited file before your code reads it: its dialect, the schema "
    "its values fit, every row checked with a code for what is wrong, and the "
    "rows to pyarrow, polars or DuckDB without a copy."
)


def version() -> str:
    with open(os.path.join(ROOT, "build.zig.zon"), encoding="utf-8") as f:
        m = re.search(r'\.version\s*=\s*"([^"]+)"', f.read())
    if not m:
        sys.exit("python_wheels.py: no .version in build.zig.zon")
    return m.group(1)


def metadata(v: str) -> str:
    with open(os.path.join(ROOT, "python", "README.md"), encoding="utf-8") as f:
        readme = f.read()
    headers = [
        "Metadata-Version: 2.4",
        "Name: threshio",
        "Version: " + v,
        "Summary: " + SUMMARY,
        "Author: Kevin O'Neil",
        "License-Expression: Apache-2.0",
        "License-File: LICENSE",
        "License-File: NOTICE",
        "Project-URL: Source, https://github.com/kmoneil/thresh",
        "Project-URL: Documentation, https://github.com/kmoneil/thresh/tree/main/python",
        "Project-URL: Issues, https://github.com/kmoneil/thresh/issues",
        "Keywords: csv,tsv,delimited,dialect,schema,validation,data-quality,arrow,pyarrow,polars,duckdb",
        "Classifier: Development Status :: 4 - Beta",
        "Classifier: Intended Audience :: Developers",
        "Classifier: Operating System :: MacOS",
        "Classifier: Operating System :: Microsoft :: Windows",
        "Classifier: Operating System :: POSIX :: Linux",
        "Classifier: Programming Language :: Python :: 3",
        "Classifier: Topic :: Scientific/Engineering :: Information Analysis",
        "Classifier: Topic :: Text Processing",
        "Classifier: Typing :: Typed",
        "Requires-Python: >=3.9",
        "Description-Content-Type: text/markdown",
    ]
    return "\n".join(headers) + "\n\n" + readme


def wheel_file(tags: str) -> str:
    lines = ["Wheel-Version: 1.0", "Generator: thresh tools/python_wheels.py", "Root-Is-Purelib: false"]
    lines += ["Tag: py3-none-" + t for t in tags.split(".")]
    return "\n".join(lines) + "\n"


def record_hash(data: bytes) -> str:
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=")
    return "sha256=" + digest.decode()


def build_lib(platform: str) -> bytes:
    target, _, lib_path, _ = PLATFORMS[platform]
    prefix = os.path.join(LIBS, platform)
    cmd = ["zig", "build", "--release", "-Dstrip", "-Dtarget=" + target, "-p", prefix]
    print("  " + " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=ROOT, check=True)
    with open(os.path.join(prefix, lib_path), "rb") as f:
        return f.read()


def build_wheel(platform: str, v: str, lib: bytes) -> str:
    _, tags, _, lib_name = PLATFORMS[platform]
    src = os.path.join(ROOT, "python", "src", "threshio")
    info = "threshio-%s.dist-info" % v
    files = []
    for name in sorted(os.listdir(src)):
        if name.endswith(".py") or name == "py.typed":
            with open(os.path.join(src, name), "rb") as f:
                files.append(("threshio/" + name, f.read(), 0o644))
    files.append(("threshio/" + lib_name, lib, 0o755))
    for name in ("LICENSE", "NOTICE"):
        with open(os.path.join(ROOT, name), "rb") as f:
            files.append(("%s/licenses/%s" % (info, name), f.read(), 0o644))
    files.append((info + "/METADATA", metadata(v).encode(), 0o644))
    files.append((info + "/WHEEL", wheel_file(tags).encode(), 0o644))
    record = "".join("%s,%s,%d\n" % (p, record_hash(d), len(d)) for p, d, _ in files)
    record += info + "/RECORD,,\n"
    files.append((info + "/RECORD", record.encode(), 0o644))

    name = "threshio-%s-py3-none-%s.whl" % (v, tags)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for path, data, mode in files:
            zi = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            zi.external_attr = (0o100000 | mode) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(buf.getvalue())
    return name


def main(argv: list) -> int:
    platforms = argv or list(PLATFORMS)
    unknown = [p for p in platforms if p not in PLATFORMS]
    if unknown:
        print("python_wheels.py: no platform %s; the platforms are %s" % (unknown[0], ", ".join(PLATFORMS)), file=sys.stderr)
        return 2
    v = version()
    os.makedirs(OUT, exist_ok=True)
    for platform in platforms:
        print(platform, flush=True)
        name = build_wheel(platform, v, build_lib(platform))
        size = os.path.getsize(os.path.join(OUT, name))
        print("  zig-out/wheels/%s, %d KB" % (name, size // 1024), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
