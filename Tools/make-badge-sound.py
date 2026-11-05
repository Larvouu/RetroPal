#!/usr/bin/env python3
"""Synthesizes `EmulateurGBA/Resources/story-badge.wav`, the Retro story badge
unlock sound (2026-10-29). Made here, from nothing but arithmetic, so the app
carries no third-party audio and the public GPL snapshot stays provenance-clean
(the RetroAchievements sounds are self-made squares for the same reason).

Deliberately unlike the RA unlock (a square-wave C-major arpeggio climbing):
a coin-style two-step pickup on a thin pulse (12.5 % duty, the NES's brightest
channel), then a triangle-wave sparkle that rises and fades, the sound of a
token landing rather than a fanfare. Mono, 16-bit, 44.1 kHz, about 0.6 s.

    python3 Tools/make-badge-sound.py
"""
import math, struct, wave, pathlib

RATE = 44100

def pulse(freq, t, duty):
    return 1.0 if (t * freq) % 1.0 < duty else -1.0

def triangle(freq, t):
    p = (t * freq) % 1.0
    return 4 * p - 1 if p < 0.5 else 3 - 4 * p

def note(samples, start, dur, freq, wave_fn, vol, attack=0.004, release=0.06):
    n0, n = int(start * RATE), int(dur * RATE)
    for i in range(n):
        t = i / RATE
        env = min(1.0, t / attack) * (1.0 if t < dur - release else max(0.0, (dur - t) / release))
        if n0 + i < len(samples):
            samples[n0 + i] += wave_fn(freq, t) * vol * env

def main():
    total = 0.62
    s = [0.0] * int(total * RATE)
    # The pickup: B5 then E6, short and bright, a hair of overlap.
    note(s, 0.000, 0.070, 987.77, lambda f, t: pulse(f, t, 0.125), 0.30, release=0.02)
    note(s, 0.065, 0.200, 1318.51, lambda f, t: pulse(f, t, 0.125), 0.30, release=0.12)
    # The sparkle: a quick rising triangle run, G6 B6 D7 G7, softer, fading.
    for k, f in enumerate([1567.98, 1975.53, 2349.32, 3135.96]):
        note(s, 0.16 + k * 0.05, 0.16, f, triangle, 0.22 * (1 - k * 0.18), release=0.1)
    peak = max(abs(x) for x in s) or 1
    out = pathlib.Path(__file__).resolve().parent.parent / "EmulateurGBA/Resources/story-badge.wav"
    with wave.open(str(out), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(x / peak * 0.85 * 32767)) for x in s))
    print("wrote", out)

if __name__ == "__main__":
    main()
