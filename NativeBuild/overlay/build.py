from pathlib import Path
import json,subprocess,hashlib,concurrent.futures,os
R=Path(__file__).resolve().parent;out=R/'build';out.mkdir(exist_ok=True)
sdk=subprocess.check_output(['xcrun','--sdk','xros','--show-sdk-path'],text=True).strip()
for x in json.loads((R/'inputs-manifest.json').read_text()):
 p=R/x['path'];assert os.environ.get('VISTA_ALLOW_MODIFIED_SOURCES')=='1' or hashlib.sha256(p.read_bytes()).hexdigest()==x['sha256'],str(p)+' changed; pass --allow-modified-sources to build your changes'
# Relative includes such as ../vobsub.h also require the -I directory itself
# to exist. Git does not retain empty directories from compiler input layouts.
recipes=json.loads((R/'recipes.json').read_text())
for recipe in recipes:
 for arg in recipe['args']:
  if arg.startswith('-I{root}/inputs/'):
   directory=Path(arg[2:].replace('{root}',str(R))).resolve()
   assert directory.is_relative_to((R/'inputs').resolve()),str(directory)
   directory.mkdir(parents=True,exist_ok=True)
def compile(x):
 c=['xcrun','--sdk','xros',x['compiler']]+[a.replace('{root}',str(R)).replace('{sdk}',sdk) for a in x['args']]
 p=subprocess.run(c,capture_output=True,text=True);(out/(x['object']+'.log')).write_text(p.stdout+p.stderr)
 f=out/x['object'];h=hashlib.sha256(f.read_bytes()).hexdigest() if p.returncode==0 else None
 return {'object':x['object'],'exit':p.returncode,'sha256':h,'matchesOriginalObject':h==x['originalObjectSHA256']}
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:rows=list(pool.map(compile,recipes))
(out/'receipt.json').write_text(json.dumps({'objects':rows,'allCompiled':all(x['exit']==0 for x in rows),'scope':f'{len(rows)} modified/new objects only; not full library or final App'},indent=2))
print(json.dumps({'jobs':len(rows),'compiled':sum(x['exit']==0 for x in rows),'failed':[x['object'] for x in rows if x['exit']],'byteIdentical':sum(x['matchesOriginalObject'] for x in rows)},indent=2));raise SystemExit(0 if all(x['exit']==0 for x in rows) else 1)
