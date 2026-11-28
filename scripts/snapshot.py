#!/usr/bin/env python3
"""운영 DB 스냅샷 (읽기 전용).

`supabase db dump --linked --data-only`(pg_dump, SELECT만)로 public 스키마를 받아
테이블별 CSV와 SCHEMA.md, summary.md를 <out>/YYYY-MM-DD/ 에 만든다.
키·비밀번호는 다루지 않는다 (CLI 로그인 세션만 쓴다). 쓰기는 하지 않는다.

  python3 scripts/snapshot.py --workdir '<체크아웃 경로>'
  python3 scripts/snapshot.py --owner-name '<owner nickname>'
  python3 scripts/snapshot.py --dump 이미받은.sql      # DB 접속 없이 다시 만들기

--workdir 는 supabase 가 link 된 체크아웃(supabase/.temp 가 있는 곳)이다. 기본은 현재 디렉터리.
--owner-name 또는 LOUNGE_OWNER_NAME으로 운영자를 지정한다. 둘 다 없으면 운영자 구분을 생략한다.
--out 기본값은 <workdir>/local/data (local/ 은 gitignore).
"""
import argparse, csv, collections, datetime as dt, os, subprocess, sys, tempfile
from pathlib import Path
from zoneinfo import ZoneInfo

KST = ZoneInfo("Asia/Seoul")
# 지갑·경제 + 게임 로그 (rooms, pixel_buckets, client_policy 등 운영 부속 테이블은 제외)
TABLES = [
    "players", "token_claims", "golden_grants", "lucky_tickets", "lounge_events", "pixel_board",
    "slot_spins", "plinko_drops", "bj_rounds", "bj_seats", "roulette_rounds", "roulette_bets",
    "minority_questions", "minority_rounds", "minority_picks", "oddeven_rounds", "oddeven_bets",
]
# 운영 DB에 마이그레이션이 아직 안 올라갔을 수 있는 테이블: 없으면 건너뛴다
OPTIONAL_TABLES = ["player_daily_seen"]


def dump_db(workdir: Path, dest: Path):
    r = subprocess.run(
        ["supabase", "db", "dump", "--linked", "--data-only", "--use-copy", "-s", "public", "-f", str(dest)],
        cwd=workdir, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("supabase db dump 실패 (link 된 체크아웃에서 실행하세요):\n" + r.stderr[-800:])


def unescape(s: str) -> str:
    if "\\" not in s:
        return s
    out, i = [], 0
    m = {"t": "\t", "n": "\n", "r": "\r", "b": "\b", "f": "\f", "v": "\v", "\\": "\\"}
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            out.append(m.get(s[i + 1], s[i + 1])); i += 2
        else:
            out.append(c); i += 1
    return "".join(out)


def parse_copy(path: Path):
    """COPY ... FROM stdin 블록 → {table: (columns, rows)}. NULL 은 None."""
    tables, cur = {}, None
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if cur is None:
                if line.startswith("COPY "):
                    head = line[len("COPY "):line.index(" FROM stdin")]
                    name = head[:head.index(" (")].split(".")[-1].strip('"')
                    cols = [c.strip().strip('"') for c in head[head.index("(") + 1:head.rindex(")")].split(",")]
                    cur = (name, cols, [])
            elif line == "\\.":
                tables[cur[0]] = (cur[1], cur[2]); cur = None
            else:
                cur[2].append([None if v == "\\N" else unescape(v) for v in line.split("\t")])
    return tables


def ts(s):  # timestamptz 문자열 → KST datetime
    if s is None:
        return None
    s = s.replace(" ", "T")
    if s.endswith("+00"):
        s += ":00"
    return dt.datetime.fromisoformat(s).astimezone(KST)


def write_csv(path: Path, cols, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(cols)
        w.writerows(["" if v is None else v for v in r] for r in rows)


def pct(a, b):
    return f"{a / b * 100:.1f}%" if b else "-"


def table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def build_plays(T):
    """게임 한 판(플레이어 단위) 목록. 서버 game_results 뷰와 같은 net 규칙 (황금 칩은 건 칩 0)."""
    def D(name):
        cols, rows = T[name]
        return [dict(zip(cols, r)) for r in rows]
    plays = []

    def add(game, pid, amount, golden, payout, at, rnd=None):
        plays.append(dict(game=game, pid=pid, wager=0 if golden else amount, payout=payout, golden=golden, at=ts(at), round=rnd))

    for r in D("slot_spins"):
        add("slot", r["player_id"], int(r["amount"]), r["golden"] == "t", int(r["payout"]), r["created_at"])
    for r in D("plinko_drops"):
        add("plinko", r["player_id"], int(r["amount"]), r["golden"] == "t", int(r["payout"]), r["created_at"])
    for r in D("oddeven_bets"):
        if r["payout"] is not None:
            add("oddeven", r["player_id"], int(r["amount"]), r.get("golden") == "t", int(r["payout"]), r["created_at"], r["round_id"])
    for r in D("minority_picks"):
        if r["payout"] is not None:
            add("minority", r["player_id"], int(r["amount"]), False, int(r["payout"]), r["created_at"], r["round_id"])
    for r in D("bj_seats"):
        if r["player_id"] and r["payout"] is not None:
            mult = 2 if r["doubled"] == "t" else 1
            add("blackjack", r["player_id"], int(r["amount"]) * mult, r["golden"] == "t", int(r["payout"]), r["created_at"], r["round_id"])
    for r in D("roulette_bets"):
        if r["payout"] is not None:
            add("roulette", r["player_id"], int(r["amount"]), r["golden"] == "t", int(r["payout"]), r["created_at"], r["round_id"])
    return plays


GAME_ORDER = ["slot", "plinko", "blackjack", "roulette", "minority", "oddeven"]
GAME_KO = {"slot": "429 슬롯", "plinko": "429 드롭", "blackjack": "블랙잭", "roulette": "미니 룰렛", "minority": "소수결", "oddeven": "구슬 홀짝(은퇴)"}


def game_stats(plays):
    st = {}
    for g in GAME_ORDER:
        P = [p for p in plays if p["game"] == g]
        if not P:
            continue
        # 룰렛은 한 회차에 베팅 여러 개 → (회차, 회원)을 한 판으로 센다
        n = len({(p["round"], p["pid"]) for p in P}) if g == "roulette" else len(P)
        norm = [p for p in P if not p["golden"]]
        gold = [p for p in P if p["golden"]]
        st[g] = dict(plays=n, members=len({p["pid"] for p in P}),
                     wager=sum(p["wager"] for p in norm), payout=sum(p["payout"] for p in norm),
                     golden_n=len(gold), golden_pay=sum(p["payout"] for p in gold))
    return st


def stat_rows(st):
    rows = []
    for g in GAME_ORDER:
        if g in st:
            s = st[g]
            rows.append([GAME_KO[g], f"{s['plays']:,}", s["members"], f"{s['wager']:,}", f"{s['payout']:,}",
                         f"{s['payout'] - s['wager']:+,}", pct(s["payout"], s["wager"]), s["golden_n"], f"{s['golden_pay']:,}"])
    if st:
        w = sum(s["wager"] for s in st.values()); p = sum(s["payout"] for s in st.values())
        rows.append(["**합계**", f"{sum(s['plays'] for s in st.values()):,}", "", f"{w:,}", f"{p:,}", f"{p - w:+,}", pct(p, w),
                     sum(s["golden_n"] for s in st.values()), f"{sum(s['golden_pay'] for s in st.values()):,}"])
    return rows


STAT_HEAD = ["게임", "판 수", "회원 수", "베팅(일반 칩)", "지급(일반 칩)", "일반 칩 손익", "실측 RTP", "황금 칩 판", "황금 칩 지급"]


def make_summary(T, day, plays, owner_ids, names):
    show_owner = owner_ids is not None
    owner_ids = owner_ids or set()
    P_all = plays
    P_ex = [p for p in plays if p["pid"] not in owner_ids]
    pcols, prows = T["players"]
    players = [dict(zip(pcols, r)) for r in prows]
    named = [p for p in players if p["named"] == "t"]
    members_ex = [p for p in players if p["id"] not in owner_ids]
    L = [f"# 429 Lounge 스냅샷 요약 · {day}", "",
         f"생성 {dt.datetime.now(KST):%Y-%m-%d %H:%M} KST. 시각은 모두 KST. 운영 DB 읽기 전용 덤프 기준이다.", ""]
    member_counts = f"- 가입(익명 계정) {len(players)}명, 닉네임 정한 회원 {len(named)}명"
    game_counts = f"- 게임을 한 번이라도 한 회원 {len({p['pid'] for p in P_all})}명"
    if show_owner:
        named_ex = sum(p["id"] not in owner_ids for p in named)
        member_counts += f" (운영자 제외: 계정 {len(members_ex)}명, 닉네임 {named_ex}명)"
        game_counts += f" (운영자 제외 {len({p['pid'] for p in P_ex})}명)"
    L += ["## 회원", "", member_counts, game_counts, ""]
    game_sections = ((" (운영자 포함)", P_all), (" (운영자 제외)", P_ex)) if show_owner else (("", P_all),)
    for title, P in game_sections:
        L += [f"## 게임별{title}", "", table(STAT_HEAD, stat_rows(game_stats(P))), ""]
    L += ["RTP = 일반 칩 지급 ÷ 일반 칩 베팅. 황금 칩 판은 건 칩 0으로 치고 지급만 손익에 더한다(서버 `game_results` 뷰와 같은 규칙). 블랙잭 더블은 베팅 2배. 룰렛은 한 회차에 베팅이 여러 개라 (회차, 회원) 하나를 한 판으로 센다. 정산 전(`payout` null) 판은 뺀다.", ""]

    # 일 활성 회원
    act = collections.defaultdict(lambda: collections.defaultdict(set))
    for p in plays:
        act[p["at"].date()]["game"].add(p["pid"])
    for tname, pidcol, tscol in (("token_claims", "player_id", "updated_at"), ("lucky_tickets", "player_id", "claimed_at"),
                                 ("pixel_board", "player_id", "painted_at")):
        cols, rows = T[tname]
        i, j = cols.index(pidcol), cols.index(tscol)
        for r in rows:
            act[ts(r[j]).date()]["any"].add(r[i])
    headers = ["날짜", "게임한 회원", "전체 활동 회원", "총 판 수"]
    if show_owner:
        headers.insert(2, "(운영자 제외)")
        headers.insert(4, "(운영자 제외)")
    rows = []
    for d in sorted(act):
        g = act[d]["game"]
        a = act[d]["any"] | g
        row = [d.isoformat(), len(g), len(a), sum(1 for p in P_all if p["at"].date() == d)]
        if show_owner:
            row.insert(2, len(g - owner_ids))
            row.insert(4, len(a - owner_ids))
        rows.append(row)
    L += ["## 일 활성 회원 (KST 날짜)", "", table(headers, rows), "",
          "전체 활동 = 게임 + 토큰 환전(`token_claims.updated_at`) + 럭키 드로우 + 벽화. 토큰 환전은 앱이 켜져 있으면 계속 갱신되므로 앱 사용의 대용치.", ""]

    # 일별 게임 판 수
    days = sorted({p["at"].date() for p in plays})
    rows = [[d.isoformat()] + [sum(1 for p in plays if p["game"] == g and p["at"].date() == d) for g in GAME_ORDER] for d in days]
    L += ["## 일별 판 수 (룰렛은 베팅 행 기준)", "", table(["날짜"] + [GAME_KO[g] for g in GAME_ORDER], rows), ""]

    # 회원별 순손익
    by = collections.defaultdict(lambda: collections.defaultdict(int))
    for p in plays:
        b = by[p["pid"]]
        b["plays"] += 1; b["wager"] += p["wager"]; b["payout"] += p["payout"]
        b[p["game"]] += p["payout"] - p["wager"]
        if not p["golden"]:
            b["nw"] += p["wager"]; b["np"] += p["payout"]
    rows = []
    for pid, b in sorted(by.items(), key=lambda kv: -(kv[1]["payout"] - kv[1]["wager"])):
        rows.append([names.get(pid, "?") + (" ★" if pid in owner_ids else ""), b["plays"], f"{b['nw']:,}",
                     f"{b['payout'] - b['wager']:+,}", pct(b["np"], b["nw"])] + [f"{b[g]:+,}" if g in b else "-" for g in GAME_ORDER[:5]])
    L += ["## 회원별 순손익", "",
          table(["회원", "판 수", "일반 칩 베팅", "순손익(황금 포함)", "일반 칩 RTP"] + [GAME_KO[g] for g in GAME_ORDER[:5]], rows),
          "", ("★ = 운영자. " if show_owner else "") + "순손익은 게임에서 딴·잃은 칩만이다(토큰 환전·오늘의 칩·럭키 드로우 제외). 판 수는 베팅 행 기준.", ""]

    # 수입
    cc, cr = T["token_claims"]
    lc, lr = T["lucky_tickets"]
    wallet = f"- 현재 지갑 합계 {sum(int(p['chips']) for p in players):,}칩"
    if show_owner:
        wallet += f" (운영자 제외 {sum(int(p['chips']) for p in members_ex):,}칩)"
    L += ["## 칩 수입 (게임 밖)", "",
          f"- 토큰 환전 누적 {sum(int(r[cc.index('chips')]) for r in cr):,}칩 ({len(cr)}건 회원·일)",
          f"- 럭키 드로우 {len(lr)}장, {sum(int(r[lc.index('amount')]) for r in lr):,}칩",
          f"- 황금 칩 지급 {len(T['golden_grants'][1])}건 (`golden_grants`)",
          wallet, ""]
    return "\n".join(L)


SCHEMA_MD = """# 스냅샷 스키마 · 칩 규칙

운영 DB(Supabase Postgres, 서울) `public` 스키마를 읽기 전용으로 받은 CSV다. 첫 줄은 헤더, NULL은 빈 칸.
**시각은 UTC 원본**(`2026-11-27 08:30:39+00`)이다. KST는 +9시간. `date` 컬럼(`day`, `week`)은 클라이언트/KST 기준 날짜. summary.md는 KST로 환산해 집계한다.
출처 마이그레이션은 `supabase/migrations/`, 규칙 원본은 `docs/chip-economy.md`. 닉네임은 원본 값이다.
단위: 칩은 모두 정수. `amount`·`payout`은 칩, 지급(`payout`)은 건 칩을 포함한 총 지급액.

## 공통 규칙

- **손익(net)** = `payout − 건 칩`. 황금 칩(`golden`)은 공짜라 건 칩 0 → net = payout. 서버 `game_results` 뷰와 같은 규칙이고 이번 주 큰손 기준이다 (ADR-0012)
- **실측 RTP** = 일반 칩 지급 ÷ 일반 칩 베팅. 황금 칩 판은 제외
- 황금 칩 = 100칩 공짜 베팅 1개. 이기면 200칩(게임별 상이), 지면 잃는 것 없음. 429 리밋 리셋 시각에 소멸. 슬롯 VIP HOUR 등은 황금 칩 유효 시간
- `payout`이 NULL = 아직 정산 전
- 시작 지갑 1,000칩. 수입: 토큰 환전(fresh 토큰 1,000개 = 1칩), 오늘의 칩(+100, 잔액 100 미만이면 +300), 황금 칩(429 걸릴 때), 럭키 드로우(하루 3장, 50~429칩)
- 칩은 현금·선물·송금 불가
- 칩 단위: 슬롯 10·50·100·200 / 드롭 10·50·100·200 / 블랙잭 10·30·50·100 / 룰렛 10·50·100(판당 상한 없음) / 소수결 판마다 고정 참가비(`minority_rounds.stake`)

## 게임별 규칙 요약

| 게임 | 규칙 | 설계 환수율 |
|---|---|---|
| 429 슬롯 | 릴 3개. 429×3=×429, 7=×50, BAR=×20, 벨=×10, 체리3=×5, 체리2=×3 | 평소 101.9% / VIP HOUR 108.0% |
| 429 드롭 | 12줄 플링코, 13칸 ×16 5 2 1.4 .8 .5 .3 .5 .8 1.4 2 5 16. 포켓(잡힘) → 1/8로 FEVER(공 40개 ×1.5). 글자 4·2·9 = 보드 레벨(v0.15.0, 11-27 이후) | 레벨0 93.8% … HOT 111.7%, 같은 금액 98.6% |
| 블랙잭 | 딜러전, 무한 덱, 블랙잭 ×2.75(황금 ×2.5), 승 ×2, 더블 가능 | 최적 전략 약 98.8% |
| 미니 룰렛 | 0~12. 숫자 ×12, 색·홀짝·구간 ×2, 0이면 전원 무효(건 칩 환불) | 100% |
| 소수결 | 평일 8·11·14시. 적은 쪽이 승, 진 쪽 칩을 나눔. 3명 미만·동점은 무효 환불 | 100% (하우스 0) |
| 구슬 홀짝 | 은퇴(v0.10.0). 과거 기록만 | 100% |

슬롯·블랙잭 배당은 11-24 20:25 KST(v0.13.1)에 바뀌었다. 그 전후를 나눠 볼 때는 `lounge_events.csv` 시각을 쓴다.

## 테이블

### players
`id` uuid(익명 계정) · `name` 닉네임(미지정 "손님 XXXXXX") · `chips` 현재 지갑 · `created_at` · `golden_chips` 보유 황금 칩 · `golden_until` 황금 칩 만료 · `last_daily` 마지막 오늘의 칩 날짜 · `named` 닉네임 지정 여부 · `last_seen_at` · `app_version` 마지막 접속 앱 버전 · `plinko_letters` 드롭 보드 글자 수(0~2){owner_column}

### player_daily_seen (운영 DB에 있을 때만)
`player_id` · `day` KST 날짜 · `first_seen_at` · `last_seen_at` · `app_version` 그날 마지막 버전 · `seen_count` touch_seen 횟수(약 2분 단위)

### token_claims
회원·날짜별 토큰 환전. `day` 클라이언트 로컬 날짜 · `fresh_tokens` 그 날 보낸 fresh 토큰 · `chips` 지금까지 지급한 칩(토큰 1,000개 = 1칩) · `updated_at`

### golden_grants
429 리밋 하나당 황금 칩 1회 지급. `resets_at` 리셋 시각 · `limit_type` five_hour/seven_day 등 · `amount` 지급 개수

### lucky_tickets
럭키 드로우(v0.12.0, 11-23~). `day` KST 날짜 · `number` 그날 1~3번째 장 · `amount` 50/100/200/300/429 · `claimed_at`. 확률 100칩 36% · 200칩 27% · 50칩 15% · 300칩 12% · 429칩 10%. 게임 손익 집계에서 제외

### lounge_events
전광판 이벤트. `kind` jackpot/bigwin · `game` · `name` 그 순간 닉네임 · `amount` 지급액

### pixel_board
라운지 벽화(v0.13.0~). 주(KST 월요일)마다 32×32, 색 8개. `week`,`x`,`y`,`color`,`player_id`,`painted_at`. 칩과 무관

### slot_spins
스핀 1회 = 1행. `amount` 건 칩 · `golden` · `reels` 최종 릴 · `initial_reels` 500 리스핀 전 · `glitched` 리스핀된 릴 번호 · `multiplier` · `payout` · `vip` VIP HOUR 중이었는지

### plinko_drops
공 1개 = 1행(v0.14.0, 11-26 23:17~). `amount` · `golden` · `lane` -1/0/1 · `power` 0~1000 · `grade` none/good/perfect · `pocket` 포켓에 잡혔는지 · `fever` FEVER 발동 · `top_mult` 그 공(분열·FEVER 포함) 최대 배수 · `payout` 총 지급 · `result` jsonb(경로, v0.15.0 이후 `level` 0~3, 3 = HOT) · `vip` VIP HOUR · `letters` 이 판 뒤 글자 수(이전 판은 NULL)

### bj_rounds / bj_seats
블랙잭 한 판 = `bj_rounds` 1행 + 자리별 `bj_seats` 최대 4행. `bj_seats.player_id`가 NULL이면 AI 봇(칩 없음, 집계 제외). `amount` 첫 베팅(더블이면 실제 건 칩은 ×2) · `golden` · `doubled` · `cards` · `state` · `result` win/lose/push/blackjack · `payout`

### roulette_rounds / roulette_bets
한 회차 `roulette_rounds`(`result` 0~12) + 베팅 여러 개 `roulette_bets`. `spot` n1~n12/red/black/odd/even/low/high · `amount` · `golden`(황금 칩은 amount = 100×개수, 바깥 칸만) · `payout`. 0이 나오면 모든 베팅 payout = amount(무효)

### minority_questions / minority_rounds / minority_picks
질문 목록 / 판(`stake` 참가비, `a_count`·`b_count`, `winner` 0/1, NULL = 무효) / 회원 선택(`choice`, `amount`, `payout` 0 = 짐 · amount = 무효 환불)

### oddeven_rounds / oddeven_bets
은퇴한 구슬 홀짝(v0.10.0에서 룰렛으로 대체). 기록만 남음
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workdir", default=".", help="supabase 가 link 된 체크아웃")
    ap.add_argument("--owner-name", default=os.environ.get("LOUNGE_OWNER_NAME"),
                    help="운영자 닉네임 (기본 LOUNGE_OWNER_NAME)")
    ap.add_argument("--out", help="기본 <workdir>/local/data")
    ap.add_argument("--dump", help="이미 받은 data-only COPY 덤프 (DB 접속 생략)")
    ap.add_argument("--date", help="폴더 날짜(기본: 오늘 KST)")
    a = ap.parse_args()
    workdir = Path(a.workdir).expanduser().resolve()
    out_root = Path(a.out).expanduser() if a.out else workdir / "local" / "data"
    day = a.date or dt.datetime.now(KST).strftime("%Y-%m-%d")

    with tempfile.TemporaryDirectory() as tmp:
        dump = Path(a.dump).expanduser() if a.dump else Path(tmp) / "dump.sql"
        if not a.dump:
            dump_db(workdir, dump)
        T = parse_copy(dump)
    missing = [t for t in TABLES if t not in T]
    if missing:
        sys.exit(f"덤프에 없는 테이블: {missing}")

    optional = [t for t in OPTIONAL_TABLES if t in T]
    out = out_root / day
    out.mkdir(parents=True, exist_ok=True)
    pcols, prows = T["players"]
    ni, ii = pcols.index("name"), pcols.index("id")
    owner_ids = None
    owner_column = ""
    if a.owner_name:
        owner_ids = {r[ii] for r in prows if r[ni] == a.owner_name}
        T["players"] = (pcols + ["is_owner"], [r + ["t" if r[ii] in owner_ids else "f"] for r in prows])
        owner_column = " · **`is_owner`**(추가) 지정한 운영자 닉네임과 일치하면 true"
    names = {r[ii]: r[ni] for r in prows}

    for t in TABLES + optional:
        cols, rows = T[t]
        write_csv(out / f"{t}.csv", cols, rows)
    (out / "SCHEMA.md").write_text(SCHEMA_MD.replace("{owner_column}", owner_column), encoding="utf-8")
    plays = build_plays(T)
    (out / "summary.md").write_text(make_summary(T, day, plays, owner_ids, names), encoding="utf-8")
    print(f"저장: {out}")
    owner_count = f" (운영자 {len(owner_ids)}명)" if owner_ids is not None else ""
    print(f"회원 {len(prows)}명{owner_count}")
    for g, s in game_stats(plays).items():
        print(f"  {GAME_KO[g]}: {s['plays']:,}판 / {s['members']}명")


if __name__ == "__main__":
    main()
