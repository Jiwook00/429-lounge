#!/usr/bin/env python3
"""429 드롭 효과음을 합성해서 Sources/Lounge429/Resources/Sounds/에 wav(모노, 44.1kHz, Int16)로 굽는다.

시안(Main.dc.html)의 WebAudio Synth 파라미터를 그대로 옮긴 것: tone(주파수, 길이, 파형, 음량, 시작, 슬라이드).
수정하고 다시 돌리면 같은 파일이 덮어써진다 (난수는 시드 고정).

    python3 scripts/gen_drop_sounds.py
"""
import math
import os
import random
import struct
import wave

SR = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "Lounge429", "Resources", "Sounds")
# 시안의 vol은 master 0.5 기준이라 조용하다. 기존 효과음(피크 0.1~0.3)에 맞추려고 vol에 2를 곱하고 master 0.6을 쓴다
MASTER = 0.6
PENTA = [0, 2, 4, 7, 9]

rng = random.Random(429)


def render(length):
    return [0.0] * int(length * SR)


def tone(buf, f, dur, kind, vol, at=0.0, slide=None):
    """exponentialRamp로 음량이 vol → 0.0001, 주파수가 f → slide"""
    start = int(at * SR)
    n = int(dur * SR)
    phase = 0.0
    for i in range(n):
        if start + i >= len(buf):
            break
        t = i / SR
        freq = f * ((slide / f) ** (t / dur)) if slide else f
        phase += freq / SR
        p = phase % 1.0
        if kind == "square":
            w = 1.0 if p < 0.5 else -1.0
        elif kind == "triangle":
            w = 4 * abs(p - 0.5) - 1
        else:
            w = math.sin(2 * math.pi * p)
        env = vol * ((0.0001 / vol) ** (t / dur))
        attack = min(1.0, i / (0.001 * SR))  # 시작 클릭 방지
        buf[start + i] += w * env * attack * MASTER


def noise(buf, dur, vol, at=0.0, hp=2000):
    start = int(at * SR)
    n = int(dur * SR)
    rc = 1 / (2 * math.pi * hp)
    a = rc / (rc + 1 / SR)
    prev_x = prev_y = 0.0
    for i in range(n):
        if start + i >= len(buf):
            break
        x = (rng.random() * 2 - 1) * (1 - i / n)
        y = a * (prev_y + x - prev_x)
        prev_x, prev_y = x, y
        buf[start + i] += y * vol * MASTER


def motif(buf, k, at, vol):
    """429 모티프: 파-레-높은 레 (음계 4·2·9도)"""
    for i, f in enumerate([349, 294, 587]):
        tone(buf, f * k, 0.12, "square", vol, at + i * 0.11)


def coins(buf, n, at):
    for i in range(n):
        tone(buf, 2000 + rng.random() * 1500, 0.04, "square", 0.03, at + i * 0.035)


def save(name, buf):
    path = os.path.join(OUT, name + ".wav")
    peak = max(1e-9, max(abs(x) for x in buf))
    scale = 1.0 if peak <= 0.95 else 0.95 / peak
    frames = b"".join(struct.pack("<h", int(max(-1, min(1, x * scale)) * 32767)) for x in buf)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(frames)
    print(f"{name}.wav  {len(buf) / SR:.2f}s  peak {peak:.2f}")


def effect(name, length, build):
    buf = render(length)
    build(buf)
    save(name, buf)


def main():
    # 충전음: 루프. 441Hz × 200주기 = 20000샘플이라 이음매가 없다. 앱이 rate 0.45~2.0으로 200~880Hz를 만든다
    n = 20000
    charge = [0.0] * n
    for i in range(n):
        charge[i] = (0.5 if (i * 441 / SR) % 1.0 < 0.5 else -0.5) * 0.12
    save("dropCharge", charge)

    effect("dropLaunch", 0.12, lambda b: tone(b, 220, 0.08, "square", 0.06 * 2, 0, 660))
    effect("dropGood", 0.22, lambda b: tone(b, 1568, 0.16, "sine", 0.1 * 2, 0.02))

    def perfect(b):
        for i, f in enumerate([1047, 1319, 1568, 2093]):
            tone(b, f, 0.08, "triangle", 0.12 * 2, i * 0.045)
    effect("dropPerfect", 0.3, perfect)

    # 일반 핀: 줄이 내려갈수록 펜타토닉으로 한 음씩 올라간다 (줄 0~11)
    for row in range(12):
        semi = 12 * (row // 5) + PENTA[row % 5]
        effect(f"dropPin{row}", 0.05, lambda b, s=semi: tone(b, 784 * 2 ** (s / 12), 0.03, "square", 0.1))

    def gold(b):
        tone(b, 1319, 0.08, "triangle", 0.12 * 2)
        tone(b, 1976, 0.14, "triangle", 0.12 * 2, 0.05)
    effect("dropGold", 0.25, gold)

    def split(b):
        tone(b, 1200, 0.06, "square", 0.05 * 2, 0, 1800)
        tone(b, 1200, 0.06, "square", 0.05 * 2, 0.07, 1800)
    effect("dropSplit", 0.16, split)

    effect("dropLand", 0.14, lambda b: tone(b, 180, 0.1, "sine", 0.12 * 2, 0, 110))

    def top(b):
        motif(b, 2, 0, 0.1 * 2)
        for f in [523, 659, 784, 1047]:
            tone(b, f, 0.7, "triangle", 0.05 * 2, 0.36)
        coins(b, 20, 0.36)
    effect("dropMax", 1.4, top)

    effect("dropPocket", 0.22, lambda b: tone(b, 1200, 0.18, "triangle", 0.12 * 2, 0, 300))

    def reach(b):
        tone(b, 110, 0.12, "sine", 0.16 * 2)
        tone(b, 110, 0.1, "sine", 0.12 * 2, 0.14)
    effect("dropReach", 0.28, reach)

    def fever(b):
        motif(b, 2, 0, 0.12 * 2)
        motif(b, 4, 0.4, 0.08 * 2)
        noise(b, 0.2, 0.1 * 2, 0, 800)
        coins(b, 16, 0.4)
    effect("dropFever", 1.2, fever)


if __name__ == "__main__":
    main()
