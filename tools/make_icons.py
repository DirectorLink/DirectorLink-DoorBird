"""Generate the driver icons in the DirectorLink style (no maker logos).

    pip install pillow
    python tools/make_icons.py

Writes (paths in driver.xml are relative to src/www/):
  src/www/icons/device_sm.png, device_lg.png   Composer (16 / 32 px)
  src/www/icons/doorbird_300.png               documentation header

Style (matches the other DirectorLink drivers): round grey disc with a vertical
gradient, thick ring, white glyph. The glyph is a door station: a tall plate with
a camera lens at the top and a round bell button below.
"""
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONS = os.path.join(ROOT, "src", "www", "icons")

CYAN = (40, 210, 255, 255)
BLUE = (66, 119, 255, 255)
DISC_TOP = (157, 157, 157)
DISC_BOTTOM = (99, 99, 99)
WHITE = (250, 250, 250, 255)
DARK = (60, 60, 60, 255)

SS = 2048          # supersampled canvas
S = SS / 1024.0    # scale from the 1024 design grid


def p(*v):
    return [int(round(x * S)) for x in v]


def disc(ring):
    """Grey gradient disc with a ring and a soft drop shadow."""
    img = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse(p(52, 60, 972, 980), fill=(0, 0, 0, 90))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14 * S)))
    ImageDraw.Draw(img).ellipse(p(44, 44, 980, 980), fill=ring)
    grad = Image.new("RGBA", (SS, SS))
    gd = ImageDraw.Draw(grad)
    top, bottom = p(124)[0], p(900)[0]
    for y in range(SS):
        t = min(1.0, max(0.0, (y - top) / float(bottom - top)))
        c = tuple(int(DISC_TOP[i] + (DISC_BOTTOM[i] - DISC_TOP[i]) * t) for i in range(3))
        gd.line([(0, y), (SS, y)], fill=c + (255,))
    mask = Image.new("L", (SS, SS), 0)
    ImageDraw.Draw(mask).ellipse(p(124, 124, 900, 900), fill=255)
    img.paste(grad, (0, 0), mask)
    return img


def station(img, plate, accent, glass):
    """The door station: plate, lens with its ring, speaker slots, bell button."""
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(p(372, 220, 652, 804), radius=p(70)[0], fill=plate)    # plate
    d.ellipse(p(452, 286, 572, 406), fill=accent)                              # lens ring
    d.ellipse(p(480, 314, 544, 378), fill=glass)                               # lens glass
    for y in (448, 484, 520):
        d.rounded_rectangle(p(448, y, 576, y + 16), radius=p(8)[0], fill=accent)  # speaker slots
    d.ellipse(p(444, 586, 580, 722), fill=accent)                              # bell button
    d.ellipse(p(474, 616, 550, 692), fill=plate)


def composer_icon(size):
    if size >= 32:
        img = disc(BLUE)
        station(img, WHITE, BLUE, DARK)
        return img.resize((size, size), Image.LANCZOS)
    # 16 px: a blue ring and a plain white plate with one lens and one button
    img = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse(p(16, 16, 1008, 1008), fill=BLUE)
    d.ellipse(p(176, 176, 848, 848), fill=(118, 118, 118, 255))
    d.rounded_rectangle(p(392, 248, 632, 776), radius=p(60)[0], fill=WHITE)
    d.ellipse(p(452, 300, 572, 420), fill=BLUE)
    d.ellipse(p(452, 580, 572, 700), fill=BLUE)
    return img.resize((size, size), Image.LANCZOS)


def header_icon():
    img = disc(CYAN)
    station(img, WHITE, CYAN, DARK)
    return img.resize((300, 300), Image.LANCZOS)


def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)


def main():
    save(composer_icon(16), os.path.join(ICONS, "device_sm.png"))
    save(composer_icon(32), os.path.join(ICONS, "device_lg.png"))
    save(header_icon(), os.path.join(ICONS, "doorbird_300.png"))
    print("icons written to", ICONS)


if __name__ == "__main__":
    main()
