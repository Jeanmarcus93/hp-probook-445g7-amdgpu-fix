#!/usr/bin/env bash
# Dump completo da ROM BAR PCI da GPU Renoir e validacao do VBIOS.
# Uso: sudo bash dump_vbios_rom.sh
set -euo pipefail

GPU="0000:05:00.0"
ROM="/sys/bus/pci/devices/$GPU/rom"
OUT="/home/jean-kegler/vbios_rombar.bin"
CUR="/lib/firmware/amdgpu/vbios.bin"

echo "==> GPU: $GPU"
[ -e "$ROM" ] || { echo "ERRO: $ROM nao existe"; exit 1; }

echo "==> Habilitando ROM BAR e fazendo dump..."
echo 1 > "$ROM"
# le tudo; usa cat pois o tamanho efetivo pode diferir do BAR
cat "$ROM" > "$OUT" 2>/dev/null || true
echo 0 > "$ROM"
chown jean-kegler:jean-kegler "$OUT" 2>/dev/null || true

SZ=$(stat -c '%s' "$OUT")
echo "==> Dump salvo: $OUT ($SZ bytes)"

echo
echo "==> Validacao da imagem dumpada:"
# 1) assinatura de ROM 0x55AA nos 2 primeiros bytes
SIG=$(xxd -p -l 2 "$OUT")
echo "    - assinatura inicial (esperado 55aa): $SIG"
# 2) string ATOM / "ATOMBIOSBK" em algum offset
echo -n "    - contem 'ATOM'           : "; grep -aqc "ATOM" "$OUT" && echo "SIM" || echo "NAO"
echo -n "    - contem 'ATOMBIOSBK-AMD' : "; grep -aq "ATOMBIOSBK" "$OUT" && echo "SIM" || echo "NAO"
# 3) string do build/part number da BIOS (ajuda a confirmar Renoir)
echo "    - strings de BIOS (amostra):"
strings -n 8 "$OUT" | grep -iE "renoir|navi|D[0-9]{3}|xxx|BK-AMD|113-" | head -8 | sed 's/^/        /'
# 4) tamanho efetivo > 54784 indica imagem mais completa
echo
echo "==> Comparacao com vbios.bin atual:"
echo "    atual : $CUR ($(stat -c '%s' "$CUR") bytes)  sha256=$(sha256sum "$CUR" | cut -d' ' -f1)"
echo "    novo  : $OUT ($SZ bytes)  sha256=$(sha256sum "$OUT" | cut -d' ' -f1)"

echo
echo "==> Concluido. NAO instalei nada ainda — revise a validacao acima."
echo "    Se assinatura=55aa, ATOM=SIM e tamanho coerente (~64K), seguimos para instalar."
