#!/usr/bin/env bash
# Monta a arvore DKMS do amdgpu patcheado e instala o modulo.
#
# Faz tudo que antes era manual:
#   1. obtem o source do kernel (pacote linux-source-X.Y.Z do apt);
#   2. extrai APENAS drivers/gpu/drm/amd (a arvore e autocontida:
#      FULL_AMD_PATH=$(src)/.. no Makefile do amdgpu);
#   3. aplica os 2 patches (file-load de VBIOS + fix de underflow de HPD);
#   4. instala em /usr/src/amdgpu-rombar-<versao> com dkms.conf + Makefile;
#   5. dkms add/build/install para o kernel alvo.
#
# O build e EXTMOD contra o headers package do kernel alvo, entao CRC de
# modversions, autoconf (CONFIG_DEBUG_INFO_BTF_MODULES) e layout de struct
# module saem corretos automaticamente — sem hacks de Module.symvers/KCFLAGS.
#
# Uso: sudo bash build_dkms.sh [kernelver]
#   kernelver  kernel alvo (ex.: 7.0.0-27-generic). Padrao: uname -r
set -euo pipefail

NAME=amdgpu-rombar
KVER="${1:-$(uname -r)}"
KBASE="${KVER%%-*}"                       # 7.0.0-27-generic -> 7.0.0
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="/usr/src/$NAME-$KBASE"
WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/$NAME-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

[ "$(id -u)" -eq 0 ] || { echo "Rode como root (sudo)."; exit 1; }

echo "== 1/6 pre-requisitos =="
[ -e "/lib/modules/$KVER/build" ] || {
  echo "ERRO: headers do kernel $KVER ausentes."
  echo "      sudo apt install linux-headers-$KVER"
  exit 1
}
MISSING=""
for t in dkms patch flex bison; do
  command -v "$t" >/dev/null || MISSING="$MISSING $t"
done
dpkg -s libelf-dev >/dev/null 2>&1 || MISSING="$MISSING libelf-dev"
[ -z "$MISSING" ] || { echo "ERRO: falta instalar:$MISSING"; echo "      sudo apt install$MISSING"; exit 1; }
echo "  OK (headers $KVER + dkms/patch/flex/bison/libelf-dev)"

echo "== 2/6 obter source do kernel (linux-source-$KBASE) =="
TARBALL=""
# ja instalado? (shopt -s nullglob evita que o glob literal entre no loop)
shopt -s nullglob
for f in /usr/src/linux-source-$KBASE/linux-source-$KBASE.tar.*; do
  TARBALL="$f" && break
done
shopt -u nullglob
if [ -z "$TARBALL" ]; then
  echo "  baixando o pacote linux-source-$KBASE (~200 MB, so desta vez)..."
  (cd "$WORK" && apt-get download "linux-source-$KBASE")
  DEB=$(ls "$WORK"/linux-source-"$KBASE"_*.deb)
  dpkg-deb --fsys-tarfile "$DEB" \
    | tar -x -C "$WORK" --wildcards '*linux-source-*.tar.*'
  rm -f "$DEB"
  TARBALL=$(find "$WORK" -name "linux-source-$KBASE.tar.*" | head -1)
fi
[ -n "$TARBALL" ] && [ -f "$TARBALL" ] || { echo "ERRO: tarball do source nao encontrado"; exit 1; }
echo "  source: $TARBALL"

echo "== 3/6 extrair drivers/gpu/drm/amd =="
mkdir -p "$WORK/build"
tar -xf "$TARBALL" -C "$WORK/build" --strip-components=4 \
  --wildcards '*/drivers/gpu/drm/amd'
[ -d "$WORK/build/amd/amdgpu" ] || { echo "ERRO: extracao falhou"; exit 1; }
echo "  OK ($(du -sh "$WORK/build/amd" | cut -f1))"

echo "== 4/6 aplicar patches =="
for p in "$REPO_DIR"/patches/*.patch; do
  echo "  - $(basename "$p")"
  # patches usam a/drivers/gpu/drm/amd/... ; a arvore local comeca em amd/ -> -p4
  patch -p4 -d "$WORK/build" --no-backup-if-mismatch < "$p"
done
grep -q 'amdgpu_read_bios_from_file' "$WORK/build/amd/amdgpu/amdgpu_bios.c" \
  || { echo "ERRO: patch do file-load nao aplicou"; exit 1; }

echo "== 5/6 instalar arvore DKMS em $DEST =="
# remover registro/arvore antigos, se existirem
if dkms status "$NAME/$KBASE" 2>/dev/null | grep -q "$NAME"; then
  dkms remove "$NAME/$KBASE" --all || true
fi
rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$WORK/build/amd" "$DEST/amd"
install -m 0644 "$REPO_DIR/dkms/Makefile" "$DEST/Makefile"
sed "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"$KBASE\"/" \
  "$REPO_DIR/dkms/dkms.conf" > "$DEST/dkms.conf"
echo "  OK"

echo "== 6/6 dkms add/build/install ($KVER) =="
dkms add "$NAME/$KBASE"
dkms build "$NAME/$KBASE" -k "$KVER"
dkms install "$NAME/$KBASE" -k "$KVER"

echo
echo "==> Modulo instalado:"
modinfo -F filename amdgpu -k "$KVER" || true
modinfo amdgpu -k "$KVER" | grep -E 'vbios\.bin|^vermagic' || true

if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
  echo
  echo "AVISO: Secure Boot ATIVO. O modulo DKMS precisa estar assinado com uma"
  echo "       chave MOK enrolada (o dkms do Ubuntu assina sozinho se a MOK de"
  echo "       /var/lib/shim-signed/mok/ existir e estiver enrolada)."
fi

echo
echo "==> OK. Proximo passo: sudo bash make_amdgpu_permanent.sh"
