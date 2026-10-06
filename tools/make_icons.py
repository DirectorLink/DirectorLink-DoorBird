"""Generate the driver icons in the DirectorLink style (no maker logos).

    pip install pillow
    python tools/make_icons.py

Writes (paths in driver.xml are relative to src/www/):
  src/www/icons/device_sm.png, device_lg.png     the DoorBird device in Composer (16 / 32 px)
  src/www/icons/camera_sm.png, camera_lg.png     the DoorBird Camera device in Composer
  src/www/icons/doorbird_300.png                 documentation header
  src/www/icons/tile/<state>_<size>.png          the DoorBird tile in Navigator
      states: idle, ring, motion, open, offline     sizes: 70, 90, 300, 512, 1024

Style (matches the other DirectorLink drivers): round grey disc with a vertical
gradient, thick ring, white glyph; cyan ring when live, red ring with a badge
when offline. The glyph is a door station: a tall plate with a camera lens at
the top and a round bell button below. Ring: waves around the button. Motion:
waves around the lens. Open: an open padlock badge.
"""
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONS = os.path.join(ROOT, "src", "www", "icons")
TILE_STATES = ("idle", "ring", "motion", "open", "offline")
SIZES = (70, 90, 300, 512, 1024)

CYAN = (40, 210, 255, 255)
BLUE = (66, 119, 255, 255)
RED = (230, 40, 40, 255)
DISC_TOP = (157, 157, 157)
DISC_BOTTOM = (99, 99, 99)
WHITE = (250, 250, 250, 255)
LIGHT = (225, 225, 225, 255)
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


def waves(d, cx, cy, radii, color, width=26):
    """Arcs on both sides of a point (sound or motion)."""
    for r in radii:
        d.arc(p(cx - r, cy - r, cx + r, cy + r), start=150, end=210, fill=color, width=p(width)[0])
        d.arc(p(cx - r, cy - r, cx + r, cy + r), start=-30, end=30, fill=color, width=p(width)[0])


def badge(img, ring, glyph):
    d = ImageDraw.Draw(img)
    d.ellipse(p(640, 640, 900, 900), fill=WHITE)
    d.ellipse(p(664, 664, 876, 876), fill=ring)
    if glyph == "alert":
        d.rounded_rectangle(p(752, 698, 788, 800), radius=p(16)[0], fill=WHITE)
        d.ellipse(p(750, 816, 790, 856), fill=WHITE)
    elif glyph == "open":
        d.rounded_rectangle(p(712, 770, 828, 852), radius=p(14)[0], fill=WHITE)          # lock body
        d.arc(p(722, 690, 798, 780), start=180, end=360, fill=WHITE, width=p(18)[0])    # shackle, opened to the left
        d.line(p(731, 734, 731, 760), fill=WHITE, width=p(18)[0])


def tile(state):
    if state == "offline":
        img = disc(RED)
        station(img, LIGHT, (150, 150, 150, 255), (110, 110, 110, 255))
        badge(img, RED, "alert")
        return img
    img = disc(CYAN)
    station(img, WHITE, CYAN, DARK)
    d = ImageDraw.Draw(img)
    if state == "ring":
        waves(d, 512, 654, (195, 255), WHITE)
    elif state == "motion":
        waves(d, 512, 346, (195, 255), WHITE, 22)
    elif state == "open":
        badge(img, CYAN, "open")
    return img


def composer_icon(size, camera=False):
    if size >= 32:
        img = disc(BLUE)
        if camera:
            d = ImageDraw.Draw(img)
            d.ellipse(p(292, 292, 732, 732), fill=WHITE)    # a big lens
            d.ellipse(p(392, 392, 632, 632), fill=BLUE)
            d.ellipse(p(452, 452, 572, 572), fill=DARK)
        else:
            station(img, WHITE, BLUE, DARK)
        return img.resize((size, size), Image.LANCZOS)
    img = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse(p(16, 16, 1008, 1008), fill=BLUE)
    d.ellipse(p(176, 176, 848, 848), fill=(118, 118, 118, 255))
    if camera:
        d.ellipse(p(312, 312, 712, 712), fill=WHITE)
        d.ellipse(p(432, 432, 592, 592), fill=BLUE)
    else:
        d.rounded_rectangle(p(392, 248, 632, 776), radius=p(60)[0], fill=WHITE)
        d.ellipse(p(452, 300, 572, 420), fill=BLUE)
        d.ellipse(p(452, 580, 572, 700), fill=BLUE)
    return img.resize((size, size), Image.LANCZOS)


def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)


def main():
    save(composer_icon(16), os.path.join(ICONS, "device_sm.png"))
    save(composer_icon(32), os.path.join(ICONS, "device_lg.png"))
    save(composer_icon(16, camera=True), os.path.join(ICONS, "camera_sm.png"))
    save(composer_icon(32, camera=True), os.path.join(ICONS, "camera_lg.png"))
    save(tile("idle").resize((300, 300), Image.LANCZOS), os.path.join(ICONS, "doorbird_300.png"))
    for state in TILE_STATES:
        big = tile(state)
        for size in SIZES:
            save(big.resize((size, size), Image.LANCZOS), os.path.join(ICONS, "tile", f"{state}_{size}.png"))
    print("icons written to", ICONS)


if __name__ == "__main__":
    main()
