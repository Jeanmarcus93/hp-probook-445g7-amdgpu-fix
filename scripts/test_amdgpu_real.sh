#!/usr/bin/env bash
# TESTE DECISIVO — carregar amdgpu com o VBIOS REAL (ROM BAR).
# Auto-recupera: se o painel NAO acender em ~90s, reinicia sozinho -> volta ao simpledrm.
# Rodar como root:  sudo bash test_amdgpu_real.sh
set -u

LOG=/var/log/amdgpu-realvbios-$(date +%Y%m%d-%H%M%S).txt
ln -sf "$LOG" /var/log/amdgpu-debug-latest.txt
echo "== TESTE amdgpu VBIOS real  $(date) ==" | tee "$LOG"

# journald persistente p/ ler o boot -1 depois do auto-reboot
mkdir -p /var/log/journal 2>/dev/null
systemctl restart systemd-journald 2>/dev/null

# captura continua do kernel ring buffer para o arquivo
dmesg --clear 2>/dev/null
( dmesg -w >> "$LOG" ) &
DW=$!

# debug DRM no maximo (diagnostico se falhar)
echo 0x16 > /sys/module/drm/parameters/debug 2>/dev/null

# WATCHDOG: reinicia em 90s salvo cancelamento (sucesso detectado)
( sleep 90
  echo "[watchdog] painel nao acendeu em 90s -> reboot p/ simpledrm" >> "$LOG"
  sync; sleep 1; systemctl reboot -f ) &
WD=$!
echo "[info] watchdog pid=$WD agendado p/ reboot em 90s (cancelado se der certo)" | tee -a "$LOG"

echo "[info] modprobe amdgpu ..." | tee -a "$LOG"
modprobe amdgpu 2>>"$LOG"

# espera o probe assentar e detecta sucesso = card ligado a amdgpu + eDP connected
OK=0
for i in $(seq 1 40); do
  sleep 1
  drv=""
  for d in /sys/class/drm/card*/device/driver; do
    [ -e "$d" ] && drv="$drv $(basename "$(readlink -f "$d")")"
  done
  edp="$(cat /sys/class/drm/card*-eDP-*/status 2>/dev/null | tr '\n' ' ')"
  if echo "$drv" | grep -qw amdgpu && echo "$edp" | grep -qw connected; then
    OK=1; break
  fi
done

sync
if [ "$OK" = 1 ]; then
  kill "$WD" 2>/dev/null           # CANCELA o reboot
  echo "============================================" | tee -a "$LOG"
  echo " SUCESSO: amdgpu + eDP connected. Painel deve estar ACESO." | tee -a "$LOG"
  echo " Watchdog cancelado. NAO vai reiniciar." | tee -a "$LOG"
  echo " Para tornar definitivo (boot normal):" | tee -a "$LOG"
  echo "   sudo bash make_amdgpu_permanent.sh" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  kill "$DW" 2>/dev/null            # para a captura continua, libera o script
  exit 0
else
  echo "[falha] amdgpu nao acendeu o eDP. driver=[$drv] eDP=[$edp]" | tee -a "$LOG"
  echo "[falha] watchdog vai reiniciar p/ simpledrm. Log: $LOG" | tee -a "$LOG"
  # deixa o watchdog reiniciar (nao matamos $WD); kill da captura p/ flush
  sync
  kill "$DW" 2>/dev/null
fi
