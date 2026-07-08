#!/bin/bash
# Torna permanente o fix do amdgpu (HP ProBook 445 G7 / AMD Renoir).
# Pre-condicao: amdgpu ja sobe limpo via `sudo modprobe amdgpu` com
# /lib/firmware/amdgpu/vbios.bin = VBIOS real da ROM BAR (sha256 e40fd9a8...).
# Roda como root: sudo ~/make_amdgpu_permanent.sh
set -euo pipefail

KVER=7.0.0-27-generic
VBIOS=/lib/firmware/amdgpu/vbios.bin
EXPECT_SHA=e40fd9a8f8a244d3dbea3c7e9834032740a2c0d71000aa1d81d61989cf95425a

if [ "$(id -u)" -ne 0 ]; then echo "Rode como root (sudo)."; exit 1; fi

echo "== 1/5 validar VBIOS real instalado =="
if [ ! -f "$VBIOS" ]; then echo "FALTA $VBIOS"; exit 1; fi
GOT_SHA=$(sha256sum "$VBIOS" | awk '{print $1}')
if [ "$GOT_SHA" != "$EXPECT_SHA" ]; then
  echo "AVISO: sha do vbios.bin ($GOT_SHA) != esperado ($EXPECT_SHA)."
  echo "       Esperado = VBIOS real da ROM BAR. Abortando por seguranca."
  exit 1
fi
echo "  OK ($GOT_SHA)"

echo "== 2/5 remover blacklist do amdgpu (deixa udev autocarregar) =="
rm -fv /etc/modprobe.d/blacklist-amdgpu-test.conf

echo "== 3/5 reabilitar force-add do amdgpu no initramfs (dracut) =="
if [ -f /etc/dracut.conf.d/amdgpu.conf.disabled ]; then
  mv -v /etc/dracut.conf.d/amdgpu.conf.disabled /etc/dracut.conf.d/amdgpu.conf
elif [ -f /etc/dracut.conf.d/amdgpu.conf ]; then
  echo "  ja habilitado"
else
  echo 'add_drivers+=" amdgpu "' > /etc/dracut.conf.d/amdgpu.conf
  echo "  recriado /etc/dracut.conf.d/amdgpu.conf"
fi

echo "== 4/5 regenerar initramfs ($KVER) =="
update-initramfs -u -k "$KVER"

echo "== 5/5 conferir amdgpu.ko + vbios.bin no initramfs =="
if command -v lsinitrd >/dev/null 2>&1; then
  lsinitrd /boot/initrd.img-"$KVER" 2>/dev/null | grep -Ei 'amdgpu\.ko|amdgpu/vbios\.bin' || \
    echo "  AVISO: nao encontrei amdgpu.ko/vbios.bin no initramfs (verifique)"
fi

cat <<'EOF'

PRONTO. Agora REINICIE pela entrada NORMAL do GRUB.
Esperado: painel acende direto em 1920x1080, card = amdgpu (sem flash p/ simpledrm).

Rede de seguranca: a entrada GRUB de recovery (nomodeset) ainda da simpledrm.
REVERTER este fix:
  printf 'blacklist amdgpu\n' > /etc/modprobe.d/blacklist-amdgpu-test.conf
  mv /etc/dracut.conf.d/amdgpu.conf /etc/dracut.conf.d/amdgpu.conf.disabled
  update-initramfs -u -k 7.0.0-27-generic

IMPORTANTE (sobreviver a updates de kernel): o amdgpu.ko e autocompilado para
7.0.0-27-generic. Um upgrade de kernel reverte o fix. Para segurar:
  apt-mark hold linux-image-7.0.0-27-generic
EOF
