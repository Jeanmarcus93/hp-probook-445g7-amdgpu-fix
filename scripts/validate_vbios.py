#!/usr/bin/env python3
"""Validacao de imagem VBIOS ATOM (estrutural + conteudo).

Estrutural (sempre fatal se falhar):
  - assinatura 0x55AA e checksum mod-256 do tamanho declarado
  - marcador ATOMBIOSBK

Conteudo (parse da Display Object Info Table v1.4 + LCD_Info):
  - template generico (todos os conectores MXM 0x15 + LCD_Info zerada) e
    exatamente a imagem que CAUSA a tela preta -> fatal, a menos que
    --allow-generic
  - ausencia de painel interno (sem conector eDP 0x14/LVDS 0x0e e sem timing
    em LCD_Info) -> aviso; fatal com --require-edp (use em laptops)
  Se a object table nao for v1.4 (outro ASIC), os checks de conteudo sao
  pulados com aviso — a validacao estrutural continua valendo.

Uso: validate_vbios.py <vbios.bin> [--require-edp] [--allow-generic] [--quiet]
Sai 0 se valido, 1 se invalido.

NB: a string "Generic VBIOS" existe TANTO no template do flash HP quanto na
imagem real da ROM BAR (o SBIOS so preenche ~351 bytes no POST), portanto NAO
serve como discriminador — por isso o parse da object table.
"""
import struct
import sys

CONNECTOR_EDP = 0x14
CONNECTOR_LVDS = 0x0E
CONNECTOR_MXM = 0x15
OBJECT_TYPE_CONNECTOR = 3


def log(msg, quiet):
    if not quiet:
        print(msg)


def parse_content(d, quiet=False):
    """Retorna (connector_ids, lcd_h_active, lcd_v_active) ou None se a
    estrutura nao for reconhecida."""
    try:
        rom_hdr = struct.unpack_from('<H', d, 0x48)[0]
        if rom_hdr + 8 > len(d):
            if not quiet:
                print('  AVISO: rom_hdr (0x{:x}) fora dos limites'.format(rom_hdr))
            return None
        if d[rom_hdr + 4:rom_hdr + 8] != b'ATOM':
            if not quiet:
                print('  AVISO: marcador ATOM ausente no rom_header')
            return None
        mdt = struct.unpack_from('<H', d, rom_hdr + 32)[0]
        if mdt + 4 + 22 * 2 + 2 > len(d):
            if not quiet:
                print('  AVISO: master_data_table (0x{:x}) fora dos limites'.format(mdt))
            return None
        lcd_off = struct.unpack_from('<H', d, mdt + 4 + 6 * 2)[0]
        obj_off = struct.unpack_from('<H', d, mdt + 4 + 22 * 2)[0]
        if not obj_off:
            if not quiet:
                print('  AVISO: object_table ausente (offset 0)')
            return None
        if obj_off + 8 > len(d):
            if not quiet:
                print('  AVISO: object_table (0x{:x}) fora dos limites'.format(obj_off))
            return None
        fmt_rev, content_rev = d[obj_off + 2], d[obj_off + 3]
        if (fmt_rev, content_rev) != (1, 4):
            if not quiet:
                print('  AVISO: object table v{}.{} (esperado v1.4); '
                      'checks de conteudo pulados'.format(fmt_rev, content_rev))
            return None
        n_path = d[obj_off + 6]
        conns = []
        for i in range(n_path):
            off = obj_off + 8 + i * 16
            if off + 2 > len(d):
                break
            objid = struct.unpack_from('<H', d, off)[0]
            if (objid >> 12) & 0x7 == OBJECT_TYPE_CONNECTOR:
                conns.append(objid & 0xFF)
        h_active = v_active = 0
        if lcd_off:
            if lcd_off + 4 + 8 > len(d):
                if not quiet:
                    print('  AVISO: LCD_Info (0x{:x}) truncada'.format(lcd_off))
            else:
                _pixclk, h_active, _hb, v_active = struct.unpack_from(
                    '<HHHH', d, lcd_off + 4)
        return conns, h_active, v_active
    except (struct.error, IndexError):
        return None


def main():
    args = sys.argv[1:]
    require_edp = '--require-edp' in args
    allow_generic = '--allow-generic' in args
    quiet = '--quiet' in args
    paths = [a for a in args if not a.startswith('--')]
    if len(paths) != 1:
        print(__doc__)
        return 1
    try:
        with open(paths[0], 'rb') as f:
            d = f.read()
    except (FileNotFoundError, PermissionError) as e:
        print(f'ERRO: nao foi possivel ler {paths[0]}: {e}')
        return 1

    # --- estrutural ---
    if len(d) < 2 or d[:2] != b'\x55\xaa':
        print('ERRO: assinatura 55AA invalida (arquivo muito curto ou corrompido)')
        return 1
    if len(d) < 3:
        print('ERRO: imagem muito curta (falta byte de tamanho)')
        return 1
    decl = d[2] * 512
    if decl == 0:
        print('ERRO: tamanho declarado e zero — imagem invalida')
        return 1
    if len(d) < decl:
        print(f'ERRO: imagem truncada ({len(d)} < {decl} declarados)')
        return 1
    if (sum(d[:decl]) & 0xFF) != 0:
        print('ERRO: checksum mod-256 invalido')
        return 1
    if b'ATOMBIOSBK' not in d:
        print('ERRO: marcador ATOMBIOSBK ausente')
        return 1
    log('  estrutural OK: 55aa + checksum 0 + ATOMBIOSBK', quiet)

    # --- conteudo ---
    parsed = parse_content(d, quiet)
    if parsed is None:
        log('  AVISO: checks de conteudo pulados (object table nao '
            'reconhecida)', quiet)
        return 0
    conns, h_active, v_active = parsed
    log(f'  conectores: {[hex(c) for c in conns]}  '
        f'LCD_Info: {h_active}x{v_active}', quiet)

    is_template = (conns and all(c == CONNECTOR_MXM for c in conns)
                   and h_active == 0)
    has_panel = any(c in (CONNECTOR_EDP, CONNECTOR_LVDS) for c in conns) \
        or h_active > 0

    if is_template:
        print('ERRO: assinatura de TEMPLATE GENERICO detectada (todos os '
              'conectores MXM 0x15 + LCD_Info zerada).')
        print('      Esta e exatamente a imagem que causa a tela preta. '
              'O dump provavelmente foi feito sem a GPU POSTada, ou de '
              'outra fonte que nao a ROM BAR.')
        if allow_generic:
            print('      --allow-generic: prosseguindo mesmo assim.')
            return 0
        return 1

    if not has_panel:
        msg = ('sem painel interno no VBIOS (nenhum conector eDP 0x14/LVDS '
               '0x0e e LCD_Info vazia)')
        if require_edp:
            print(f'ERRO: {msg} — este fix e para laptop; confira se o dump '
                  'veio da GPU certa (multiplas GPUs AMD?).')
            return 1
        log(f'  AVISO: {msg} (ok para APU desktop; em laptop, suspeite)',
            quiet)

    log('  conteudo OK', quiet)
    return 0


if __name__ == '__main__':
    sys.exit(main())
