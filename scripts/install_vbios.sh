#!/usr/bin/env bash
# Instala o VBIOS integro (dump da ROM BAR) como vbios.bin, com backup, e regenera initrd.
# Uso: sudo bash install_vbios.sh [dump]
#   dump  arquivo do dump da ROM BAR. Padrao: ./vbios_rombar.bin
set -euo pipefail

SRC="${1:-$PWD/vbios_rombar.bin}"
TS=$(date +%Y%m%d-%H%M%S)

[ "$(id -u)" -eq 0 ] || { echo "Rode como root (sudo)."; exit 1; }
[ -f "$SRC" ] || { echo "ERRO: $SRC nao existe (rode dump_vbios_rom.sh antes)"; exit 1; }

# valida a estrutura antes de instalar (assinatura + checksum + ATOM)
python3 - "$SRC" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
decl=d[2]*512
assert d[:2]==b'\x55\xaa', "assinatura invalida"
assert (sum(d[:decl])&0xff)==0, "checksum invalido"
assert b'ATOMBIOSBK' in d, "sem ATOMBIOSBK"
print("  fonte validada: 55aa + checksum 0 + ATOMBIOSBK ok")
PY

for D in /lib/firmware/amdgpu /usr/lib/firmware/amdgpu; do
  mkdir -p "$D"
  if [ -f "$D/vbios.bin" ]; then
    cp -a "$D/vbios.bin" "$D/vbios.bin.bak-$TS"
    echo "  backup: $D/vbios.bin.bak-$TS"
  fi
  install -m 0644 "$SRC" "$D/vbios.bin"
  echo "  instalado: $D/vbios.bin  sha256=$(sha256sum "$D/vbios.bin" | cut -d' ' -f1)"
done

if [ "${SKIP_INITRAMFS:-0}" = 1 ]; then
  echo "==> SKIP_INITRAMFS=1: initramfs sera regenerado depois"
else
  echo "==> Regenerando initramfs (kernel atual)..."
  update-initramfs -u -k "$(uname -r)"
fi

echo "==> Verificacao final do instalado:"
python3 - /lib/firmware/amdgpu/vbios.bin <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
decl=d[2]*512
print(f"  checksum_mod256={sum(d[:decl])&0xff} -> {'INTEGRO' if (sum(d[:decl])&0xff)==0 else 'ERRO'}")
PY
echo "==> OK. Proximo passo: sudo bash build_dkms.sh"
