"""Render a terminal-style demo video from a captured run_demo.sh log (no screen recording needed).

  python3 demo/video/render.py <log> <out.mp4>
Frames are drawn with Pillow, encoded with ffmpeg. Typing is animated for commands, output appears line by line.
"""
import subprocess, sys, textwrap
from PIL import Image, ImageDraw, ImageFont

LOG, OUT = sys.argv[1], sys.argv[2]
W, H, FPS = 1280, 720, 30
MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
font = ImageFont.truetype(MONO, 20); bold = ImageFont.truetype(BOLD, 20)
title_f = ImageFont.truetype(BOLD, 44); sub_f = ImageFont.truetype(MONO, 24)
BG, FG, DIM, GREEN, AMBER, RED = (18, 22, 28), (231, 235, 240), (120, 130, 145), (61, 187, 138), (224, 164, 69), (226, 123, 123)
LINE_H, PAD, MAX_LINES = 28, 36, 22

def card(lines, hold_s):
    im = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(im); y = 200
    for i, (txt, f, col) in enumerate(lines):
        d.text((PAD + 40, y), txt, font=f, fill=col); y += 64 if i == 0 else 40
    return [im] * int(hold_s * FPS)

def color_for(line):
    if line.startswith("--"): return AMBER
    if "reverted as expected" in line: return GREEN
    if line.startswith("==") or "!!" in line: return FG
    return FG if not line.startswith("   ") else DIM

def screen(lines, cursor=True):
    im = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(im)
    d.rectangle([0, 0, W, 44], fill=(28, 34, 42)); d.text((PAD, 11), "reins — demo on Robinhood Chain testnet (46630)", font=bold, fill=DIM)
    y = 60
    for txt, col in lines[-MAX_LINES:]:
        d.text((PAD, y), txt, font=font, fill=col); y += LINE_H
    if cursor: d.rectangle([PAD, y + 4, PAD + 11, y + 24], fill=GREEN)
    return im

frames = []
frames += card([("Reins", title_f, GREEN), ("Policy-bound execution vaults for AI agents", sub_f, FG),
                ("on Robinhood Chain (Arbitrum Orbit)", sub_f, FG), ("", sub_f, FG),
                ("github.com/BinLiang2021/reins", sub_f, DIM)], 3.5)
buf = [("$ ./demo/run_demo.sh", FG)]
typed = ""
for ch in "RPC_URL=https://rpc.testnet.chain.robinhood.com ./demo/run_demo.sh":
    typed += ch; buf[0] = ("$ " + typed, FG); frames.append(screen(buf))
    frames += [frames[-1]] * 1
frames += [screen(buf)] * (FPS // 2)
for raw in open(LOG, encoding="utf-8").read().splitlines():
    for line in textwrap.wrap(raw, 100, subsequent_indent="   ") or [""]:
        buf.append((line, color_for(line)))
    pause = 1.2 if raw.startswith("--") else 0.5
    if "reverted as expected" in raw or "== demo complete" in raw: pause = 2.0
    frames += [screen(buf)] * int(pause * FPS)
frames += [screen(buf, cursor=False)] * FPS
frames += card([("What the chain enforced", title_f, GREEN),
                ("• $1,000/day cap priced by Chainlink", sub_f, FG), ("• allowlisted tokens, router, payee", sub_f, FG),
                ("• over-cap swap reverted; revoke locked the agent out", sub_f, FG), ("• owner withdrew; agent never had custody", sub_f, FG),
                ("", sub_f, FG), ("explorer.testnet.chain.robinhood.com/address/0x8B7EDa130B54c89aeea454018CAe0dE7b95e62f8", sub_f, DIM)], 5)

proc = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS),
                         "-i", "-", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "medium", "-crf", "20", OUT], stdin=subprocess.PIPE)
for fr in frames: proc.stdin.write(fr.tobytes())
proc.stdin.close(); proc.wait()
print(f"wrote {OUT}: {len(frames)/FPS:.1f}s, {len(frames)} frames")
