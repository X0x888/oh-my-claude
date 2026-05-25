#!/usr/bin/env bash
#
# tools/build-release-assets.sh — build cross-platform deterministic
# source-bundle release assets plus a SHA256 manifest for vX.Y.Z.

set -euo pipefail

VERSION_ARG=""
OUT_DIR=""
REF_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: bash tools/build-release-assets.sh X.Y.Z [--out-dir <dir>] [--ref <git-ref>]

Builds the canonical attached release assets for vX.Y.Z:
  - oh-my-claude-vX.Y.Z.tar.gz
  - oh-my-claude-vX.Y.Z.zip
  - oh-my-claude-vX.Y.Z.SHA256SUMS

Options:
  --out-dir <dir>  Destination directory. When omitted, a temp dir is
                   created and the script prints the resulting file paths.
  --ref <git-ref>  Override the git ref to archive. Defaults to
                   vX.Y.Z^{commit}.
EOF
}

err() { printf 'build-release-assets: %s\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      OUT_DIR="$2"
      shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      REF_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'build-release-assets: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "${VERSION_ARG}" ]]; then
        VERSION_ARG="$1"
        shift
      else
        printf 'build-release-assets: unexpected positional arg: %s\n' "$1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

[[ -n "${VERSION_ARG}" ]] || { usage >&2; exit 2; }
[[ "${VERSION_ARG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "version must be X.Y.Z, got: ${VERSION_ARG}"
command -v git >/dev/null 2>&1 || err "git not found in PATH"
command -v python3 >/dev/null 2>&1 || err "python3 not found in PATH"
command -v tar >/dev/null 2>&1 || err "tar not found in PATH"

sha256_of_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
  else
    err "neither sha256sum nor shasum found in PATH"
  fi
}

REF_TO_ARCHIVE="${REF_OVERRIDE:-v${VERSION_ARG}^{commit}}"
if ! git rev-parse "${REF_TO_ARCHIVE}" >/dev/null 2>&1; then
  err "could not resolve archive ref: ${REF_TO_ARCHIVE}"
fi

if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="$(mktemp -d -t omc-release-assets-XXXXXX)"
fi
mkdir -p "${OUT_DIR}"

asset_stem="oh-my-claude-v${VERSION_ARG}"
tar_path="${OUT_DIR}/${asset_stem}.tar.gz"
zip_path="${OUT_DIR}/${asset_stem}.zip"
sums_path="${OUT_DIR}/${asset_stem}.SHA256SUMS"

stage_dir="$(mktemp -d -t omc-release-stage-XXXXXX)"
cleanup() {
  rm -rf "${stage_dir}"
}
trap cleanup EXIT

root_dir="${stage_dir}/${asset_stem}"
mkdir -p "${root_dir}"
git archive --format=tar "${REF_TO_ARCHIVE}" | tar -xf - -C "${root_dir}"

python3 - "${root_dir}" "${tar_path}" "${zip_path}" <<'PY'
import gzip
import os
import stat
import sys
import tarfile
import zipfile
from pathlib import Path

src_root = Path(sys.argv[1]).resolve()
tar_path = Path(sys.argv[2]).resolve()
zip_path = Path(sys.argv[3]).resolve()
root_name = src_root.name

# Earliest ZIP timestamp; also stable for tar directory/file metadata.
FIXED_TS = 315532800  # 1980-01-01T00:00:00Z
FIXED_ZIP_DT = (1980, 1, 1, 0, 0, 0)


def sorted_entries(base: Path):
    dir_entries = []
    file_entries = []
    for path in sorted(base.rglob("*")):
        rel = path.relative_to(base).as_posix()
        if path.is_dir():
            dir_entries.append(rel)
        else:
            file_entries.append(rel)
    return dir_entries, file_entries


def add_tar_directory(tf: tarfile.TarFile, name: str):
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = 0o755
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = FIXED_TS
    tf.addfile(info)


def add_tar_path(tf: tarfile.TarFile, path: Path, rel: str):
    arcname = f"{root_name}/{rel}"
    st = path.lstat()
    mode = stat.S_IMODE(st.st_mode)
    if path.is_symlink():
        info = tarfile.TarInfo(arcname)
        info.type = tarfile.SYMTYPE
        info.mode = 0o777
        info.uid = 0
        info.gid = 0
        info.uname = ""
        info.gname = ""
        info.mtime = FIXED_TS
        info.linkname = os.readlink(path)
        tf.addfile(info)
        return
    info = tarfile.TarInfo(arcname)
    info.size = st.st_size
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = FIXED_TS
    with path.open("rb") as fh:
        tf.addfile(info, fh)


def directory_zipinfo(name: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, FIXED_ZIP_DT)
    info.create_system = 3
    info.external_attr = (0o755 << 16) | 0x10
    info.compress_type = zipfile.ZIP_STORED
    return info


def path_zipinfo(path: Path, rel: str) -> zipfile.ZipInfo:
    st = path.lstat()
    mode = stat.S_IMODE(st.st_mode)
    info = zipfile.ZipInfo(f"{root_name}/{rel}", FIXED_ZIP_DT)
    info.create_system = 3
    if path.is_symlink():
        info.external_attr = (0o120777 << 16)
        info.compress_type = zipfile.ZIP_STORED
    else:
        info.external_attr = (mode << 16)
        info.compress_type = zipfile.ZIP_DEFLATED
    return info


dir_entries, file_entries = sorted_entries(src_root)

with tar_path.open("wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tf:
            add_tar_directory(tf, root_name)
            for rel in dir_entries:
                add_tar_directory(tf, f"{root_name}/{rel}")
            for rel in file_entries:
                add_tar_path(tf, src_root / rel, rel)

with zipfile.ZipFile(zip_path, mode="w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    zf.writestr(directory_zipinfo(f"{root_name}/"), b"")
    for rel in dir_entries:
        zf.writestr(directory_zipinfo(f"{root_name}/{rel}/"), b"")
    for rel in file_entries:
        path = src_root / rel
        info = path_zipinfo(path, rel)
        if path.is_symlink():
            zf.writestr(info, os.readlink(path).encode("utf-8"))
        else:
            zf.writestr(info, path.read_bytes())
PY

(
  cd "${OUT_DIR}" || exit 1
  tar_hash="$(sha256_of_file "${asset_stem}.tar.gz")"
  zip_hash="$(sha256_of_file "${asset_stem}.zip")"
  {
    printf '%s  %s\n' "${tar_hash}" "${asset_stem}.tar.gz"
    printf '%s  %s\n' "${zip_hash}" "${asset_stem}.zip"
  } > "${asset_stem}.SHA256SUMS"
)

printf '%s\n%s\n%s\n' "${tar_path}" "${zip_path}" "${sums_path}"
