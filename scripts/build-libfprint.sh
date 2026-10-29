#!/usr/bin/env bash
# 下载 libfprint 6f9479c、应用 0c3d 补丁、编译并安装到 /usr/local/lib/fprint-patched
set -euo pipefail

COMMIT=6f9479c
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$HOME/.cache/varmilo-fp}"
SRC="$WORK/libfprint-$COMMIT"
DEST=/usr/local/lib/fprint-patched

for t in meson ninja gcc pkg-config curl; do
  command -v "$t" >/dev/null ||
    { echo "缺少 $t。Arch: sudo pacman -S meson ninja base-devel glib2 libgusb pixman libusb"; exit 1; }
done

mkdir -p "$WORK"
if [[ ! -f $WORK/libfprint-$COMMIT.tar.gz ]]; then
  echo "下载 libfprint $COMMIT ..."
  curl -fSL -o "$WORK/libfprint-$COMMIT.tar.gz" \
    "https://gitlab.freedesktop.org/libfprint/libfprint/-/archive/$COMMIT/libfprint-$COMMIT.tar.gz"
fi

rm -rf "$SRC"
mkdir -p "$SRC"
tar xzf "$WORK/libfprint-$COMMIT.tar.gz" -C "$SRC" --strip-components=1

echo "应用补丁 ..."
patch -d "$SRC" -p1 < "$ROOT/patches/libfprint-0c3d.patch"

echo "编译（仅 elan 驱动）..."
cd "$SRC"
meson setup build \
  -Ddrivers=elan -Dintrospection=false -Ddoc=false \
  -Dinstalled-tests=false -Dudev_rules=disabled -Dudev_hwdb=disabled
ninja -C build

echo "安装到 $DEST ..."
sudo install -d "$DEST"
sudo install -m 0755 build/libfprint/libfprint-2.so.2.0.0 "$DEST"/
sudo ln -sf libfprint-2.so.2.0.0 "$DEST/libfprint-2.so.2"

sudo install -d /etc/systemd/system/fprintd.service.d
printf '[Service]\nEnvironment=LD_LIBRARY_PATH=%s\n' "$DEST" |
  sudo tee /etc/systemd/system/fprintd.service.d/zz-fprint-patched.conf >/dev/null

sudo systemctl daemon-reload
sudo systemctl restart fprintd
sleep 1

if sudo grep -q fprint-patched "/proc/$(systemctl show -p MainPID --value fprintd)/maps"; then
  echo "完成：fprintd 正在使用 $DEST/libfprint-2.so.2.0.0"
else
  echo "警告：fprintd 似乎没有加载补丁库，请检查 drop-in" >&2
  exit 1
fi
