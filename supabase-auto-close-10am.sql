-- ============================================================
-- Auto-close work day ตาม "เวลาตัดรอบวันทำงาน" ในหน้า ตั้งค่าระบบ (Asia/Bangkok)
-- รันสคริปต์นี้ใน Supabase SQL Editor ของ project จริง (รันซ้ำได้ปลอดภัย)
-- (ต้องรันด้วยสิทธิ์ owner/admin — anon key ของแอปทำแบบนี้ไม่ได้)
--
-- เดิม cron ฝังเวลาไว้ตายตัว (เช่น '0 1 * * *' = 08:00) ไม่ได้อ่านค่าจากหน้า Setting
-- เปลี่ยนเวลาตัดรอบในแอปแล้วต้องมาแก้ SQL ด้วยมือทุกครั้ง ตอนนี้ job รันทุกนาที แล้วอ่าน
-- work_day_cutoff_minutes จาก wh_settings เอง → เปลี่ยนเวลาในหน้า Setting มีผลกับการ
-- ปิดวันอัตโนมัติทันที (ภายใน 1 นาที) ไม่ต้องแก้ SQL อีก
--
-- ทำสิ่งเดียวกับปุ่ม "ล้างวันใหม่" ใน Dashboard (handleReset ใน App.jsx):
--   1. archive แถวปัจจุบันของ wh_queue + wh_trucks ไปที่ wh_archive
--   2. ลบ wh_queue และ wh_trucks ให้ว่างสำหรับรอบใหม่
-- ปุ่ม "ล้างวันใหม่" ในแอปยังใช้งานได้ตามปกติ (เผื่อกดปิดงานนอกรอบ/เร็วกว่าเวลาตัดรอบ)
-- ============================================================

-- 1) เปิด extension pg_cron (ถ้ายังไม่เปิด)
--    ถ้ารันแล้ว error เรื่องสิทธิ์ ให้ไปเปิดผ่าน
--    Dashboard → Database → Extensions → ค้นหา "pg_cron" → Enable
create extension if not exists pg_cron;

-- 2) บันทึกว่าวันทำงานไหนปิดอัตโนมัติไปแล้ว — กัน job ที่รันทุกนาทีปิดวันเดิมซ้ำ
create table if not exists wh_auto_close_log (
  work_date date primary key,
  closed_at timestamptz not null default now()
);

-- 3) เวลาตัดรอบ (นาทีนับจากเที่ยงคืน) — อ่านจาก wh_settings ตัวเดียวกับที่หน้า Setting บันทึก
--    ไม่มีแถว/ค่าไม่ถูกต้อง → ใช้ 450 (07:30) ตรงกับ default ใน src/lib/settings.js
create or replace function wh_cutoff_minutes() returns int as $$
  select coalesce(
    (select (value #>> '{}')::int
       from wh_settings
      where id = 'work_day_cutoff_minutes'
        and jsonb_typeof(value) = 'number'
        and (value #>> '{}')::numeric between 0 and 1439),
    450);
$$ language sql stable security definer;

-- 4) วันทำงาน "ปัจจุบัน" ตามเวลา Bangkok — logic เดียวกับ cycleDateStr() ใน App.jsx
--    (ก่อนเวลาตัดรอบ = ยังเป็นวันทำงานของเมื่อวาน)
create or replace function wh_current_work_date() returns date as $$
  select ((now() at time zone 'Asia/Bangkok') - make_interval(mins => wh_cutoff_minutes()))::date;
$$ language sql stable security definer;

-- 5) ปิดวันทำงานที่ระบุ: archive + ล้างตาราง live
--    ถ้า wh_queue/wh_trucks ว่างทั้งคู่ (เช่น มีคนกด "ล้างวันใหม่" ไปแล้วก่อนเวลาตัดรอบ)
--    จะไม่เขียนทับ wh_archive — ไม่งั้น archive ที่กดปิดด้วยมือไว้จะถูกแทนด้วยข้อมูลว่าง
create or replace function close_work_day(p_archive_date date) returns void as $$
declare
  v_queue  jsonb;
  v_trucks jsonb;
begin
  select coalesce(jsonb_agg(data order by (data->>'seq')::numeric nulls last), '[]'::jsonb)
    into v_queue
    from wh_queue;

  select coalesce(jsonb_agg(data), '[]'::jsonb)
    into v_trucks
    from wh_trucks;

  if v_queue = '[]'::jsonb and v_trucks = '[]'::jsonb then
    return;
  end if;

  insert into wh_archive (archive_date, queue, trucks)
  values (p_archive_date, v_queue, v_trucks)
  on conflict (archive_date) do update
    set queue  = excluded.queue,
        trucks = excluded.trucks;

  delete from wh_queue;
  delete from wh_trucks;
end;
$$ language plpgsql security definer;

-- 6) ตัวที่ cron เรียกทุกนาที: ถ้าวันทำงานก่อนหน้าวันทำงานปัจจุบันยังไม่ถูกปิด → ปิดเลย
--    เลยเวลาตัดรอบมาแล้วกี่นาทีก็ตาม (เช่น DB หลับไปช่วงหนึ่ง) จะตามปิดให้ทันทีที่ job รันได้
--    advisory lock กันกรณีรอบก่อนยังทำไม่เสร็จแล้วรอบใหม่เริ่มซ้อน
create or replace function close_work_day_if_due() returns void as $$
declare
  v_due date := wh_current_work_date() - 1;
begin
  if not pg_try_advisory_xact_lock(hashtext('close_work_day_if_due')) then
    return;
  end if;
  if exists (select 1 from wh_auto_close_log where work_date = v_due) then
    return;
  end if;
  perform close_work_day(v_due);
  insert into wh_auto_close_log (work_date) values (v_due);
end;
$$ language plpgsql security definer;

-- 7) ตอนติดตั้งครั้งแรก: บันทึกว่าวันทำงานที่จบไปแล้วถูกปิดแล้ว ไม่งั้นรันสคริปต์นี้กลางวัน
--    job รอบแรกจะเห็นว่า "เมื่อวานยังไม่ปิด" แล้วล้างข้อมูลวันนี้ทิ้งทันที
insert into wh_auto_close_log (work_date)
values (wh_current_work_date() - 1)
on conflict (work_date) do nothing;

-- 8) ลบ job เวลาตายตัวตัวเก่า (ถ้ามี) + ฟังก์ชันเก่าแบบไม่มีพารามิเตอร์
do $$
declare j text;
begin
  foreach j in array array['close-work-day-10am', 'close-work-day-8am', 'close-work-day-0730'] loop
    if exists (select 1 from cron.job where jobname = j) then
      perform cron.unschedule(j);
    end if;
  end loop;
end $$;
drop function if exists close_work_day();

-- 9) ตั้ง job ให้รันทุกนาที (ฟังก์ชันตัดสินเองว่าถึงเวลาปิดหรือยัง)
--    รันซ้ำได้ปลอดภัย: ถ้ามี job ชื่อนี้อยู่แล้ว cron.schedule จะอัปเดตให้ ไม่สร้างซ้ำ
select cron.schedule(
  'close-work-day-auto',
  '* * * * *',
  $$ select close_work_day_if_due(); $$
);

-- ============================================================
-- ตรวจสอบหลังรัน
-- ============================================================
-- ดูว่าเหลือ job เดียว:
--   select jobname, schedule from cron.job;
-- ดูเวลาตัดรอบที่ DB ใช้อยู่ + วันทำงานปัจจุบัน:
--   select wh_cutoff_minutes(), wh_current_work_date();
-- ดูว่าวันไหนปิดอัตโนมัติไปแล้ว:
--   select * from wh_auto_close_log order by work_date desc limit 5;
-- ดู log การรันของ cron:
--   select * from cron.job_run_details order by start_time desc limit 5;
--
-- ⚠️ ห้ามรัน `select close_work_day(...);` ทดสอบตรง ๆ ในเวลาทำงานจริง
--   เพราะมันจะ archive + ลบ wh_queue/wh_trucks ทันทีเหมือนกดปุ่ม "ล้างวันใหม่" จริง
--
-- ยกเลิก automation (ถ้าต้องการ):
--   select cron.unschedule('close-work-day-auto');
-- ============================================================
