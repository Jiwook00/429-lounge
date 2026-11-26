-- 429 드롭 4·2·9 대기 (ADR-0019): 세 글자가 다 켜진 뒤 네 번째 포켓이 FEVER 확정.
-- 전엔 두 글자 뒤 세 번째 포켓이 확정이었다. 포켓 중 FEVER 비율이 37.9% → 30.2%로 줄어든 만큼 포켓이 잡을 확률을 올려
-- 환수율은 그대로 98 / 98.5 / 99%, VIP HOUR 105 / 105.5 / 106%. 수치의 원본은 scripts/drop_ev.py.

alter table public.players drop constraint players_plinko_letters_check;
alter table public.players add constraint players_plinko_letters_check check (plinko_letters between 0 and 3);

create or replace function public.plinko_catch(p_grade text, p_vip boolean)
returns numeric
language sql immutable as $$
  select case p_grade when 'perfect' then 0.0405 when 'good' then 0.0393 else 0.0381 end
       + case when p_vip then 0.0170 else 0 end
$$;

-- p_letters = 이 판 전의 글자 수(0~3, 3이면 대기), 반환의 letters = 이 판 뒤 글자 수
create or replace function public.plinko_resolve(p_amount bigint, p_lane int, p_grade text, p_vip boolean, p_letters int)
returns jsonb
language plpgsql volatile as $$
declare
  ball jsonb;
  total bigint;
  top numeric;
  pocket jsonb;
  fever_balls jsonb := '[]'::jsonb;
  syms constant text[] := array['429', '7', 'BAR', '200', '404'];
  is_fever boolean := false;
  ceiling boolean := false;
  letters int := p_letters;
  reels text[];
  refund bigint := 0;
  fb jsonb;
begin
  ball := plinko_launch(p_lane, false, plinko_catch(p_grade, p_vip), p_amount);
  total := (ball->>'payout')::bigint + coalesce((ball->'clone'->>'payout')::bigint, 0);
  top := greatest((ball->>'mult')::numeric, coalesce((ball->'clone'->>'mult')::numeric, 0));
  -- 분열 핀(10줄)이 포켓(6줄)보다 아래라 포켓은 한 판에 많아야 한 번
  if (ball->>'pocket')::boolean then
    ceiling := letters >= 3;
    is_fever := ceiling or random() < 0.125;
    if is_fever then
      letters := 0;
      reels := array['429', '429', '429'];
      for i in 1..40 loop
        fb := plinko_launch(floor(random() * 3)::int - 1, true, 0, p_amount);
        fever_balls := fever_balls || fb;
        total := total + (fb->>'payout')::bigint;
        top := greatest(top, (fb->>'mult')::numeric);
      end loop;
    else
      letters := letters + 1;
      -- 연출용 릴. 429 둘이면 리치. 셋 다 429는 FEVER일 때만
      reels := array[
        case when random() < 0.4 then '429' else syms[1 + floor(random() * 5)::int] end,
        '429',
        syms[2 + floor(random() * 4)::int]];
      if reels[1] <> '429' then reels[2] := syms[1 + floor(random() * 5)::int]; end if;
      refund := floor(p_amount * 0.2)::bigint;
      total := total + refund;
    end if;
    pocket := jsonb_build_object('reels', to_jsonb(reels), 'fever', is_fever, 'refund', refund, 'ceiling', ceiling);
  end if;
  return jsonb_build_object('ball', ball, 'pocket', pocket, 'fever_balls', fever_balls,
    'payout', total, 'top_mult', top, 'fever', is_fever, 'letters', letters, 'vip', p_vip);
end $$;

revoke execute on function public.plinko_catch(text, boolean)                     from public, anon, authenticated;
revoke execute on function public.plinko_resolve(bigint, int, text, boolean, int) from public, anon, authenticated;
