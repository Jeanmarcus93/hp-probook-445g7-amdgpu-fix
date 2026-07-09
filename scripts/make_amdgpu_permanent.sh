#!/bin/bash
# Torna permanente o fix do amdgpu (HP ProBook 445 G7 / AMD Renoir).
# Pre-condicoes: vbios.bin real instalado (install_vbios.sh) e modulo DKMS
# construido (build_dkms.sh).
# Uso: sudo bash make_amdgpu_permanent.sh [kernelver]
set -euo pipefail

KVER="${1:-$(uname -r)}"
VBIOS=/lib/firmware/amdgpu/vbios.bin

if [ "$(id -u)" -ne 0 ]; then echo "Rode como root (sudo)."; exit 1; fi

echo "== 1/5 validar VBIOS instalado =="
[ -f "$VBIOS" ] || { echo "FALTA $VBIOS (rode install_vbios.sh)"; exit 1; }
python3 - "$VBIOS" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
decl=d[2]*512
assert d[:2]==b'\x55\xaa', "assinatura invalida"
assert (sum(d[:decl])&0xff)==0, "checksum invalido"
assert b'ATOMBIOSBK' in d, "sem ATOMBIOSBK"
print("  OK: 55aa + checksum 0 + ATOMBIOSBK")
PY
echo "  sha256: $(sha256sum "$VBIOS" | cut -d' ' -f1)"

echo "== 2/5 validar modulo patcheado =="
MODPATH=$(modinfo -F filename amdgpu -k "$KVER" 2>/dev/null || true)
case "$MODPATH" in
  */updates/dkms/*) echo "  OK: modulo DKMS ativo ($MODPATH)";;
  *) echo "  AVISO: modulo amdgpu nao vem de updates/dkms ($MODPATH)."
     echo "         Rode build_dkms.sh antes, ou confira 'dkms status'.";;
esac

echo "== 3/5 remover blacklist do amdgpu (deixa udev autocarregar) =="
rm -fv /etc/modprobe.d/blacklist-amdgpu-test.conf

echo "== 4/5 habilitar force-add do amdgpu no initramfs (dracut) =="
if [ -f /etc/dracut.conf.d/amdgpu.conf.disabled ]; then
  mv -v /etc/dracut.conf.d/amdgpu.conf.disabled /etc/dracut.conf.d/amdgpu.conf
elif [ -f /etc/dracut.conf.d/amdgpu.conf ]; then
  echo "  ja habilitado"
else
  echo 'add_drivers+=" amdgpu "' > /etc/dracut.conf.d/amdgpu.conf
  echo "  criado /etc/dracut.conf.d/amdgpu.conf"
fi

echo "== 5/5 regenerar initramfs ($KVER) e conferir conteudo =="
update-initramfs -u -k "$KVER"
if command -v lsinitrd >/dev/null 2>&1; then
  lsinitrd /boot/initrd.img-"$KVER" 2>/dev/null | grep -Ei 'amdgpu\.ko|amdgpu/vbios\.bin' || \
    echo "  AVISO: nao encontrei amdgpu.ko/vbios.bin no initramfs (verifique)"
fi

cat <<'EOF'

PRONTO. Agora REINICIE pela entrada NORMAL do GRUB.
Esperado: painel acende direto na resolucao nativa, card = amdgpu.

Rede de seguranca: recovery (nomodeset) no GRUB ainda da simpledrm.
REVERTER este fix:
  printf 'blacklist amdgpu\n' > /etc/modprobe.d/blacklist-amdgpu-test.conf
  mv /etc/dracut.conf.d/amdgpu.conf /etc/dracut.conf.d/amdgpu.conf.disabled
  update-initramfs -u -k $(uname -r)

Como o modulo e DKMS (AUTOINSTALL=yes), updates de kernel via apt
reconstroem o modulo sozinhos — nao precisa de apt-mark hold.
EOF
