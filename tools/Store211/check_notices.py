from pathlib import Path
import subprocess

R = Path(__file__).resolve().parents[2]
T = R / '.build/store211/notice-check'
T.mkdir(parents=True, exist_ok=True)
(T / 'main.swift').write_text(r'''import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
for suffix in ["", "-en"] {
    let source = try String(contentsOf: root.appendingPathComponent("Resources/VistaPrivacy\(suffix).txt"), encoding: .utf8)
    let blocks = VistaNoticeLinks.blocks(source, markdown: true)
    precondition(blocks.compactMap(\.headingLevel) == [1,2,2,2,2,2,2])
    precondition(blocks.map(\.id) == Array(blocks.indices))
    precondition(blocks.filter { $0.headingLevel != nil }.allSatisfy { !String($0.text.characters).hasPrefix("#") })
    let links = blocks.flatMap { Array($0.text.runs).compactMap(\.link) }
    precondition(links.count == 5 && links.allSatisfy(VistaNoticeLinks.allows))
    precondition(!blocks.contains { String($0.text.characters).contains("[GitHub Issues]") })
    print("PASS privacy\(suffix): 7 styled heading blocks, 5 working link attributes")
}
for name in ["Resources/VLCThirdPartyNotices.txt", "Resources/VLCThirdPartyNotices-en.txt",
             "Resources/MKVThirdPartyNotices.txt", "Resources/MKVThirdPartyNotices-en.txt",
             "VistaApp/Resources/Apple-Stereo-LICENSE.txt"] {
    let source = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    let blocks = VistaNoticeLinks.blocks(source, markdown: false)
    precondition(blocks.count == 1 && blocks[0].headingLevel == nil)
    precondition(String(blocks[0].text.characters) == source)
}
print("PASS 5 original license texts: exact visible text and whitespace preserved")
''')
subprocess.run(['xcrun', 'swiftc', str(R/'Sources/VistaCore/VistaLocalization.swift'),
                str(T/'main.swift'), '-o', str(T/'check')], check=True)
subprocess.run([str(T/'check'), str(R)], check=True)
