#!/usr/bin/env bash
# Instala o VBIOS integro (dump da ROM BAR) como vbios.bin, com backup, e regenera initrd.
set -euo pipefail
SRC="/home/jean-kegler/vbios_rombar.bin"
TS=$(date +%Y%m%d-%H%M%S)

# valida fonte antes de instalar
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
  if [ -f "$D/vbios.bin" ]; then
    cp -a "$D/vbios.bin" "$D/vbios.bin.corrompido-$TS"
    echo "  backup: $D/vbios.bin.corrompido-$TS"
  fi
  install -m 0644 "$SRC" "$D/vbios.bin"
  echo "  instalado: $D/vbios.bin  sha256=$(sha256sum "$D/vbios.bin" | cut -d' ' -f1)"
done

echo "==> Regenerando initramfs (kernel atual)..."
update-initramfs -u -k "$(uname -r)"

echo "==> Verificacao final do instalado:"
python3 - /lib/firmware/amdgpu/vbios.bin <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
decl=d[2]*512
print(f"  checksum_mod256={sum(d[:decl])&0xff} -> {'INTEGRO' if (sum(d[:decl])&0xff)==0 else 'ERRO'}")
PY
echo "==> OK. Pronto para testar (reboot na entrada de teste ou modprobe controlado)."
