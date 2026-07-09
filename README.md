# correção amdgpu para HP ProBook 445 G7 — tela preta AMD Renoir

Correção do bug de tela preta no HP ProBook 445 G7 (iGPU AMD Renoir) no
Ubuntu 26.04 / kernel 7.0.0-27-generic.

**Status: ✅ RESOLVIDO E PERMANENTE.** No boot normal o `amdgpu` carrega do
initramfs, o painel interno (eDP-1) acende em 1920×1080 nativo.

---

## Resumo

| Item | Valor |
|------|-------|
| Máquina | HP ProBook 445 G7 |
| GPU | AMD Renoir iGPU (`1002:1636`, subsystem HP `103C:8730`), PCI `0000:05:00.0` |
| SO | Ubuntu 26.04, kernel **7.0.0-27-generic** |
| Sintoma | Tela 100% preta com `amdgpu`; falha no estágio `amdgpu_get_bios()` / display |
| Causa raiz | A imagem VBIOS na **flash da HP é um template genérico sem objeto eDP**; o VBIOS real (com o painel) só existe na **ROM BAR**, preenchida pelo SBIOS durante o POST |
| Correção | (a) `amdgpu` recompilado com **carregamento de VBIOS via arquivo** + correção de underflow do HPD; (b) `vbios.bin` = dump da **ROM BAR real**; (c) carga antecipada via dracut |
| Resultado | `card1 → amdgpu`, eDP-1 = 1920×1080/1680×1050/…; sem `Failed to create link encoder`, sem `wait timed out` |

---

## O problema

Em **todos** os kernels testados (6.8, 6.17, 7.0) o `amdgpu` falhava no probe com
`-22` (EINVAL), deixando o display no `simple-framebuffer` (simpledrm) — ou,
com o módulo patcheado indo mais fundo no probe, numa **tela preta sem fallback**.

`amdgpu_get_bios()` tenta obter o VBIOS nesta ordem: **ATRM → VFCT →
VRAM BAR → ROM BAR → platform**. Nesta máquina, em estado normal de boot:

- **ATRM**: sem método ACPI → ausente.
- **VFCT**: sem tabela VFCT ACPI nesta ACPI.
- **VRAM shadow**: ausente.
- **ROM BAR**: retornava `I/O error` quando a GPU não havia sido POSTada.
- **platform**: pegava a cópia que o SBIOS espelha em `0xC0000` — o **VBIOS genérico**.

Mesmo quando um VBIOS era obtido, o estágio de display (DC) falhava:

```
create_links: BIOS object table - number of connectors: 5
... link_id: 21, is_internal_display: 0, hpd_int_gpio_uid id: 0
*ERROR* Failed to create link encoder!
construct_phy failed.
```

### Causa raiz do "Failed to create link encoder"

- `link_factory.c` → `construct_phy`: sem HPD no VBIOS, executa
  `link->hpd_src = hpd_info.hpd_int_gpio_uid - 1`. Com `uid = 0` (VBIOS genérico)
  → `hpd_src = -1` (**underflow sem sinal** → valor enorme).
- `dcn21_link_encoder_create` (`dcn21_resource.c`):
  `if (... || enc_init_data->hpd_source >= ARRAY_SIZE(link_enc_hpd_regs)) return NULL;`
  `link_enc_hpd_regs[]` tem 5 entradas; `hpd_source` enorme → `NULL` →
  "Failed to create link encoder" para **todos** os links → sem CRTC → tela preta.

### A descoberta decisiva: dois VBIOSes diferentes

Comparando o VBIOS extraído do firmware HP com o dump da **ROM BAR**
(lida com a GPU já POSTada pelo simpledrm), as imagens diferem em ~351 bytes,
**todos na região `0xCC00–0xD300`** (LCD_Info @`0xCCD8` + Display Object Table @`0xD248`):

| Região | Flash HP (`renoir_vbios_113-RENOIR-037.rom`) | ROM BAR real (`vbios_rombar.bin`) |
|--------|----------------------------------------------|-----------------------------------|
| LCD_Info @`0xCCD8` | **zerado** (sem timing do painel) | timing real **1920×1080** (`0x780`×`0x438`) |
| Tabela de conectores @`0xD250` | **5× `0x15` (MXM)** — placeholder genérico | `0x14` (**eDP**, painel interno) + `0x0C` (HDMI) + 2× `0x13` (DP), com HPD/GPIO válidos |
| Strings | "Renoir Generic VBIOS" | mapeamento OEM real |

**Conclusão:** o mapeamento eDP/painel **não está na flash**; é montado pelo
SBIOS durante o POST da iGPU. O VBIOS correto sempre existiu — na ROM BAR.

---

## A correção (3 componentes)

### 1. Módulo `amdgpu` patcheado (2 patches)

Fonte baixada do apt pool `linux_7.0.0-27.27` e extraída com `dpkg-source`.

**Patch 1 — carregamento de VBIOS via arquivo** (`drivers/gpu/drm/amd/amdgpu/amdgpu_bios.c`):
- Nova função `amdgpu_read_bios_from_file()` que chama `request_firmware("amdgpu/vbios.bin")`
  e valida com `check_atom_bios`.
- Chamada **primeiro** em `amdgpu_get_bios_apu()`.
- `MODULE_FIRMWARE("amdgpu/vbios.bin")` → garante que `vbios.bin` entre no initramfs.

**Patch 2 — correção de underflow do HPD** (`drivers/gpu/drm/amd/display/dc/link/link_factory.c`):
```c
/* antes */ link->hpd_src = hpd_info.hpd_int_gpio_uid - 1;
/* depois*/ link->hpd_src = hpd_info.hpd_int_gpio_uid ? hpd_info.hpd_int_gpio_uid - 1 : 0;
```
> Com o VBIOS real essa correção é um no-op (o VBIOS já fornece HPD válido),
> mas protege contra regressão.

### 2. `vbios.bin` = dump real da ROM BAR

- Fonte: `/sys/bus/pci/devices/0000:05:00.0/rom` (legível com GPU já POSTada).
- 54784 bytes, checksum mod256 = 0 (válido), `113-RENOIR-037`,
  `ATOMBIOSBK-AMD VER017.010.000.031`.
- **sha256: `e40fd9a8f8a244d3dbea3c7e9834032740a2c0d71000aa1d81d61989cf95425a`**
- Instalar em `/lib/firmware/amdgpu/vbios.bin`.

### 3. Carga antecipada (dracut)

Ubuntu 26.04 usa **dracut**, não mkinitramfs.
- `/etc/dracut.conf.d/amdgpu.conf` → `add_drivers+=" amdgpu "`
- `update-initramfs -u -k 7.0.0-27-generic` embute `amdgpu.ko.zst` + `vbios.bin`
  no initramfs.

---

## Notas de build (lições aprendidas)

### Erro 1 — mismatch de CRC de modversions
- Sintoma: `amdgpu: disagrees about version of symbol module_layout`.
- Causa: build in-tree de módulo único (`make drivers/.../amdgpu.ko`) sem `vmlinux.o`
  gera CRCs a partir dos headers fonte, não do kernel binário.
- Correção: build EXTMOD (`make -C $SRC M=drivers/gpu/drm/amd/amdgpu modules`)
  com `Module.symvers` **do kernel binário**
  (`/lib/modules/.../build/Module.symvers`, `module_layout=0xb0c84d61`) copiado
  para a árvore fonte.

### Erro 2 — relocação rejeitada
- Sintoma: `x86/modules: Invalid relocation target, existing value is nonzero ...`
  (fatal, `-ENOEXEC`) → módulo aborta antes do probe.
- Causa: kernel tem `CONFIG_DEBUG_INFO_BTF_MODULES=y`, que adiciona **24 bytes**
  ao `struct module` (campos `btf_*`) **antes** do campo `exit`. Nosso `.config`
  tinha a opção desabilitada → `cleanup_module` ficou no offset errado (`0x490` vs `0x4a8`).
- Correção: rebuild com `KCFLAGS="-DCONFIG_DEBUG_INFO_BTF_MODULES=1"` (sem necessidade de
  pahole/vmlinux). `cleanup_module` foi para `0x4a8`. ✅
- **Lição:** ao copiar `Module.symvers` do kernel para casar CRCs, é preciso
  também casar **todas** as opções de `.config` que alteram o layout de structs
  exportadas — senão o CRC passa mas o binário/relocação diverge.

### Build validado
- vermagic `7.0.0-27-generic SMP preempt mod_unload modversions` ✅
- `module_layout = 0xb0c84d61` (== kernel), 0/1130 símbolos divergentes ✅
- `firmware: amdgpu/vbios.bin` presente ✅
- Ambiente de build: gcc 15.2.0 (idêntico ao build do kernel), Secure Boot OFF,
  `MODULE_SIG_FORCE` off, lockdown `[none]`.
- Pacotes necessários: `flex bison libelf-dev`.

---

## Instalação — início rápido

**Pré-condição:** iniciar com a GPU já POSTada e o módulo `amdgpu` *não*
controlando o display (o estado quebrado já serve: simpledrm ativo, ou recovery /
boot com `nomodeset`). A ROM BAR só é legível após o POST.

```bash
sudo apt install dkms patch flex bison libelf-dev linux-headers-$(uname -r)
git clone https://github.com/Jeanmarcus93/hp-probook-445g7-amdgpu-fix.git
cd hp-probook-445g7-amdgpu-fix
sudo bash install.sh
# reinicie pela entrada normal do GRUB
```

O `install.sh` executa os quatro passos em ordem:

1. **`scripts/dump_vbios_rom.sh`** — detecta automaticamente a GPU AMD no barramento PCI,
   habilita a ROM BAR, faz o dump do VBIOS real e valida (assinatura 0x55AA,
   checksum mod-256, marcador `ATOMBIOSBK`, conteúdo da object table v1.4).
2. **`scripts/install_vbios.sh`** — instala o dump como
   `/lib/firmware/amdgpu/vbios.bin` (com backup de arquivo anterior).
3. **`scripts/build_dkms.sh`** — baixa o pacote `linux-source` correspondente,
   extrai somente `drivers/gpu/drm/amd/` (a subárvore é autocontida:
   `FULL_AMD_PATH=$(src)/..`), aplica os patches de `patches/`, instala a
   árvore em `/usr/src/amdgpu-rombar-<versão>/` e executa
   `dkms add/build/install`.
4. **`scripts/make_amdgpu_permanent.sh`** — configuração dracut de carga antecipada
   (`add_drivers+=" amdgpu "`) + regeneração do initramfs + verificações.

Cada script também pode ser executado individualmente; todos aceitam argumentos
opcionais (BDF PCI, caminho do dump, versão do kernel) e usam auto-detecção
como padrão.

**Teste opcional sem reboot com auto-recuperação:** `sudo bash scripts/test_amdgpu_real.sh`
carrega o módulo manualmente e, se o painel não acender em 90 s, reinicia
sozinho de volta ao simpledrm.

---

## DKMS

O módulo é empacotado como `amdgpu-rombar` com `AUTOINSTALL="yes"`: cada novo
kernel instalado via apt dispara um rebuild automático contra os headers desse
kernel — sem necessidade de `apt-mark hold`, sem rebuild manual.

O build é **EXTMOD contra o pacote de headers** do kernel alvo, então CRCs de
modversions, autoconf (`CONFIG_DEBUG_INFO_BTF_MODULES`) e o layout do
`struct module` saem corretos automaticamente (veja
[Notas de build](#notas-de-build-lições-aprendidas) para entender por que isso importa).

> **Secure Boot:** o dkms do Ubuntu assina módulos automaticamente com a chave MOK
> em `/var/lib/shim-signed/mok/` se houver uma enrolada. Com Secure Boot ativo e
> sem MOK enrolada, o módulo não carregará — enrole uma antes
> (`sudo update-secureboot-policy --new-key` + `mokutil --import`).

---

## Patches

O diretório `patches/` contém diffs unificados contra a fonte vanilla
`linux_7.0.0-27.27`:

- `0001-amdgpu-bios-add-file-load-vbios.patch` — carregamento de VBIOS via arquivo em `amdgpu_bios.c`
- `0002-link-factory-fix-hpd-underflow.patch` — correção de underflow do HPD em `link_factory.c`
- `0003-amdgpu-trace-fix-out-of-tree-include-path.patch` — `TRACE_INCLUDE_PATH .`
  em `amdgpu_trace.h`. **Necessário apenas para build out-of-tree/DKMS** (o
  caminho relativo in-tree `../../drivers/gpu/drm/amd/amdgpu` não existe ao
  compilar como módulo externo). Pule se estiver patcheando uma árvore completa.

Aplique numa árvore completa do kernel com `patch -p1`, ou na subárvore `amd/`
extraída com `patch -p4` (que é o que o `build_dkms.sh` faz).

A árvore reconstruída (fonte vanilla + estes patches) foi verificada
**byte-idêntica** à árvore DKMS rodando na máquina de referência.

---

## Verificação (estado atual confirmado)

```bash
uname -r
# 7.0.0-27-generic

readlink -f /sys/class/drm/card1/device/driver
# .../bus/pci/drivers/amdgpu

dmesg | grep -iE 'Fetched VBIOS|Display Core|eDP-1'
# amdgpu 0000:05:00.0: Fetched VBIOS from file (amdgpu/vbios.bin)
# [drm] Display Core v3.2.369 initialized on DCN 2.1
# [drm] Using ACPI provided EDID for eDP-1

cat /sys/class/drm/card1-eDP-1/modes | head
# 1920x1080
# 1680x1050

sha256sum /lib/firmware/amdgpu/vbios.bin
# e40fd9a8f8a244d3dbea3c7e9834032740a2c0d71000aa1d81d61989cf95425a
```

O timestamp `Fetched VBIOS from file` em ~8.5 s confirma que a carga acontece
**no boot** (via initramfs/dracut), não via modprobe manual.

---

## Rollback / recuperação

**Se a tela ficar preta:**

1. No GRUB (segure Shift/Esc), escolha **Advanced options → recovery**
   (`nomodeset`): o `amdgpu` não fará probe e o simpledrm restaura o vídeo.

2. Remova o módulo DKMS (o módulo stock em
   `/lib/modules/.../kernel/...` volta a valer):
   ```bash
   sudo dkms remove amdgpu-rombar/$(uname -r | cut -d- -f1) --all
   sudo rm -f /etc/dracut.conf.d/amdgpu.conf
   sudo depmod -a
   sudo update-initramfs -u -k "$(uname -r)"
   ```

3. Reinicie.

---

## Hardware / IDs

- GPU: AMD Renoir iGPU, PCI `0000:05:00.0` (bus 5, slot 0, func 0)
- `1002:1636`, subsystem HP `103C:8730`
- BIOS HP S79 (protegida por senha: F10 setup e flashrom inacessíveis → flash imutável)
- VBIOS genérico da flash HP: `113-RENOIR-037`, sha256 `fb51268390b6ee18a20a2f5d6840f72844ddc88715dd91f6cce9c686182445a7`
- VBIOS real (ROM BAR): mesma string, sha256 `e40fd9a8f8a244d3dbea3c7e9834032740a2c0d71000aa1d81d61989cf95425a`
