from pathlib import Path
import subprocess,hashlib,json,re
R=Path(__file__).resolve().parents[2]
b=json.loads((R/'tools/Store213/baseline.json').read_text())
def original(path):return subprocess.check_output(['git','show',b['baseCommit']+':'+path],cwd=R).decode()
s=(R/'VistaApp/ShortcutBrowser.swift').read_text()
s=re.sub(r'\n// INPUT_PROBE_BEGIN\n.*?// INPUT_PROBE_END\n','',s,flags=re.S)
s=s.replace('Capsule().inset(by:4)','Capsule()').replace('.accessibilityIdentifier("vistaAboutVersion")','').replace('.accessibilityIdentifier("vistaAboutDone")','')
assert s==original('VistaApp/ShortcutBrowser.swift')
for f,h in b['unchangedNativeSourceHashes'].items():assert hashlib.sha256((R/f).read_bytes()).hexdigest()==h,f
for f,h in b['nativeArtifactHashes'].items():assert hashlib.sha256((R/f).read_bytes()).hexdigest()==h,f
p=(R/'Resources/VistaPrivacy.txt').read_text()
assert p.replace('/zh/site-policy/privacy-policies/github-general-privacy-statement','/en/site-policy/privacy-policies/github-general-privacy-statement')==original('Resources/VistaPrivacy.txt')
assert '/zh/site-policy/privacy-policies/github-general-privacy-statement' in (R/'docs/隱私權聲明.md').read_text()
assert '/en/site-policy/privacy-policies/github-general-privacy-statement' in (R/'Resources/VistaPrivacy-en.txt').read_text()
print('PASS exact accepted UI equivalence except36pt shapes, two About accessibility IDs and compile-gated passive observations; native inputs unchanged; bilingual links aligned')
