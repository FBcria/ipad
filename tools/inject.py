import sys, struct
p, dylib = sys.argv[1], sys.argv[2]
d = bytearray(open(p, 'rb').read())
magic, ct, cst, ft, ncmds, sizeofcmds, fl, rs = struct.unpack_from('<IiiIIIII', d, 0)
if magic != 0xfeedfacf:
    sys.exit("nao e Mach-O 64: %x" % magic)
off, first = 32, len(d)
for _ in range(ncmds):
    cmd, csz = struct.unpack_from('<II', d, off)
    if csz < 8:
        sys.exit("cmdsize invalido")
    if cmd == 0x19:
        ns = struct.unpack_from('<I', d, off + 64)[0]
        so = off + 72
        for _ in range(ns):
            fo = struct.unpack_from('<I', d, so + 48)[0]
            if fo and fo < first:
                first = fo
            so += 80
    off += csz
end = 32 + sizeofcmds
nm = dylib.encode() + b'\0'
csz = 24 + ((len(nm) + 7) // 8) * 8
if first - end < csz:
    sys.exit("sem espaco no cabecalho: livre=%d precisa=%d" % (first - end, csz))
blob = struct.pack('<IIIIII', 0xC, csz, 24, 0, 0x10000, 0x10000) + nm
blob += b'\0' * (csz - len(blob))
d[end:end] = blob
struct.pack_into('<II', d, 16, ncmds + 1, sizeofcmds + csz)
open(p, 'wb').write(d)
print("injetado:", dylib)
