#!/usr/bin/env python3
"""429 드롭 환수율 계산기 (ADR-0018, ADR-0019).

공이 서로 영향을 주지 않으므로 (줄, 칸, 분열 여부) 위의 DP로 공 하나의 기대값을 정확히 계산한다.
4·2·9 글자(보드 레벨 0~3)는 포켓 사이에만 바뀌는 상태다. 레벨마다 핀이 다르므로 레벨별로 DP를 돌리고,
포켓 사이 구간의 장기 비율(레벨마다 포켓까지의 기대 판 수가 같다)로 평균을 낸다.
`--mc N`을 주면 같은 규칙으로 공 N개를 레벨까지 이어서 굴려 DP와 비교하고 결과 분포를 찍는다.
수치를 바꾸면 서버 마이그레이션(`plinko_*`)과 docs/chip-economy.md도 같이 고친다.

    python3 scripts/drop_ev.py            # 레벨 × 등급 표 (평소 / VIP HOUR), 금액 바꾸기 전략
    python3 scripts/drop_ev.py --mc 300000
"""
from functools import lru_cache
import random
import sys

ROWS = 12                       # 핀 줄 수. 줄 r에는 핀 r+3개, 칸 번호 j는 -(r+2)..(r+2) 짝수 간격
BUCKETS = [16, 5, 2, 1.4, 0.8, 0.5, 0.3, 0.5, 0.8, 1.4, 2, 5, 16]  # 건 칩 포함 배수
GOLD_BONUS = 0.3                # 골드 핀: 맞은 공의 최종 배수 +0.3
# 보드 레벨(= 켜진 글자 수)마다 핀. 레벨이 오르면 앞 레벨 핀에 더해진다. FEVER 공은 늘 레벨 0 핀
GOLD_BY_LEVEL = [
    {(8, 4), (8, -4)},                       # 기본
    {(6, 6), (6, -6)},                       # 4
    set(),                                   # 4·2
    {(9, 5), (9, -5), (7, 3), (7, -3)},      # 4·2·9 HOT
]
SPLIT_BY_LEVEL = [
    {(10, 8), (10, -8)},                     # 기본. 분열은 공 하나당 한 번, FEVER 공은 분열하지 않음
    set(),
    {(9, 7), (9, -7)},                       # 4·2: 파란 분열 핀
    set(),
]
LEVELS = len(GOLD_BY_LEVEL)     # 0~3. 3(HOT)은 다음 포켓에서 0으로
POCKET = (6, 0)                 # 스타트 포켓
POCKET_CATCH = {'none': 0.0700, 'good': 0.0730, 'perfect': 0.0761}  # 등급별 포켓이 공을 잡을 확률
VIP_CATCH = 0.0424              # VIP HOUR(황금 칩 유효 시간)엔 포켓 입구가 이만큼 넓다
FEVER_ODDS = 1 / 8              # 포켓에 들어간 뒤 FEVER(429 429 429) 확률
REFUND = 0.2                    # FEVER가 아니면 건 칩의 20% 환급
FEVER_BALLS = 40
FEVER_MULT = 1.5
STAKES = [10, 50, 100, 200]
# 레인: 왼쪽·오른쪽 레인 공은 입구 가이드 핀(0, ±2)에 맞아 안쪽 (1, ∓1)로 간다.
# 가운데 레인 공은 (0, 0)에서 무작위. 그래서 세 레인의 기대값이 같다.
LANES = {'L': [(-1, 1.0)], 'C': [(-1, 0.5), (1, 0.5)], 'R': [(1, 1.0)]}


def pins(level):
    gold = set().union(*GOLD_BY_LEVEL[:level + 1])
    split = set().union(*SPLIT_BY_LEVEL[:level + 1])
    return gold, split


def final_bucket(j, d):
    jf = j + d
    if jf > 12:
        jf = j - 1
    if jf < -12:
        jf = j + 1
    return (jf + 12) // 2


def solver(fever, catch, pocket_value, level=0):
    gold, split = pins(0 if fever else level)

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
        if (r, j) in split and not s and not fever:
            a, b = child(r, j, 1, True), child(r, j, -1, True)
            val, cnt = a[0] + b[0], a[1] + b[1]
        else:
            a, b = child(r, j, 1, s), child(r, j, -1, s)
            val, cnt = 0.5 * (a[0] + b[0]), 0.5 * (a[1] + b[1])
        if (r, j) in gold:
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


def level_share():
    """포켓 사이 구간의 레벨 비율. 포켓마다 1/8 FEVER면 0, 아니면 한 칸 오르고 HOT(3)은 0으로."""
    stay = 1 - FEVER_ODDS
    raw = [stay ** k for k in range(LEVELS)]
    return [x / sum(raw) for x in raw]


def by_level(grade='none', vip=False, lane='C'):
    pv = pocket_value()
    q = POCKET_CATCH[grade] + (VIP_CATCH if vip else 0)
    return [solver(False, q, pv, lv)(lane) for lv in range(LEVELS)]


def flat(grade='none', vip=False, lane='C'):
    return sum(s * r for s, r in zip(level_share(), by_level(grade, vip, lane)))


def strategy(stakes, grade='none', vip=False):
    """레벨마다 다른 금액을 걸 때의 환수율 (칩 가중)."""
    r, s = by_level(grade, vip), level_share()
    return sum(s[k] * stakes[k] * r[k] for k in range(LEVELS)) / sum(s[k] * stakes[k] for k in range(LEVELS))


def monte_carlo(n, grade='none', vip=False, seed=429):
    rnd = random.Random(seed)
    catch = POCKET_CATCH[grade] + (VIP_CATCH if vip else 0)
    level = 0

    def run(lane, fever, lv):
        nonlocal level
        gold, split = pins(0 if fever else lv)
        js, ps = zip(*LANES[lane])
        start = rnd.choices(js, ps)[0]
        stack, pay = [(1, start, 0.0, False)], 0.0
        while stack:
            r, j, g, s = stack.pop()
            while True:
                if (r, j) == POCKET and not fever and rnd.random() < catch:
                    if rnd.random() < FEVER_ODDS:
                        level = 0
                        pay += sum(run(rnd.choice('LCR'), True, 0) for _ in range(FEVER_BALLS))
                    else:
                        level = 0 if level == LEVELS - 1 else level + 1
                        pay += REFUND
                    break
                if (r, j) in gold:
                    g += GOLD_BONUS
                d = 1 if rnd.random() < 0.5 else -1
                if (r, j) in split and not s and not fever:
                    s = True
                    if r == ROWS - 1:
                        pay += BUCKETS[final_bucket(j, -d)] + g
                    else:
                        stack.append((r + 1, j - d, g, True))
                if r == ROWS - 1:
                    pay += BUCKETS[final_bucket(j, d)] * (FEVER_MULT if fever else 1) + g
                    break
                r, j = r + 1, j + d
        return pay

    return [run('C', False, level) for _ in range(n)]


if __name__ == '__main__':
    share = level_share()
    print('레벨 비율 ' + '  '.join(f'L{k} {s * 100:.1f}%' for k, s in enumerate(share)))
    for vip in (False, True):
        print('VIP HOUR' if vip else '평소')
        for g in POCKET_CATCH:
            rows = by_level(g, vip)
            print(f'  {g:<8} ' + '  '.join(f'L{k} {v * 100:6.2f}%' for k, v in enumerate(rows))
                  + f'  | 같은 금액 {flat(g, vip) * 100:6.2f}%  (레인 L {flat(g, vip, "L") * 100:.2f}%)')
    print(f'FEVER 공 하나 기대 배수 {fever_ball():.4f} (FEVER 한 번 약 {FEVER_BALLS * fever_ball():.1f}배), 포켓 가치 {pocket_value():.4f}')
    lo, hi = STAKES[0], STAKES[-1]
    print(f'금액 바꾸기: {lo} → HOT {hi} {strategy([lo, lo, lo, hi]) * 100:.2f}%, '
          f'{lo} → 4·2부터 {hi} {strategy([lo, lo, hi, hi]) * 100:.2f}%, 50 → HOT {hi} {strategy([50, 50, 50, hi]) * 100:.2f}%')
    if '--mc' in sys.argv:
        n = int(sys.argv[sys.argv.index('--mc') + 1])
        for vip in (False, True):
            pays = monte_carlo(n, vip=vip)
            bands = [(0, 0.5), (0.5, 1), (1, 1.5), (1.5, 4), (4, 10), (10, 1e9)]
            dist = '  '.join(f'{lo:g}~{hi:g} {sum(lo <= p < hi for p in pays) / n * 100:.1f}%'.replace('~1e+09', '+')
                             for lo, hi in bands)
            print(f'MC {"VIP" if vip else "평소"} 가운데 {sum(pays) / n * 100:6.2f}%  {dist}')
