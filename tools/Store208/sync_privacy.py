from pathlib import Path
import re
from urllib.parse import urljoin
R = Path(__file__).resolve().parents[2]
for source, target in [("docs/隱私權聲明.md", "Resources/VistaPrivacy.txt"), ("docs/PrivacyPolicy.en.md", "Resources/VistaPrivacy-en.txt")]:
    text = (R / source).read_text()
    # Website navigation is not part of the offline in-app policy.
    text = re.sub(r"^\[(?:English|中文|返回首頁|Back to Home)\]\([^\n]+\)\n\n", "", text, flags=re.M)
    def absolute(match):
        label, link = match.groups()
        if not link.startswith(("https://", "http://", "#")):
            link = urljoin("https://peiyu66.github.io/Vista/" + source, link)
            link = re.sub(r"\.md(?=$|#)", ".html", link)
            link = link.replace("https://peiyu66.github.io/Vista/README.html", "https://peiyu66.github.io/Vista/")
        return f"[{label}]({link})"
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", absolute, text)
    (R / target).write_text(text)
