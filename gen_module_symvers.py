#!/usr/bin/env python3
"""
vmlinux ELF ファイルから Module.symvers を生成するスクリプト。
Android GKI カーネル向け外部モジュールビルドに使用。

使い方:
  python3 gen_module_symvers.py <vmlinux> <output_Module.symvers>
"""

import struct
import subprocess
import sys
import re


def parse_elf64_sections(data):
    """ELF64 セクションヘッダから (vaddr_start, vaddr_end, file_offset) のリストを返す。"""
    assert data[:4] == b'\x7fELF', "ELF マジックが一致しません"
    ei_data = data[5]
    endian = '<' if ei_data == 1 else '>'  # 1=little, 2=big

    e_shoff,    = struct.unpack_from(endian + 'Q', data, 0x28)
    e_shentsize, = struct.unpack_from(endian + 'H', data, 0x3A)
    e_shnum,    = struct.unpack_from(endian + 'H', data, 0x3C)

    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        sh_addr,   = struct.unpack_from(endian + 'Q', data, off + 16)
        sh_offset, = struct.unpack_from(endian + 'Q', data, off + 24)
        sh_size,   = struct.unpack_from(endian + 'Q', data, off + 32)
        if sh_addr != 0 and sh_size != 0:
            sections.append((sh_addr, sh_addr + sh_size, sh_offset))
    return sections


def vaddr_to_foffset(vaddr, sections):
    """仮想アドレスをファイルオフセットに変換。"""
    for start, end, foff in sections:
        if start <= vaddr < end:
            return foff + (vaddr - start)
    return None


def nm_symbols(vmlinux_path):
    """nm コマンドで全シンボルを取得。{name: (vaddr, section_type)} を返す。"""
    out = subprocess.check_output(
        ['aarch64-linux-gnu-nm', '--defined-only', vmlinux_path],
        stderr=subprocess.DEVNULL
    ).decode(errors='replace')

    syms = {}
    for line in out.splitlines():
        m = re.match(r'^([0-9a-f]+) ([a-zA-Z]) (\S+)$', line)
        if m:
            syms[m.group(3)] = (int(m.group(1), 16), m.group(2))
    return syms


def determine_export_type(sym, all_syms):
    """シンボルのエクスポートタイプを判定。"""
    if f'__ksymtab_gpl_{sym}' in all_syms:
        return 'EXPORT_SYMBOL_GPL'
    return 'EXPORT_SYMBOL'


def main():
    if len(sys.argv) < 3:
        print(f"使い方: {sys.argv[0]} <vmlinux> <Module.symvers>", file=sys.stderr)
        sys.exit(1)

    vmlinux_path = sys.argv[1]
    output_path  = sys.argv[2]

    print(f"[INFO] {vmlinux_path} を読み込み中...", file=sys.stderr)
    with open(vmlinux_path, 'rb') as f:
        data = f.read()

    sections = parse_elf64_sections(data)
    print(f"[INFO] セクション数: {len(sections)}", file=sys.stderr)

    print("[INFO] nm でシンボル情報を取得中...", file=sys.stderr)
    all_syms = nm_symbols(vmlinux_path)
    print(f"[INFO] 総シンボル数: {len(all_syms)}", file=sys.stderr)

    # __crc_<symbol> エントリから CRC 値を読み取る
    symvers = []
    missing = 0
    for name, (vaddr, _) in all_syms.items():
        if not name.startswith('__crc_'):
            continue
        sym = name[len('__crc_'):]
        foff = vaddr_to_foffset(vaddr, sections)
        if foff is None or foff + 4 > len(data):
            missing += 1
            continue
        crc, = struct.unpack_from('<I', data, foff)
        export_type = determine_export_type(sym, all_syms)
        symvers.append((crc, sym, export_type))

    print(f"[INFO] エクスポートシンボル数: {len(symvers)} (オフセット不明: {missing})", file=sys.stderr)

    with open(output_path, 'w') as f:
        for crc, sym, etype in sorted(symvers, key=lambda x: x[1]):
            # Module.symvers フォーマット: 0xCRC\tSYMBOL\tvmlinux\tEXPORT_TYPE\tNAMESPACE
            f.write(f"0x{crc:08x}\t{sym}\tvmlinux\t{etype}\t\n")

    print(f"[SUCCESS] {output_path} に {len(symvers)} シンボルを書き込みました", file=sys.stderr)


if __name__ == '__main__':
    main()
