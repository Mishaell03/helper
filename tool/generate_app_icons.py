"""Regenerate platform icons from assets/branding/logo.png (requires Pillow)."""

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/branding/logo.png"


def generate():
    with Image.open(SOURCE) as image:
        image = image.convert("RGB")

        def png(relative, size):
            target = ROOT / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            image.resize((size, size), Image.Resampling.LANCZOS).save(target)

        image.save(
            ROOT / "windows/runner/resources/app_icon.ico",
            format="ICO",
            sizes=[(n, n) for n in (16, 20, 24, 32, 40, 48, 64, 128, 256)],
        )
        for size in (16, 32, 64, 128, 256, 512, 1024):
            png(f"macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png", size)
        png("web/favicon.png", 32)
        for size in (192, 512):
            png(f"web/icons/Icon-{size}.png", size)
            png(f"web/icons/Icon-maskable-{size}.png", size)
        branding = ROOT / "installer/branding"
        branding.mkdir(parents=True, exist_ok=True)
        image.resize((55, 55), Image.Resampling.LANCZOS).save(branding / "wizard-small.bmp")
        wizard = Image.new("RGB", (164, 314), "black")
        wizard.paste(image.resize((164, 164), Image.Resampling.LANCZOS), (0, 75))
        wizard.save(branding / "wizard.bmp")


if __name__ == "__main__":
    generate()
