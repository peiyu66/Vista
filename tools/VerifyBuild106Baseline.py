"""Verify accepted Build106 inputs and auto-hide source contracts without mutation."""
from pathlib import Path
import json, hashlib, os
r=Path(__file__).resolve().parents[1];sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
b=json.loads((r/'tools/Build106AcceptedBaseline.json').read_text());m=json.loads((r/'tools/Build106AcceptedInputs.json').read_text());old=json.loads((r/'tools/Build105AcceptedInputs.json').read_text());checks={}
checks['manifest_identity']=len(m)==394 and sha(r/'tools/Build106AcceptedInputs.json')==b['inputManifestSHA256']
checks['exact_three_product_delta']={p for p in m if m[p]!=old.get(p)}==set(b['changedProductFiles'])
checks['all_application_inputs']=all((r/p).is_file() and sha(r/p)==b['metadataExceptions'].get(p,{}).get('promotedSHA256',digest) for p,digest in m.items())
checks['supplemental_inputs']=all((r/p).is_file() and sha(r/p)==digest for p,digest in b['supplementalFiles'].items())
checks['vendor_symlinks']=all((r/p).is_symlink() and os.readlink(r/p)==target and (r/p).resolve().is_dir() for p,target in b['symlinks'].items())
v=(r/'VistaApp/VRPresentation.swift').read_text();hide=v.split('    func scheduleHide()',1)[1].split('    func toggleControlsFromBackground()',1)[0]
checks['selected_start_and_deadline']='player.speedStatus.selected <= 1' in hide and 'let selectedRate = self.player?.speedStatus.selected, selectedRate <= 1' in hide
checks['navigation_start_and_deadline']=hide.count('navigationVisibility == nil')==2
checks['unchanged_three_seconds']='Task.sleep(for: .seconds(3))' in hide
checks['rate_observer_never_reveals']=v.count('.onChange(of: presentation.player?.speedStatus.selected) { _, _ in presentation.scheduleHide() }')==1
checks['no_waiting_or_effective_rule']='isBuffering' not in hide and 'effectiveRate' not in hide
checks['no_unaccepted_hide_button']='hideImmersiveControls' not in v and 'hideControlsFromButton' not in v
for name in ['Vista.xcodeproj/project.pbxproj','VistaBrowser.xcodeproj/project.pbxproj']:
 s=(r/name).read_text();checks[name+'_version106']=s.count('CURRENT_PROJECT_VERSION = 106;')==2 and s.count('MARKETING_VERSION = 0.1.0;')==2
print(json.dumps({'checks':checks,'passed':sum(checks.values()),'total':len(checks),'scope':'Source contracts, not UI runtime'},indent=2))
raise SystemExit(not all(checks.values()))
