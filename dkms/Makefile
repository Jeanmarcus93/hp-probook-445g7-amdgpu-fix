# Wrapper Makefile para o pacote DKMS amdgpu-rombar.
# Constroi o amdgpu.ko patcheado (file-load do VBIOS real da ROM BAR + fix HPD)
# como modulo externo contra o headers package do kernel-alvo.
# CURDIR = diretorio de build do DKMS (.../build), onde fica amd/.
KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build
MDIR := $(CURDIR)/amd/amdgpu

all:
	$(MAKE) -C $(KDIR) M=$(MDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(MDIR) clean
