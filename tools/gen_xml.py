"""Generate src/driver.xml from tools/driver.xml.in (the tile's icon list is long and mechanical).

    python tools/gen_xml.py
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRV = "DirectorLink-DoorBird"  # the .c4z file name, used in controller:// icon URLs
STATES = ("idle", "ring", "motion", "open", "offline")
SIZES = (70, 90, 300, 512, 1024)


def icons(state, ind):
    return "\n".join(f'{ind}<Icon width="{z}" height="{z}">controller://driver/{DRV}/icons/tile/{state}_{z}.png</Icon>' for z in SIZES)


def nav():
    out = ['\t\t<navigator_display_option proxybindingid="5001">', "\t\t\t<display_icons>", icons("idle", "\t\t\t\t")]
    for st in STATES:
        out += [f'\t\t\t\t<state id="{st}">', icons(st, "\t\t\t\t\t"), "\t\t\t\t</state>"]
    out += ["\t\t\t</display_icons>", "\t\t</navigator_display_option>"]
    return "\n".join(out)


def main():
    template = open(os.path.join(ROOT, "tools", "driver.xml.in"), encoding="utf-8").read()
    out = os.path.join(ROOT, "src", "driver.xml")
    open(out, "w", encoding="utf-8", newline="\n").write(template.replace("@@NAVIGATOR_ICONS@@", nav()))
    print("wrote", out)


if __name__ == "__main__":
    main()
