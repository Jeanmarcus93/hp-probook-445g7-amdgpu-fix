#!/usr/bin/env bash
# Dump completo da ROM BAR PCI da GPU AMD e validacao do VBIOS.
#
# Pre-condicao: a GPU precisa ja ter sido POSTada pelo SBIOS (estado normal
# de boot — inclusive com simpledrm/nomodeset). Se a leitura der I/O error,
# reboot e rode de novo sem carregar o amdgpu.
#
# Uso: sudo bash dump_vbios_rom.sh [BDF] [saida]
#   BDF   endereco PCI (ex.: 0000:05:00.0). Padrao: primeira GPU AMD detectada.
#   saida arquivo de destino. Padrao: ./vbios_rombar.bin
set -euo pipefail

GPU="${1:-}"
OUT="${2:-$PWD/vbios_rombar.bin}"
CUR="/lib/firmware/amdgpu/vbios.bin"

if [ -z "$GPU" ]; then
  for d in /sys/bus/pci/devices/*; do
    read -r vend < "$d/vendor"
    read -r cls  < "$d/class"
    # vendor AMD/ATI (0x1002) + classe display (0x03xxxx)
    if [ "$vend" = "0x1002" ] && [ "${cls:2:2}" = "03" ]; then
      GPU=$(basename "$d")
      break
    fi
  done
fi
[ -n "$GPU" ] || { echo "ERRO: nenhuma GPU AMD encontrada (passe o BDF como 1o argumento)"; exit 1; }

ROM="/sys/bus/pci/devices/$GPU/rom"
echo "==> GPU: $GPU"
[ -e "$ROM" ] || { echo "ERRO: $ROM nao existe"; exit 1; }

echo "==> Habilitando ROM BAR e fazendo dump..."
echo 1 > "$ROM"
# le tudo; usa cat pois o tamanho efetivo pode diferir do BAR
if ! cat "$ROM" > "$OUT" 2>/dev/null; then
  echo "AVISO: cat reportou erro (pode ser normal — verificando tamanho)"
fi
echo 0 > "$ROM"
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER:$SUDO_USER" "$OUT" 2>/dev/null || true

SZ=$(stat -c '%s' "$OUT")
if [ "$SZ" -eq 0 ]; then
  echo "ERRO: dump vazio (I/O error na ROM BAR)."
  echo "      A GPU provavelmente nao foi POSTada. Reboot SEM carregar o amdgpu"
  echo "      (recovery/nomodeset se preciso) e rode de novo."
  exit 1
fi
echo "==> Dump salvo: $OUT ($SZ bytes)"

echo
echo "==> Validacao da imagem dumpada:"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/validate_vbios.py"
if [ -f "$VALIDATE" ]; then
  python3 "$VALIDATE" "$OUT" || {
    echo "ERRO: validacao do VBIOS falhou (veja acima)."
    echo "      Refaca o dump com a GPU POSTada (boot com simpledrm/nomodeset)."
    exit 1
  }
else
  # fallback manual se validate_vbios.py nao existir
  SIG=$(xxd -p -l 2 "$OUT")
  echo "    - assinatura inicial (esperado 55aa): $SIG"
  echo -n "    - contem 'ATOM'           : "; grep -aqc "ATOM" "$OUT" && echo "SIM" || echo "NAO"
  echo -n "    - contem 'ATOMBIOSBK-AMD' : "; grep -aq "ATOMBIOSBK" "$OUT" && echo "SIM" || echo "NAO"
  echo "    - strings de BIOS (amostra):"
  strings -n 8 "$OUT" | grep -iE "renoir|navi|D[0-9]{3}|xxx|BK-AMD|113-" | head -8 | sed 's/^/        /'
fi

echo
if [ -f "$CUR" ]; then
  echo "==> Comparacao com vbios.bin atual:"
  echo "    atual : $CUR ($(stat -c '%s' "$CUR") bytes)  sha256=$(sha256sum "$CUR" | cut -d' ' -f1)"
  echo "    novo  : $OUT ($SZ bytes)  sha256=$(sha256sum "$OUT" | cut -d' ' -f1)"
fi

echo
echo "==> Concluido. NAO instalei nada ainda — revise a validacao acima."
echo "    Se assinatura=55aa, ATOM=SIM e tamanho coerente (~54-64K), seguimos:"
echo "    sudo bash install_vbios.sh $OUT"
