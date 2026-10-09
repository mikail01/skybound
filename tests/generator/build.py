import re,sys
import os; root=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'src', 'shared') + '/'
def mod(name):
    s=open(root+name+'.luau').read()
    s=s.replace('--!strict','')
    s=re.sub(r'require\(script\.Parent\.(\w+)\)', r'MOD_\1', s)
    return s
mocks=r'''
local Color3 = { fromRGB = function(r,g,b) return {r=r,g=g,b=b} end, new=function(r,g,b) return {r=r,g=g,b=b} end }
local Vector3 = { new = function(x,y,z) return {X=x,Y=y,Z=z} end }
-- deterministic PRNG mock for Random
local Random = {}
Random.new = function(seed)
  local state = (seed % 2147483646) + 1
  local r = {}
  local function nxt() state = (state * 48271) % 2147483647; return state / 2147483647 end
  function r:NextNumber(a,b) local v = nxt(); if a then return a + (b-a)*v end return v end
  function r:NextInteger(a,b) return a + math.floor(nxt()*(b-a+1)) end
  return r
end
'''
out=mocks
for n in ['Config','Format','Types']:
    out+=f'local MOD_{n} = (function()\n{mod(n)}\nend)()\n'
out+='local MOD_Generator = (function()\n'+mod('Generator')+'\nend)()\n'
out+=open(sys.argv[1]).read()
open(sys.argv[2],'w').write(out)
