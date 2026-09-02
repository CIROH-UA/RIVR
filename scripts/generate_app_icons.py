"""Regenerate every launcher-icon and splash-logo asset from one source image.

The source is a single full-bleed square PNG — artwork that runs edge to edge,
with no rounded corners and no padding baked in. Every platform applies its own
mask, so baking a shape into the source is how an icon ends up with a visible
white hairline inside iOS's superellipse, or a double-rounded corner on Android.

    python3 scripts/generate_app_icons.py [path/to/source.png]

Defaults to release-assets/app-icon/rivr-launch-icon.png.

What it writes
--------------
iOS app icon      ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png
                  Full-bleed and opaque. iOS rejects alpha in an app icon, and
                  it draws its own superellipse mask, so the artwork must fill
                  the square. The previous set sat at 73% of the canvas inside a
                  white border, which made RIVR the one small icon on the home
                  screen. Contents.json is unchanged — the filenames still match.

Android legacy    android/app/src/main/res/mipmap-*/rivr.png
                  Pre-API-26 launchers apply no mask, so the shape has to be in
                  the file. Squircle with transparent corners.

Android adaptive  android/app/src/main/res/mipmap-*/rivr_background.png
                  API 26+. The artwork is the BACKGROUND layer, full-bleed, and
                  the foreground is transparent. The alternative — artwork as
                  foreground — must fit the inner 66% safe zone, which would
                  shrink the river to two thirds and leave a flat ring around
                  it. Both layers get the same launcher mask either way.

Splash logo       android/app/src/main/res/drawable-*/launch_logo.png
                  ios/.../LaunchImage.imageset/LaunchImage*.png
                  A squircle floating on a white ground, matching the launch
                  screens already in the project. Proportions are copied from
                  the assets being replaced: 72.7% of the canvas for the legacy
                  and iOS splashes, 44.1% for the Android 12+ splash, whose icon
                  the system masks to a circle of two thirds the canvas.
"""

import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = REPO_ROOT / "release-assets" / "app-icon" / "rivr-launch-icon.png"

ANDROID_RES = REPO_ROOT / "android" / "app" / "src" / "main" / "res"
IOS_APPICON = (
    REPO_ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
)
IOS_LAUNCH = (
    REPO_ROOT / "ios" / "Runner" / "Assets.xcassets" / "LaunchImage.imageset"
)

# Every filename referenced by AppIcon.appiconset/Contents.json. The set is
# deduplicated by pixel size, which is why 120 and 40 each serve two entries.
IOS_ICON_SIZES = [20, 29, 40, 57, 58, 60, 76, 80, 87, 114, 120, 152, 167, 180, 1024]

# Launcher icon, in px, per density bucket (48dp baseline).
ANDROID_DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

# Splash canvas per density, matching the files already in the project.
SPLASH_DENSITIES = {
    "mdpi": 200,
    "hdpi": 300,
    "xhdpi": 400,
    "xxhdpi": 600,
    "xxxhdpi": 800,
}

# iOS splash canvas per scale factor.
IOS_SPLASH = {"LaunchImage.png": 200, "LaunchImage@2x.png": 400, "LaunchImage@3x.png": 600}

# Fraction of the splash canvas the logo occupies. Measured off the assets
# being replaced rather than chosen — see the module docstring.
SPLASH_LOGO_FRACTION = 0.727
V31_CANVAS = 1152
V31_LOGO_FRACTION = 0.441

# Superellipse exponent. 5 is the usual approximation of Apple's squircle;
# a plain rounded rectangle reads as visibly boxier beside real app icons.
SQUIRCLE_EXPONENT = 5.0
SUPERSAMPLE = 4


def squircle_mask(size: int) -> Image.Image:
    """An 8-bit mask of a superellipse filling a `size` square, antialiased.

    Drawn at SUPERSAMPLE resolution and downsampled, because the mask is
    computed per pixel rather than rasterised by a drawing library, so the
    edge would otherwise be hard.
    """
    n = size * SUPERSAMPLE
    # Pixel centres mapped to [-1, 1].
    axis = (np.arange(n) + 0.5) / n * 2.0 - 1.0
    x = np.abs(axis)[None, :]
    y = np.abs(axis)[:, None]
    inside = (x**SQUIRCLE_EXPONENT + y**SQUIRCLE_EXPONENT) <= 1.0
    big = Image.fromarray((inside * 255).astype(np.uint8), mode="L")
    return big.resize((size, size), Image.LANCZOS)


def resized(source: Image.Image, size: int) -> Image.Image:
    return source.resize((size, size), Image.LANCZOS)


def full_bleed_opaque(source: Image.Image, size: int) -> Image.Image:
    """Square RGB with no alpha channel at all — what iOS app icons require."""
    return resized(source, size).convert("RGB")


def squircled(source: Image.Image, size: int) -> Image.Image:
    """The artwork masked to a squircle, transparent outside it."""
    icon = resized(source, size).convert("RGBA")
    icon.putalpha(squircle_mask(size))
    return icon


def splash_logo(source: Image.Image, canvas: int, fraction: float) -> Image.Image:
    """A squircled logo centred on a transparent canvas."""
    logo_size = max(1, round(canvas * fraction))
    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    offset = (canvas - logo_size) // 2
    out.paste(squircled(source, logo_size), (offset, offset))
    return out


def write(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, "PNG")
    print(f"  {path.relative_to(REPO_ROOT)}  {image.size[0]}x{image.size[1]} {image.mode}")


def main() -> int:
    source_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SOURCE
    if not source_path.is_file():
        print(f"Source image not found: {source_path}", file=sys.stderr)
        return 1

    source = Image.open(source_path).convert("RGBA")
    if source.size[0] != source.size[1]:
        print(f"Source must be square, got {source.size}", file=sys.stderr)
        return 1
    if source.size[0] < 1024:
        print(
            f"Source is {source.size[0]}px; 1024 is the largest icon needed, so "
            "anything smaller upscales.",
            file=sys.stderr,
        )
        return 1
    print(f"Source: {source_path} ({source.size[0]}px)")

    print("iOS app icon (full-bleed, no alpha):")
    for size in IOS_ICON_SIZES:
        write(full_bleed_opaque(source, size), IOS_APPICON / f"{size}.png")

    print("Android legacy launcher icon (squircle, transparent corners):")
    for bucket, size in ANDROID_DENSITIES.items():
        write(squircled(source, size), ANDROID_RES / f"mipmap-{bucket}" / "rivr.png")

    print("Android adaptive icon layers (artwork as background, empty foreground):")
    for bucket, size in ANDROID_DENSITIES.items():
        # 108dp of layer for 48dp of visible icon: the launcher mask crops the
        # rest, and some launchers pan the layers behind it.
        layer = round(size * 108 / 48)
        write(
            resized(source, layer).convert("RGBA"),
            ANDROID_RES / f"mipmap-{bucket}" / "rivr_background.png",
        )
        write(
            Image.new("RGBA", (layer, layer), (0, 0, 0, 0)),
            ANDROID_RES / f"mipmap-{bucket}" / "rivr_foreground.png",
        )

    print("Android splash logo (API 21-30):")
    for bucket, canvas in SPLASH_DENSITIES.items():
        logo = splash_logo(source, canvas, SPLASH_LOGO_FRACTION)
        write(logo, ANDROID_RES / f"drawable-{bucket}" / "launch_logo.png")

    print("Android 12+ splash icon (system masks it to a circle):")
    write(
        splash_logo(source, V31_CANVAS, V31_LOGO_FRACTION),
        ANDROID_RES / "drawable-v31" / "launch_logo.png",
    )

    print("iOS splash logo:")
    for filename, canvas in IOS_SPLASH.items():
        write(splash_logo(source, canvas, SPLASH_LOGO_FRACTION), IOS_LAUNCH / filename)

    print("Store listing icon:")
    write(
        full_bleed_opaque(source, 1024),
        REPO_ROOT / "release-assets" / "app-store" / "icon" / "icon-1024x1024.png",
    )
    # Play masks the listing icon itself, so it takes the same full-bleed square.
    write(
        full_bleed_opaque(source, 512),
        REPO_ROOT / "release-assets" / "google-play" / "icon" / "icon-512x512.png",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
