import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 1024            # final size
SS = 2              # supersample
N = S * SS

margin = int(0.085 * N)
tile = N - 2 * margin
radius = int(0.225 * tile)
cx = cy = N / 2.0

# --- background: subtle warm-charcoal vertical gradient + radial CRT glow ---
top = np.array([0x1a, 0x14, 0x0e], float)
bot = np.array([0x09, 0x0a, 0x0f], float)
t = np.linspace(0, 1, N)
bg = top[None, :] * (1 - t[:, None]) + bot[None, :] * t[:, None]   # (N,3) per row
bg = np.repeat(bg[:, None, :], N, axis=1)                          # (N,N,3)

Y, X = np.mgrid[0:N, 0:N]
r = np.sqrt((X - cx) ** 2 + (Y - cy) ** 2) / (tile * 0.5)
radial = np.clip(1 - r, 0, 1) ** 2
bg += radial[..., None] * np.array([55, 26, 9], float)

# --- Lissajous figure-8 (x = sin 2t, y = sin t) ---
tt = np.linspace(0, 2 * np.pi, 5000)
A = tile * 0.5 * 0.62
x = cx + A * np.sin(2 * tt)
y = cy + A * np.sin(tt)
pts = list(zip(x.tolist(), y.tolist()))

def stroke(width):
    im = Image.new("L", (N, N), 0)
    ImageDraw.Draw(im).line(pts, fill=255, width=int(width), joint="curve")
    return im

# bloom: a few blurred copies of the trace, summed additively
glow = stroke(0.020 * N)
gimg = np.zeros((N, N), float)
for rad, amp in [(0.012 * N, 1.0), (0.030 * N, 0.75), (0.065 * N, 0.5)]:
    gimg += np.asarray(glow.filter(ImageFilter.GaussianBlur(rad)), float) / 255.0 * amp
glow_rgb = np.clip(gimg, 0, 2.2)[..., None] * np.array([255, 120, 45], float)

# bright near-white core
core = stroke(0.008 * N).filter(ImageFilter.GaussianBlur(0.0022 * N))
core_rgb = (np.asarray(core, float) / 255.0)[..., None] * np.array([255, 224, 178], float)

out = np.clip(bg + glow_rgb * 0.9 + core_rgb, 0, 255).astype(np.uint8)
img = Image.fromarray(out, "RGB").convert("RGBA")

# rounded-rect tile mask
mask = Image.new("L", (N, N), 0)
ImageDraw.Draw(mask).rounded_rectangle([margin, margin, N - margin, N - margin],
                                       radius=radius, fill=255)
img.putalpha(mask)

# soft drop shadow on a transparent canvas
canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
shadow_alpha = mask.filter(ImageFilter.GaussianBlur(0.022 * N)).point(lambda v: int(v * 0.45))
shadow = Image.new("RGBA", (N, N), (0, 0, 0, 255))
shadow.putalpha(shadow_alpha)
canvas = Image.alpha_composite(canvas, ImageChops.offset(shadow, 0, int(0.012 * N)))
canvas = Image.alpha_composite(canvas, img)

canvas.resize((S, S), Image.LANCZOS).save("/tmp/scope_icon_1024.png")
print("wrote /tmp/scope_icon_1024.png")
