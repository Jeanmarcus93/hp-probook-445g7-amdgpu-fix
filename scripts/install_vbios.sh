#!/usr/bin/env bash
# Instala o VBIOS integro (dump da ROM BAR) como vbios.bin, com backup, e regenera initrd.
# Uso: sudo bash install_vbios.sh [dump]
#   dump  arquivo do dump da ROM BAR. Padrao: ./vbios_rombar.bin
set -euo pipefail

SRC="${1:-$PWD/vbios_rombar.bin}"
TS=$(date +%Y%m%d-%H%M%S)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/validate_vbios.py"

[ "$(id -u)" -eq 0 ] || { echo "Rode como root (sudo)."; exit 1; }
[ -f "$SRC" ] || { echo "ERRO: $SRC nao existe (rode dump_vbios_rom.sh antes)"; exit 1; }

# valida a estrutura antes de instalar (assinatura + checksum + ATOM + conteudo)
echo "==> Validando $SRC..."
if [ -f "$VALIDATE" ]; then
  python3 "$VALIDATE" "$SRC" --require-edp || {
    echo "ERRO: validacao do VBIOS falhou (veja acima)."
    echo "      Se o dump foi feito com a GPU POSTada, verifique a saida."
    exit 1
  }
else
  # fallback: validacao estrutural minima inline
  python3 - "$SRC" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
decl=d[2]*512
assert d[:2]==b'\x55\xaa', "assinatura invalida"
assert (sum(d[:decl])&0xff)==0, "checksum invalido"
assert b'ATOMBIOSBK' in d, "sem ATOMBIOSBK"
print("  fonte validada: 55aa + checksum 0 + ATOMBIOSBK ok")
PY
fi

# --- instalacao ---
D=/lib/firmware/amdgpu
mkdir -p "$D"
if [ -f "$D/vbios.bin" ]; then
  cp -a "$D/vbios.bin" "$D/vbios.bin.bak-$TS"
  echo "  backup: $D/vbios.bin.bak-$TS"
fi
install -m 0644 "$SRC" "$D/vbios.bin"
echo "  instalado: $D/vbios.bin  sha256=$(sha256sum "$D/vbios.bin" | cut -d' ' -f1)"
# tambem em /usr/lib se for distinto (sistemas pre-merged-usr)
if [ -d /usr/lib/firmware/amdgpu ] && [ "/lib/firmware/amdgpu" != "/usr/lib/firmware/amdgpu" ]; then
  D2=/usr/lib/firmware/amdgpu
  if [ -f "$D2/vbios.bin" ]; then
    cp -a "$D2/vbios.bin" "$D2/vbios.bin.bak-$TS"
    echo "  backup: $D2/vbios.bin.bak-$TS"
  fi
  install -m 0644 "$SRC" "$D2/vbios.bin"
  echo "  instalado: $D2/vbios.bin  sha256=$(sha256sum "$D2/vbios.bin" | cut -d' ' -f1)"
fi

if [ "${SKIP_INITRAMFS:-0}" = 1 ]; then
  echo "==> SKIP_INITRAMFS=1: initramfs sera regenerado depois"
else
  echo "==> Regenerando initramfs (kernel atual)..."
  update-initramfs -u -k "$(uname -r)"
fi

echo "==> Verificacao final do instalado:"
if [ -f "$VALIDATE" ]; then
  python3 "$VALIDATE" /lib/firmware/amdgpu/vbios.bin --require-edp || true
else
  python3 - /lib/firmware/amdgpu/vbios.bin <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
decl=d[2]*512
print(f"  checksum_mod256={sum(d[:decl])&0xff} -> {'INTEGRO' if (sum(d[:decl])&0xff)==0 else 'ERRO'}")
PY
fi
echo "==> OK. Proximo passo: sudo bash build_dkms.sh"
