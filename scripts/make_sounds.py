#!/usr/bin/env python3
"""Synthesizes Notchling's sound effects from scratch (no samples) into Notchling/Resources/sounds.

Run:  python3 scripts/make_sounds.py        (needs numpy)
"""
import os
import wave
import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "Notchling", "Resources", "sounds")
rng = np.random.default_rng(7)


def t(d):
    return np.arange(int(SR * d)) / SR


def env(n, a=0.005, r=0.08):
    e = np.ones(n)
    na, nr = max(1, int(SR * a)), max(1, int(SR * r))
    e[:na] = np.linspace(0, 1, na)
    e[-nr:] *= np.linspace(1, 0, nr)
    return e


def sweep(f0, f1, d, shape="sine", vib=0.0, vibf=0.0):
    tt = t(d)
    f = np.geomspace(f0, f1, len(tt)) if f0 > 0 and f1 > 0 else np.linspace(f0, f1, len(tt))
    if vib:
        f = f * (1 + vib * np.sin(2 * np.pi * vibf * tt))
    ph = 2 * np.pi * np.cumsum(f) / SR
    if shape == "tri":
        return 2 / np.pi * np.arcsin(np.sin(ph))
    return np.sin(ph) + 0.18 * np.sin(2 * ph)


def tone(f0, f1, d, **k):
    s = sweep(f0, f1, d, **{x: y for x, y in k.items() if x in ("shape", "vib", "vibf")})
    return s * env(len(s), k.get("a", 0.005), k.get("r", min(0.08, d * 0.6)))


def noise(d, lp=0.2):
    n = rng.standard_normal(int(SR * d))
    y = np.zeros_like(n)
    for i in range(1, len(n)):  # simple one-pole low-pass
        y[i] = y[i - 1] + lp * (n[i] - y[i - 1])
    return y / (np.max(np.abs(y)) + 1e-9)


def seq(*parts, gap=0.0):
    g = np.zeros(int(SR * gap))
    out = []
    for p in parts:
        out += [p, g]
    return np.concatenate(out)


def mix(*parts):
    n = max(len(p) for p in parts)
    return sum(np.pad(p, (0, n - len(p))) for p in parts)


def save(name, x, gain=0.6):
    x = x / (np.max(np.abs(x)) + 1e-9) * gain
    x = np.concatenate([np.zeros(int(SR * 0.004)), x, np.zeros(int(SR * 0.02))])
    os.makedirs(OUT, exist_ok=True)
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767).astype(np.int16).tobytes())


save("peek", tone(700, 1250, 0.09, shape="tri"))
save("open", seq(tone(520, 780, 0.07), tone(780, 1040, 0.09), gap=0.01), 0.45)
save("close", seq(tone(900, 650, 0.07), tone(620, 420, 0.09), gap=0.01), 0.4)
save("wave", seq(tone(880, 1320, 0.08, vib=0.02, vibf=30), tone(1100, 1650, 0.12, vib=0.03, vibf=28), gap=0.03))
save("poke", tone(520, 260, 0.12, shape="tri"))
save("dizzy", tone(900, 250, 0.9, vib=0.12, vibf=7, r=0.2), 0.5)
munch = [noise(0.05, 0.35) * env(int(SR * 0.05), 0.002, 0.03) * 0.8 for _ in range(3)]
save("munch", seq(*munch, gap=0.07))
bloops = [tone(f, f * 1.9, 0.06, shape="tri") for f in (420, 520, 380, 610, 470)]
save("splash", mix(noise(0.5, 0.08) * env(int(SR * 0.5), 0.01, 0.3) * 0.35, seq(*bloops, gap=0.035)))
purr_t = t(0.55)
purr = np.sin(2 * np.pi * 95 * purr_t) * (0.55 + 0.45 * np.sin(2 * np.pi * 22 * purr_t)) * env(len(purr_t), 0.05, 0.2)
save("purr", seq(purr * 0.7, tone(1000, 1500, 0.1)), 0.5)
save("yawn", tone(620, 300, 0.75, vib=0.04, vibf=5, a=0.08, r=0.3), 0.45)
save("gulp", seq(tone(300, 140, 0.09), tone(500, 900, 0.05), gap=0.02))
save("think", seq(tone(1400, 1400, 0.03), tone(1700, 1700, 0.03), gap=0.05), 0.3)
save("answer", seq(tone(784, 784, 0.1), tone(1175, 1175, 0.18, r=0.12), gap=0.02), 0.45)
save("alert", seq(tone(1320, 1320, 0.06), tone(1320, 1320, 0.06), tone(1760, 1760, 0.1), gap=0.05), 0.4)
save("sad", seq(tone(660, 620, 0.16), tone(560, 470, 0.3, vib=0.02, vibf=6), gap=0.03), 0.45)
crack = noise(0.04, 0.9) * env(int(SR * 0.04), 0.001, 0.03)
save("hatch", seq(crack, crack, tone(900, 1500, 0.1), tone(1200, 1900, 0.14), gap=0.06))
save("pop", tone(400, 1100, 0.06, shape="tri"))
print("sounds written to", os.path.abspath(OUT))
