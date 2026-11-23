"""Place the attribution index and its offline license links beside the app's resources."""

from pathlib import Path
import re
import shutil
import sys


DOCS = Path(__file__).resolve().parents[1] / "docs"


def bundled_index(resources):
    text = (DOCS / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
    bundle = Path("Serein_Serein.bundle")
    if (resources / bundle / "Contents/Resources").is_dir():
        bundle /= "Contents/Resources"
    text = text.replace("](../Sources/Serein/", f"]({bundle}/")
    text = text.replace("[`tools/avatar`](../tools/avatar)", "`tools/avatar`")
    for target in re.findall(r"\]\(([^):#]+)\)", text):
        if not (resources / target).is_file():
            raise ValueError(f"Missing bundled notice link: {target}")
    return text


if __name__ == "__main__":
    resources = Path(sys.argv[1])
    shutil.copytree(DOCS / "licenses", resources / "licenses")
    (resources / "THIRD_PARTY_NOTICES.md").write_text(bundled_index(resources), encoding="utf-8")
