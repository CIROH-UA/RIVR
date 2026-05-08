"""Generate a Google Play feature graphic (1024x500) draft for RIVR.

This is a one-shot inspiration script — produces a layout reference that
matches the Play Store feature-graphic format (1024x500 PNG, no alpha).
The final asset should be redone in Canva with proper typography polish.

Usage:
    python3 scripts/generate_feature_graphic.py

Output:
    release-assets/google-play/feature-graphic-1024x500-draft.png
"""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO_ROOT = Path(__file__).resolve().parents[1]
LOGO_PATH = REPO_ROOT / "assets" / "images" / "rivr_logo.png"
OUTPUT_PATH = (
    REPO_ROOT / "release-assets" / "google-play" / "feature-graphic-1024x500-draft.png"
)

WIDTH, HEIGHT = 1024, 500
TOP_COLOR = (79, 184, 232)
BOTTOM_COLOR = (30, 136, 229)
WHITE = (255, 255, 255)


def vertical_gradient(width: int, height: int, top: tuple, bottom: tuple) -> Image.Image:
    img = Image.new("RGB", (width, height), top)
    pixels = img.load()
    for y in range(height):
        t = y / (height - 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        for x in range(width):
            pixels[x, y] = (r, g, b)
    return img


def draw_river_wave(img: Image.Image) -> None:
    """Draw a subtle white meandering river ribbon across the bottom third."""
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    import math

    points = []
    base_y = HEIGHT * 0.72
    amplitude = 28
    for x in range(0, WIDTH + 1, 4):
        t = x / WIDTH
        y = base_y + math.sin(t * math.pi * 2.2) * amplitude
        points.append((x, y))

    upper = [(x, y - 22) for x, y in points]
    lower = [(x, y + 22) for x, y in reversed(points)]
    polygon = upper + lower
    draw.polygon(polygon, fill=(255, 255, 255, 40))

    overlay = overlay.filter(ImageFilter.GaussianBlur(radius=3))
    img.paste(overlay, (0, 0), overlay)


def load_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    candidates = (
        ["/System/Library/Fonts/Helvetica.ttc"]
        if not bold
        else [
            "/System/Library/Fonts/HelveticaNeue.ttc",
            "/System/Library/Fonts/Helvetica.ttc",
        ]
    )
    for path in candidates:
        try:
            return ImageFont.truetype(path, size=size)
        except OSError:
            continue
    return ImageFont.load_default()


def add_logo(canvas: Image.Image) -> None:
    logo = Image.open(LOGO_PATH).convert("RGBA")
    target_size = 360
    logo = logo.resize((target_size, target_size), Image.LANCZOS)

    shadow = Image.new("RGBA", logo.size, (0, 0, 0, 0))
    shadow_alpha = logo.split()[3].point(lambda a: int(a * 0.35))
    shadow.putalpha(shadow_alpha)
    shadow_blurred = shadow.filter(ImageFilter.GaussianBlur(radius=12))

    x = 60
    y = (HEIGHT - target_size) // 2
    canvas.paste(shadow_blurred, (x + 6, y + 10), shadow_blurred)
    canvas.paste(logo, (x, y), logo)


def add_text(canvas: Image.Image) -> None:
    draw = ImageDraw.Draw(canvas)

    title_font = load_font(140, bold=True)
    tagline_font = load_font(34)
    subline_font = load_font(22)

    text_x = 460
    title_y = 110

    draw.text((text_x, title_y), "RIVR", font=title_font, fill=WHITE)

    tagline = "Real-time river flow"
    tagline2 = "& flood risk forecasts"
    draw.text((text_x, title_y + 160), tagline, font=tagline_font, fill=WHITE)
    draw.text((text_x, title_y + 200), tagline2, font=tagline_font, fill=WHITE)

    subline = "Powered by the NOAA National Water Model"
    draw.text(
        (text_x, title_y + 260),
        subline,
        font=subline_font,
        fill=(255, 255, 255, 200),
    )


def main() -> None:
    canvas = vertical_gradient(WIDTH, HEIGHT, TOP_COLOR, BOTTOM_COLOR)
    draw_river_wave(canvas)
    add_logo(canvas)
    add_text(canvas)

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(OUTPUT_PATH, format="PNG", optimize=True)
    print(f"Wrote {OUTPUT_PATH.relative_to(REPO_ROOT)} ({WIDTH}x{HEIGHT})")


if __name__ == "__main__":
    main()
