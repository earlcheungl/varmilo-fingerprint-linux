#!/usr/bin/env bash
# 录入 + 验证 + 配置 PAM
# 用法: enroll.sh [press|swipe] [finger]
#   press（默认）: 按压录入，默认 left-index-finger
#   swipe        : 滑动录入，默认 right-index-finger
set -uo pipefail

MODE="${1:-press}"
case "$MODE" in
  press) FINGER="${2:-left-index-finger}" ;;
  swipe) FINGER="${2:-right-index-finger}" ;;
  *) echo "用法: $0 [press|swipe] [finger]"; exit 1 ;;
esac

LOG="$HOME/.cache/varmilo-fp/enroll-$MODE.log"
mkdir -p "$(dirname "$LOG")"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
bad() { printf '\033[1;31m%s\033[0m\n' "$*"; }
hot() { printf '\n\033[1;33m>>> %s <<<\033[0m\n\n' "$*"; }

countdown() { local n=$1 i; for ((i = n; i >= 1; i--)); do printf "\r  手离开键盘… %2d " "$i"; sleep 1; done; echo; }

[[ -f /usr/local/lib/fprint-patched/libfprint-2.so.2.0.0 ]] || {
  bad "补丁库未安装，先运行 scripts/build-libfprint.sh"; exit 1
}
command -v fprintd-enroll >/dev/null || { bad "fprintd 未安装"; exit 1; }

sudo -v || exit 1
sudo systemctl restart fprintd
sleep 1

if [[ $MODE == press ]]; then
  cat <<'EOF'

  按压模式：
    * 指腹盖满整个传感器，按住不动约 2 秒；
    * 完全抬起，停 5 秒，再按下一次；
    * 共 6 次。不要移动、不要滑。

EOF
else
  cat <<'EOF'

  滑动模式：
    * 指腹贴住传感器，匀速滑过整个感应区，约 1.5 秒；
    * 滑完立刻抬手，停 5 秒再滑下一次；
    * 共 6 次。滑太短会只有不到 10 个特征点，基本必挂。

EOF
fi
read -r -p "准备好了按回车开始（倒数 8 秒期间手离开）…… " _ || true

countdown 8
sudo -n fprintd-enroll -f "$FINGER" "$USER" &
pid=$!
sleep 2
if [[ $MODE == press ]]; then
  hot "按下去、盖满、保持 2 秒、抬起；停 5 秒再按（共 6 次，手指：$FINGER）"
else
  hot "慢滑、滑满、滑完立刻抬手；停 5 秒再滑（共 6 次，手指：$FINGER）"
fi
if ! wait $pid; then
  bad "录入失败。日志：journalctl -b -u fprintd -o cat | grep -E 'background mean|Calibration failed'"
  exit 1
fi
ok "录入完成。"

say "验证（最多 3 次）"
verify_ok=0
for i in 1 2 3; do
  for ((k = 5; k >= 1; k--)); do printf "\r  准备… %2d " "$k"; sleep 1; done; echo
  fprintd-verify &
  pid=$!
  sleep 2
  if [[ $MODE == press ]]; then hot "再按一次（盖满、2 秒、抬起）"; else hot "再滑一次（滑满、立刻抬手）"; fi
  if wait $pid; then verify_ok=1; break; fi
  bad "no-match"
done

if [[ $verify_ok -ne 1 ]]; then
  bad "验证未通过。可重跑本脚本；或 journalctl -b -u fprintd -o cat | grep score 查看分数。"
  exit 1
fi
ok "验证通过。"

say "配置 PAM"
gate="auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed"

if ! grep -q pam_fprintd.so /etc/pam.d/sudo; then
  sudo sed -i '1i auth      sufficient pam_fprintd.so' /etc/pam.d/sudo
fi
if ! grep -q 'omarchy-hw-laptop-closed' /etc/pam.d/sudo; then
  sudo sed -i "/pam_fprintd\.so/i $gate" /etc/pam.d/sudo
fi

if [[ -f /etc/pam.d/polkit-1 ]]; then
  if ! grep -q 'pam_fprintd.so' /etc/pam.d/polkit-1; then
    sudo sed -i '1i auth      sufficient pam_fprintd.so' /etc/pam.d/polkit-1
  fi
  if ! grep -q 'omarchy-hw-laptop-closed' /etc/pam.d/polkit-1; then
    sudo sed -i "/pam_fprintd\.so/i $gate" /etc/pam.d/polkit-1
  fi
else
  sudo tee /etc/pam.d/polkit-1 >/dev/null <<PAMEOF
$gate
auth      sufficient pam_fprintd.so
auth      required pam_unix.so

account   required pam_unix.so
password  required pam_unix.so
session   required pam_unix.so
PAMEOF
fi

sudo tee /etc/pam.d/omarchy-lock-fingerprint >/dev/null <<'PAMEOF'
#%PAM-1.0
auth       required                    pam_fprintd.so
account    include                     system-local-login
PAMEOF

say "完成"
fprintd-list "$USER"
ok "sudo / polkit / 锁屏（Super+Ctrl+L）都可以用指纹。"
echo "自测：sudo -k; sudo -v"
