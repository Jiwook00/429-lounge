#!/usr/bin/env python3
"""429 드롭 환수율 계산기 (ADR-0018).

공이 서로 영향을 주지 않으므로 (줄, 칸, 분열 여부) 위의 DP로 기대값을 정확히 계산한다.
`--mc N`을 주면 같은 규칙으로 공 N개를 무작위로 굴려 DP와 비교한다.
수치를 바꾸면 서버 마이그레이션(`plinko_*`)과 docs/chip-economy.md도 같이 고친다.

    python3 scripts/drop_ev.py            # 레인 × 등급 표
    python3 scripts/drop_ev.py --mc 300000
"""
from functools import lru_cache
import random
import sys

ROWS = 12                       # 핀 줄 수. 줄 r에는 핀 r+3개, 칸 번호 j는 -(r+2)..(r+2) 짝수 간격
BUCKETS = [16, 4, 1.8, 1.3, 1.0, 0.6, 0.4, 0.6, 1.0, 1.3, 1.8, 4, 16]  # 건 칩 포함 배수
GOLD = {(8, 4), (8, -4)}        # 골드 핀: 맞은 공의 최종 배수 +GOLD_BONUS
GOLD_BONUS = 0.3
SPLIT = {(10, 8), (10, -8)}     # 분열 핀: 공이 둘로. 공 하나당 한 번, FEVER 공은 분열하지 않음
POCKET = (6, 0)                 # 스타트 포켓
POCKET_CATCH = {'none': 0.0947, 'good': 0.1008, 'perfect': 0.1068}  # 등급별 포켓이 공을 잡을 확률
FEVER_ODDS = 1 / 8              # 포켓에 들어간 뒤 FEVER(429 429 429) 확률
REFUND = 0.2                    # FEVER가 아니면 건 칩의 20% 환급
FEVER_BALLS = 15
FEVER_MULT = 2
# 레인: 왼쪽·오른쪽 레인 공은 입구 가이드 핀(0, ±2)에 맞아 안쪽 (1, ∓1)로 간다.
# 가운데 레인 공은 (0, 0)에서 무작위. 그래서 세 레인의 기대값이 같다.
LANES = {'L': [(-1, 1.0)], 'C': [(-1, 0.5), (1, 0.5)], 'R': [(1, 1.0)]}


def final_bucket(j, d):
    jf = j + d
    if jf > 12:
        jf = j - 1
    if jf < -12:
        jf = j + 1
    return (jf + 12) // 2


def solver(fever, catch, pocket_value):
    @lru_cache(None)
    def V(r, j, split_used):
        """(r, j) 핀에 닿은 공 하나의 (기대 배수, 칸에 떨어지는 공 수 기대값)."""
        if (r, j) == POCKET and not fever and catch > 0:
            v, c = bounce(r, j, split_used)
            return (catch * pocket_value + (1 - catch) * v, (1 - catch) * c)
        return bounce(r, j, split_used)

    def child(r, j, d, s):
        if r == ROWS - 1:
            return (BUCKETS[final_bucket(j, d)] * (FEVER_MULT if fever else 1), 1.0)
        return V(r + 1, j + d, s)

    def bounce(r, j, s):
        if (r, j) in SPLIT and not s and not fever:
            a, b = child(r, j, 1, True), child(r, j, -1, True)
            val, cnt = a[0] + b[0], a[1] + b[1]
        else:
            a, b = child(r, j, 1, s), child(r, j, -1, s)
            val, cnt = 0.5 * (a[0] + b[0]), 0.5 * (a[1] + b[1])
        if (r, j) in GOLD:
            val += GOLD_BONUS * cnt
        return (val, cnt)

    def lane(name):
        return sum(p * V(1, j, False)[0] for j, p in LANES[name])

    return lane


def fever_ball():
    lane = solver(True, 0, 0)
    return sum(lane(n) for n in LANES) / len(LANES)


def pocket_value():
    return FEVER_ODDS * FEVER_BALLS * fever_ball() + (1 - FEVER_ODDS) * REFUND


def table():
    pv = pocket_value()
    return {g: {n: solver(False, q, pv)(n) for n in LANES} for g, q in POCKET_CATCH.items()}


def monte_carlo(n, grade='none', seed=429):
    rnd = random.Random(seed)
    catch = POCKET_CATCH[grade]

    def run(lane, fever):
        js, ps = zip(*LANES[lane])
        start = rnd.choices(js, ps)[0]
        stack, pay = [(1, start, 0.0, False)], 0.0
        while stack:
            r, j, gold, s = stack.pop()
            while True:
                if (r, j) == POCKET and not fever and rnd.random() < catch:
                    if rnd.random() < FEVER_ODDS:
                        pay += sum(run(rnd.choice('LCR'), True) for _ in range(FEVER_BALLS))
                    else:
                        pay += REFUND
                    break
                if (r, j) in GOLD:
                    gold += GOLD_BONUS
                d = 1 if rnd.random() < 0.5 else -1
                if (r, j) in SPLIT and not s and not fever:
                    s = True
                    if r == ROWS - 1:
                        pay += BUCKETS[final_bucket(j, -d)] + gold
                    else:
                        stack.append((r + 1, j - d, gold, True))
                if r == ROWS - 1:
                    pay += BUCKETS[final_bucket(j, d)] * (FEVER_MULT if fever else 1) + gold
                    break
                r, j = r + 1, j + d
        return pay

    return {lane: sum(run(lane, False) for _ in range(n)) / n for lane in LANES}


if __name__ == '__main__':
    t = table()
    print('등급      ' + '  '.join(f'{n:>7}' for n in LANES))
    for g, row in t.items():
        print(f'{g:<8}  ' + '  '.join(f'{v * 100:6.2f}%' for v in row.values()))
    print(f'FEVER 공 하나 기대 배수 {fever_ball():.4f}, 포켓 가치 {pocket_value():.4f}')
    if '--mc' in sys.argv:
        n = int(sys.argv[sys.argv.index('--mc') + 1])
        print('MC none  ' + '  '.join(f'{v * 100:6.2f}%' for v in monte_carlo(n).values()))
