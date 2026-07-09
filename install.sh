#!/usr/bin/env bash
# Instalador completo do fix de tela preta do amdgpu (HP ProBook 445 G7 / AMD Renoir).
#
# Executa, em ordem:
#   1. dump do VBIOS real da ROM BAR (a GPU precisa estar POSTada — boot com
#      simpledrm/nomodeset serve);
#   2. instalacao do vbios.bin em /lib/firmware/amdgpu/;
#   3. build + instalacao do modulo amdgpu patcheado via DKMS;
#   4. carga antecipada via dracut + regeneracao do initramfs.
#
# Depois: REBOOT pela entrada normal do GRUB.
#
# Uso: sudo bash install.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$REPO_DIR/scripts"
DUMP="$REPO_DIR/vbios_rombar.bin"

[ "$(id -u)" -eq 0 ] || { echo "Rode como root: sudo bash install.sh"; exit 1; }

echo "########################################################"
echo "## amdgpu-rombar — fix de tela preta AMD Renoir       ##"
echo "## kernel alvo: $(uname -r)"
echo "########################################################"
echo

echo "### PASSO 1/4: dump do VBIOS real (ROM BAR) ###"
bash "$S/dump_vbios_rom.sh" "" "$DUMP"
echo

echo "### PASSO 2/4: instalar vbios.bin ###"
SKIP_INITRAMFS=1 bash "$S/install_vbios.sh" "$DUMP"
echo

echo "### PASSO 3/4: build + install do modulo DKMS ###"
bash "$S/build_dkms.sh"
echo

echo "### PASSO 4/4: tornar permanente (dracut + initramfs) ###"
bash "$S/make_amdgpu_permanent.sh"
echo

echo "########################################################"
echo "## CONCLUIDO. Reinicie pela entrada normal do GRUB.   ##"
echo "##                                                    ##"
echo "## Teste opcional SEM reboot (com auto-recuperacao):  ##"
echo "##   sudo bash scripts/test_amdgpu_real.sh            ##"
echo "########################################################"
