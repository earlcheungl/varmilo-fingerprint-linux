#!/usr/bin/env bash
# 诊断 sudo 的指纹链路：开 fprintd 调试 -> 实际跑一次 sudo -v -> 输出日志
set -uo pipefail

LOG="$HOME/.cache/varmilo-fp/diagnose-sudo.log"
mkdir -p "$(dirname "$LOG")"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
hot() { printf '\n\033[1;33m>>> %s <<<\033[0m\n\n' "$*"; }

DEBUG=/run/systemd/system/fprintd.service.d/zz-debug.conf
cleanup() {
  sudo rm -f "$DEBUG"
  sudo systemctl daemon-reload 2>/dev/null
  sudo systemctl restart fprintd 2>/dev/null || true
}
trap cleanup EXIT

sudo -v || exit 1

say "开启 fprintd 调试"
sudo install -d "$(dirname "$DEBUG")"
printf '[Service]\nEnvironment=G_MESSAGES_DEBUG=all\n' | sudo tee "$DEBUG" >/dev/null
sudo systemctl daemon-reload
sudo systemctl restart fprintd
sleep 1

cat <<'EOF'

  接下来会执行  sudo -k; sudo -v
  出现 "Place your finger ..." 时用已录入的手指按压/滑动一次；
  最多 3 次机会。如果回到密码提示，直接 Ctrl-C，不用输密码。

EOF
read -r -p "按回车开始…… " _ || true

hot "现在按/滑！"
sudo -k
sudo -v || true
echo
echo "（若卡在密码提示，按 Ctrl-C 结束）"

say "fprintd 侧"
journalctl -b -u fprintd -o cat --no-pager 2>/dev/null |
  grep -E "VerifyStart|ListEnrolled|probe minutiae|score|background mean|verify" | tail -25

say "sudo/PAM 侧"
journalctl -b --since "-3min" -o cat --no-pager 2>/dev/null |
  grep -iE "pam_fprintd|pam_exec\(sudo|pam_unix\(sudo:auth" | tail -12

say "结论提示"
echo "- 出现 probe minutiae 且 score >= 15 → 指纹链路正常"
echo "- 完全没有 VerifyStart → pam_fprintd 未被调用（检查 /etc/pam.d/sudo 前两行）"
echo "- probe minutiae < 10 → 采集质量不够，重按/重滑"
