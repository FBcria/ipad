import sys, plistlib
orig = plistlib.load(open(sys.argv[1], 'rb'))
extra = plistlib.load(open(sys.argv[2], 'rb'))
orig.pop('get-task-allow', None)
orig.update(extra)
plistlib.dump(orig, open(sys.argv[3], 'wb'))
print("entitlements:", len(orig), "chaves")
