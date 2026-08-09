#!/bin/sh
set -eu

usage() {
    printf 'usage: package-local-app.sh [--ad-hoc-sign] <absolute-output-app>\n' >&2
    exit 64
}

sign=0
if [ "${1-}" = "--ad-hoc-sign" ]; then
    sign=1
    shift
fi
[ "$#" -eq 1 ] || usage
destination=$1
case "$destination" in
    /*) ;;
    *) printf 'destination must be absolute\n' >&2; exit 64 ;;
esac

script_dir=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -P -- "$script_dir/.." && pwd)

python3 - "$root" "$destination" <<'PY'
import pathlib
import stat
import sys
root = pathlib.Path(sys.argv[1]).resolve()
requested = pathlib.Path(sys.argv[2])
destination = requested.resolve(strict=False)
try:
    destination.relative_to(root)
except ValueError:
    pass
else:
    raise SystemExit("destination must be outside repository")
for ancestor in (requested.parent, *requested.parent.parents):
    try:
        metadata = ancestor.lstat()
    except FileNotFoundError:
        continue
    if stat.S_ISLNK(metadata.st_mode) and metadata.st_uid != 0:
        raise SystemExit("destination ancestors must not contain user-owned symlinks")
PY

if [ -e "$destination" ] || [ -L "$destination" ]; then
    printf 'destination already exists\n' >&2
    exit 73
fi
parent=$(dirname -- "$destination")
[ -d "$parent" ] || { printf 'destination parent does not exist\n' >&2; exit 73; }
[ ! -L "$parent" ] || { printf 'destination parent must not be a symlink\n' >&2; exit 73; }

cd "$root"
python3 -B scripts/verify-release-metadata.py >/dev/null
swift build -c release -Xswiftc -warnings-as-errors >&2

if [ "$sign" -eq 1 ]; then
    codesign --force --sign - .build/release/NextUp >/dev/null
fi

umask 077
temporary=$(mktemp -d "$parent/.nextup-package.XXXXXX")
exec 9< "$temporary"
cleanup() {
    python3 - "$temporary" 9 <<'PY' || true
import errno
import os
import stat
import sys

path = sys.argv[1]
descriptor = int(sys.argv[2])
original = os.fstat(descriptor)

def clear(directory: int) -> None:
    for name in os.listdir(directory):
        try:
            child = os.open(
                name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=directory,
            )
        except OSError as error:
            if error.errno not in (errno.ENOTDIR, errno.ELOOP):
                raise
            os.unlink(name, dir_fd=directory)
            continue
        try:
            clear(child)
        finally:
            os.close(child)
        os.rmdir(name, dir_fd=directory)

clear(descriptor)
try:
    current = os.stat(path, follow_symlinks=False)
except FileNotFoundError:
    pass
else:
    if stat.S_ISDIR(current.st_mode) and (
        current.st_dev,
        current.st_ino,
    ) == (original.st_dev, original.st_ino):
        os.rmdir(path)
PY
}
trap cleanup EXIT HUP INT TERM

bound_temporary=$(python3 - 9 <<'PY'
import fcntl
import os
import shutil
import sys

descriptor = int(sys.argv[1])
os.mkdir("Contents", mode=0o700, dir_fd=descriptor)
contents = os.open("Contents", os.O_RDONLY | os.O_DIRECTORY, dir_fd=descriptor)
try:
    os.mkdir("MacOS", mode=0o700, dir_fd=contents)
    macos = os.open("MacOS", os.O_RDONLY | os.O_DIRECTORY, dir_fd=contents)
    try:
        source = os.open(".build/release/NextUp", os.O_RDONLY)
        destination = os.open(
            "NextUp",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            mode=0o755,
            dir_fd=macos,
        )
        try:
            with os.fdopen(source, "rb", closefd=False) as input_file:
                with os.fdopen(destination, "wb", closefd=False) as output_file:
                    shutil.copyfileobj(input_file, output_file)
        finally:
            os.close(source)
            os.close(destination)
    finally:
        os.close(macos)
    source = os.open("packaging/Info.plist", os.O_RDONLY)
    destination = os.open(
        "Info.plist",
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        mode=0o600,
        dir_fd=contents,
    )
    try:
        with os.fdopen(source, "rb", closefd=False) as input_file:
            with os.fdopen(destination, "wb", closefd=False) as output_file:
                shutil.copyfileobj(input_file, output_file)
    finally:
        os.close(source)
        os.close(destination)
finally:
    os.close(contents)

path = fcntl.fcntl(descriptor, 50, b"\0" * 1024).split(b"\0", 1)[0]
print(os.fsdecode(path))
PY
)

if [ "$sign" -eq 1 ]; then
    codesign --force --sign - "$bound_temporary" >/dev/null
    # Keep the release-build receipt byte-identical to the executable that
    # bundle signing finalized, so downstream hash verification has one truth.
    cp "$bound_temporary/Contents/MacOS/NextUp" .build/release/NextUp
fi
python3 - "$parent" "$(basename -- "$temporary")" "$(basename -- "$destination")" 9 <<'PY'
import ctypes
import errno
import os
import sys

parent, source_name, destination_name = sys.argv[1:4]
source_descriptor = int(sys.argv[4])
directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
try:
    source = os.fstat(source_descriptor)
    current = os.stat(source_name, dir_fd=directory, follow_symlinks=False)
    if (source.st_dev, source.st_ino) != (current.st_dev, current.st_ino):
        raise SystemExit("private package directory was substituted")
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameatx_np
    rename.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    rename.restype = ctypes.c_int
    rename_exclusive = 0x00000004
    status = rename(
        directory,
        os.fsencode(source_name),
        directory,
        os.fsencode(destination_name),
        rename_exclusive,
    )
    if status != 0:
        error = ctypes.get_errno()
        if error == errno.EEXIST:
            raise SystemExit("destination appeared before publish")
        raise OSError(error, os.strerror(error))
finally:
    os.close(directory)
PY
trap - EXIT HUP INT TERM
exec 9<&-

version=$(tr -d '\r\n' < VERSION)
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$destination/Contents/Info.plist")
hash=$(shasum -a 256 "$destination/Contents/MacOS/NextUp" | cut -d ' ' -f 1)
printf 'version=%s\nbuild=%s\nexecutable_sha256=%s\n' "$version" "$build" "$hash"
