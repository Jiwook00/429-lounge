"""인디언 포커 동시성 확인 (ADR-0023). 로컬 DB 전용, 만든 계정·테이블은 끝에 지운다.
  python3 supabase/tests/indian_poker_race.py
각 연결이 따로 커밋되는 경합(동시 이탈, 잠금 뒤에 줄 선 늦은 행동, 중복 tick·재시도, 마지막 사람 away와 입장)을 본다.
"""
import concurrent.futures
import os
import subprocess
import time
import uuid

os.environ.setdefault("PGPASSWORD", "postgres")
BASE = ["psql", "-X", "-h", "127.0.0.1", "-p", "54322", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-Atq"]
fails = []


def sql(q, check=True):
    p = subprocess.run(BASE, input=q, text=True, capture_output=True)
    if p.returncode:
        if check:
            raise RuntimeError(p.stderr)
        return "ERR " + p.stderr.strip().splitlines()[0]
    return p.stdout.strip()


def rpc(u, call):
    return f"set role authenticated; set request.jwt.claim.sub = '{u}'; select {call};"


def run(calls, check=True):
    with concurrent.futures.ThreadPoolExecutor() as ex:
        return list(ex.map(lambda q: sql(q, check), calls))


def chk(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""))
    if not ok:
        fails.append(name)


users = [str(uuid.uuid4()) for _ in range(5)]
a, b, c, d, e = users
ids = ",".join(f"'{u}'" for u in users)
tables = []


def hand(t):
    return sql(f"select id, turn_no, phase, hand_no from ip_hands where table_id = {t} order by hand_no desc limit 1;").split("|")


def pots(t):
    return sql(f"select sum(put) || '|' || coalesce(sum(payout), -1) from ip_hand_seats where hand_id = (select max(id) from ip_hands where table_id = {t});")


try:
    sql(f"insert into auth.users(id, aud, role) select id::uuid, 'authenticated', 'authenticated' from unnest(array[{ids}]) id;"
        f"insert into players(id, name, named, chips) select id::uuid, left(id, 8), true, 1000 from unnest(array[{ids}]) id"
        f" on conflict (id) do update set named = true, chips = 1000;")
    total = lambda: int(sql(f"select sum(chips) from players where id in ({ids});"))

    # 1) 사람 셋: 동시 이탈 → 남은 한 명에게 한 번만
    t = int(sql(rpc(a, "ip_create(2)->'table'->>'id'")))
    tables.append(t)
    for u in (b, c):
        sql(rpc(u, f"ip_join({t})->'me'"))
    sql(f"select ip_apply(id, 1::smallint, 'fold', null, clock_timestamp()) from ip_hands where table_id = {t};"
        f"select ip_start_hand({t}, clock_timestamp());")
    run([rpc(a, f"ip_leave({t})->'hand'->>'phase'"), rpc(c, f"ip_leave({t})->'hand'->>'phase'")])
    put, paid = pots(t).split("|")
    chk("동시 이탈: 판돈 = 지급, 한 번만", put == paid and hand(t)[2] == "done", f"{put}/{paid}")

    # 2) 잠금 뒤에 줄 선 행동: 마감 전에 도착해도 잠금을 잡은 시각(clock_timestamp)이 마감 뒤면 받지 않는다
    sql(f"select ip_start_hand({t}, clock_timestamp());")
    sql(rpc(a, f"ip_join({t})->'me'"))
    sql(f"update ip_hands set turn_seat = 2, turn_started_at = clock_timestamp() - interval '9s', turn_deadline = clock_timestamp() + interval '2s'"
        f" where id = (select max(id) from ip_hands where table_id = {t});")
    h, n, _, _ = hand(t)
    with concurrent.futures.ThreadPoolExecutor() as ex:
        ex.submit(sql, f"begin; select pg_advisory_xact_lock(hashtext('ip:' || {t})); select pg_sleep(3); commit;")
        time.sleep(0.35)
        action = ex.submit(sql, rpc(b, f"ip_action({t}, {h}, {n}, 'bet', 20)->>'rejected'"), False)
        time.sleep(2)
        tick = ex.submit(sql, rpc(a, f"ip_tick({t})->'hand'->>'phase'"), False)
        r = action.result()
        tick.result()
    last = sql(f"select last_action from ip_hand_seats where hand_id = {h} and seat = 2;")
    chk("마감 뒤 잠금을 잡은 행동은 거절, 시간 초과 폴드", r == "stale_turn" and last == "timeout", f"{r} {last}")

    # 3) 중복 tick·같은 요청 재시도: 칩이 다시 빠지거나 지급되지 않는다
    before = total()
    run([rpc(u, f"ip_tick({t})->'hand'->>'phase'") for u in (a, b)])
    r = sql(rpc(b, f"ip_action({t}, {h}, {n}, 'bet', 20)->>'rejected'"))
    chk("중복 tick·재시도 뒤 칩 그대로", total() == before and r in ("stale_turn", "not_your_turn"), r)

    # 4) 마지막 사람의 두 번째 연속 시간 초과 + 동시 입장·tick: 입장은 거절, 테이블 닫힘, 다음 판 없음
    t = int(sql(rpc(d, "ip_create(1)->'table'->>'id'")))
    tables.append(t)
    for _ in range(2):
        sql(f"select ip_advance({t}, turn_deadline) from ip_hands where table_id = {t} and phase = 'betting' order by hand_no desc limit 1;")
        sql(f"select ip_advance({t}, turn_deadline) from ip_hands where table_id = {t} and phase = 'betting' order by hand_no desc limit 1;")
        if hand(t)[2] == "done" and sql(f"select status from ip_tables where id = {t};") == "open":
            sql(f"select ip_advance({t}, next_at) from ip_hands where table_id = {t} order by hand_no desc limit 1;")
            if hand(t)[3] == "2":
                # 2판: 마감을 지금 직전으로 → 다음 호출들이 경합하며 만료를 정산
                sql(f"update ip_hands set turn_seat = 1, turn_deadline = clock_timestamp() + interval '0.3s'"
                    f" where id = (select max(id) from ip_hands where table_id = {t});")
                break
    time.sleep(0.4)
    res = run([rpc(e, f"ip_join({t})->'me'->>'member'"), rpc(d, f"ip_tick({t})->'table'->>'status'"),
               rpc(e, f"ip_join({t})->'me'->>'member'")], False)
    status = sql(f"select status from ip_tables where id = {t};")
    hn = hand(t)[3]
    members = sql(f"select count(*) from ip_members where table_id = {t} and left_at is null;")
    joins_ok = [x for x in (res[0], res[2]) if not x.startswith("ERR")]
    chk("마지막 사람 away → 닫힘, 동시 입장 거절", status == "closed" and members == "0" and not joins_ok, f"{res} {status}")
    sql(f"select ip_advance({t}, clock_timestamp() + interval '1 minute');")
    chk("닫힌 테이블에 3판 없음", hand(t)[3] == hn == "2", hn)
finally:
    for t in tables:
        sql(f"delete from ip_tables where id = {t};", False)
    sql(f"delete from auth.users where id in ({ids});", False)

print("failures", len(fails))
raise SystemExit(1 if fails else 0)
