import re, json, sys
src = open(sys.argv[1]).read()
meta = json.loads(src.split('\n',1)[0].split('--#METADATA#',1)[1])
classes = {}
cur = None
for line in src.split('\n'):
    m = re.match(r'declare extern type (\w+) extends (\w+) with', line) or re.match(r'declare extern type (\w+) with', line)
    if m:
        name = m.group(1)
        base = m.group(2) if m.lastindex and m.lastindex >= 2 else None
        cur = {'base': base, 'props': {}, 'methods': []}
        classes[name] = cur
        continue
    if line.strip() == 'end' or line.startswith('declare ') or line.startswith('type ') or line.startswith('export '):
        if line.strip()=='end': cur = None
        continue
    if cur is None: continue
    s = line.strip()
    if s.startswith('@'): continue
    fm = re.match(r'function (\w+)\(', s)
    if fm:
        cur['methods'].append(fm.group(1)); continue
    pm = re.match(r'(\w+): (.+)$', s)
    if pm:
        cur['props'][pm.group(1)] = pm.group(2).strip()
# keep Instance-derived classes only
def isinst(c):
    seen=0
    while c and seen<50:
        if c=='Instance': return True
        c = classes.get(c,{}).get('base'); seen+=1
    return False
out = ['return {', ' creatable = {']
out += ['  ["%s"] = true,' % c for c in meta['CREATABLE_INSTANCES']]
out += [' },', ' services = {']
out += ['  ["%s"] = true,' % c for c in meta['SERVICES']]
out += [' },', ' classes = {']
n=0
for name, c in classes.items():
    if not isinst(name) and name not in ('Instance','Object'): continue
    n+=1
    props = ', '.join('["%s"] = %s' % (k, json.dumps(v)) for k,v in c['props'].items())
    meths = ', '.join('["%s"] = true' % k for k in c['methods'])
    out.append('  ["%s"] = { base = %s, props = { %s }, methods = { %s } },' % (name, json.dumps(c['base']) if c['base'] else 'nil', props, meths))
out += [' },', '}']
open(sys.argv[2],'w').write('\n'.join(out))
print(n, 'instance classes')
