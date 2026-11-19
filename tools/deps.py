import sys, struct
d = open(sys.argv[1], 'rb').read()
if struct.unpack_from('<I', d, 0)[0] != 0xfeedfacf:
    sys.exit("nao e Mach-O 64")
n = struct.unpack_from('<I', d, 16)[0]
off, bad = 32, 0
for _ in range(n):
    cmd, csz = struct.unpack_from('<II', d, off)
    if cmd in (0xC, 0xD, 0x8000001F):
        so = struct.unpack_from('<I', d, off + 8)[0]
        p = d[off + so:off + csz].split(b'\0')[0].decode(errors='replace')
        tag = "rpath" if cmd == 0x8000001F else "dep"
        print(tag + ":", p)
        if p.startswith('/var/jb') or (tag == "dep" and p.startswith('@rpath')):
            bad += 1
sys.exit(1 if bad else 0)
