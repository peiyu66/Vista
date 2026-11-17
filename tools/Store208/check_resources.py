from pathlib import Path
import subprocess, json, re, shutil, plistlib
R=Path(__file__).resolve().parents[2]; T=R/'.build/store208/resource-check';T.mkdir(parents=True,exist_ok=True)
def strings(lang):
 p=R/'Resources'/f'{lang}.lproj/Localizable.strings'
 return json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(p)]))
a,b=strings('en'),strings('zh-Hant');assert a.keys()==b.keys()
for k in a:assert re.findall(r'%(?:\d+\$)?[@dfisu]',a[k])==re.findall(r'%(?:\d+\$)?[@dfisu]',b[k]),k
used=set()
for root in ['Sources','VistaApp','engine/vlc/Sources']:
 for p in (R/root).rglob('*.swift'):
  used.update(json.loads(m) for m in re.findall(r'VistaL10n\.text\(("(?:[^"\\]|\\.)*")',p.read_text()))
assert not used-a.keys(),used-a.keys()
for name in ['VistaPrivacy.txt','VistaPrivacy-en.txt']:
 text=(R/'Resources'/name).read_text();assert not re.search(r'(?i)\bbuild\s*\d+|Vista\s*\d{3}',text)
 assert 'Release' in text and 'Diagnostic' in text and 'GitHub Issues' in text
 assert not re.search(r'^\[(?:English|中文|返回首頁|Back to Home)\]\(',text,re.M)
# Exercise the actual Bundle.main lookup in two independent process launches.
app=T/'LanguageCheck.app'; exe=app/'Contents/MacOS';res=app/'Contents/Resources';exe.mkdir(parents=True,exist_ok=True);res.mkdir(parents=True,exist_ok=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.example.VistaResourceCheck','CFBundleExecutable':'LanguageCheck','CFBundlePackageType':'APPL','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','zh-Hant']}))
for lang in ['en','zh-Hant']:shutil.copytree(R/'Resources'/f'{lang}.lproj',res/f'{lang}.lproj',dirs_exist_ok=True)
main=T/'main.swift';main.write_text('''import Foundation
let expected = CommandLine.arguments[1]
precondition(Bundle.main.preferredLocalizations.first == expected)
let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\\(expected).lproj/Localizable.strings")
let data = try Data(contentsOf: path)
let entries = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String:String]
for (key, value) in entries { precondition(VistaL10n.text(key) == value, key) }
precondition(VistaL10n.isEnglish == (expected == "en"))
print("PASS \\(expected): \\(entries.count) actual localized lookups")
''')
subprocess.run(['xcrun','swiftc',str(R/'Sources/VistaCore/VistaLocalization.swift'),str(main),'-o',str(exe/'LanguageCheck')],check=True)
for lang in ['en','zh-Hant']:subprocess.run([str(exe/'LanguageCheck'),lang,'-AppleLanguages',f'({lang})'],check=True)
print('PASS matching format placeholders and',len(used),'literal call-site keys')
