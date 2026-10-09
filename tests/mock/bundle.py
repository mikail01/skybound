# Bundle: apidb + runtime + project sources (mapped like default.project.json) + harness
import os, sys, json
import os; root = os.environ.get('SKY_ROOT', os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
proj = json.load(open(os.path.join(root, 'default.project.json')))
entries = []
def walk_path(fs, rojo, kind_hint=None):
    # fs is a dir or file; produce entries (rojo path list, class, code)
    if os.path.isdir(fs):
        init = None
        for n in ('init.server.luau','init.client.luau','init.luau'):
            if os.path.exists(os.path.join(fs,n)): init=n
        cls = {'init.server.luau':'Script','init.client.luau':'LocalScript','init.luau':'ModuleScript'}.get(init,'Folder')
        entries.append((rojo, cls, open(os.path.join(fs,init)).read() if init else None, os.path.relpath(os.path.join(fs,init) if init else fs, root)))
        for n in sorted(os.listdir(fs)):
            if n==init or n.startswith('.'): continue
            full=os.path.join(fs,n)
            if os.path.isdir(full):
                walk_path(full, rojo+[n])
            elif n.endswith('.luau') or n.endswith('.lua'):
                base=n.rsplit('.',1)[0]
                cls='ModuleScript'
                if base.endswith('.server'): cls='Script'; base=base[:-7]
                elif base.endswith('.client'): cls='LocalScript'; base=base[:-7]
                entries.append((rojo+[base], cls, open(full).read(), os.path.relpath(full, root)))
def walk_tree(node, rojo):
    for k,v in node.items():
        if k.startswith('$'): continue
        if '$path' in v:
            walk_path(os.path.join(root, v['$path']), rojo+[k])
        else:
            entries.append((rojo+[k], v.get('$className'), None, None))
            walk_tree(v, rojo+[k])
walk_tree(proj['tree'], [])
def lstr(s):
    eq='='*8
    assert (']'+eq+']') not in s
    return '['+eq+'['+s+']'+eq+']'
out=['local APIDB = (function()', open('apidb.luau').read(), 'end)()', 'local R = (function()', open('runtime.luau').read(), 'end)()', 'local ENTRIES = {']
for rojo, cls, code, path in entries:
    out.append('{ path = %s, class = %s, code = %s, file = %s },' % (json.dumps('/'.join(rojo)), json.dumps(cls) if cls else 'nil', lstr(code) if code is not None else 'nil', json.dumps(path) if path else 'nil'))
out.append('}')
out.append(open(sys.argv[1]).read())
open(sys.argv[2],'w').write('\n'.join(out))
print(len(entries),'entries')
