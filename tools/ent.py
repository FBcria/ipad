import sys, plistlib

def load(p):
    try:
        with open(p, 'rb') as f:
            return plistlib.load(f)
    except Exception:
        return {}

orig = load(sys.argv[1])
extra = load(sys.argv[2])
if not isinstance(orig, dict):
    orig = {}
if not isinstance(extra, dict):
    extra = {}
orig.pop('get-task-allow', None)
orig.update(extra)
with open(sys.argv[3], 'wb') as f:
    plistlib.dump(orig, f)
print("entitlements:", len(orig), "chaves")
