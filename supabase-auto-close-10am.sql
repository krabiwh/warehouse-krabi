-- ============================================================
-- Auto-close work day ที่ 08:00 น. (Asia/Bangkok)
-- รันสคริปต์นี้ครั้งเดียวใน Supabase SQL Editor ของ project จริง
-- (ต้องรันด้วยสิทธิ์ owner/admin — anon key ของแอปทำแบบนี้ไม่ได้)
--
-- ⚠️ ถ้าเคยรันไฟล์นี้เวอร์ชันเก่าไปแล้ว (ก่อนแก้ archive_date -1 วันด้านล่าง) ต้อง
-- รัน "create or replace function close_work_day()" บล็อกนี้ซ้ำอีกครั้งเพื่ออัปเดต
-- ฟังก์ชันที่ผูกกับ cron job อยู่แล้ว — ของเดิม archive_date เพี้ยนไปข้างหน้า 1 วันทุกครั้ง
-- ที่ job รัน (เช่น ข้อมูลของวันที่ 17 ถูกเก็บเป็น archive_date = วันที่ 18 แทน) แถวเก่าที่เพี้ยน
-- ไปแล้วต้องแก้ archive_date ของแถวนั้นด้วยมือแยกต่างหาก สคริปต์นี้แก้แค่ตัว function ไปข้างหน้า
--
-- ทำสิ่งเดียวกับปุ่ม "ล้างวันใหม่" ใน Dashboard (handleReset ใน App.jsx):
--   1. archive แถวปัจจุบันของ wh_queue + wh_trucks ไปที่ wh_archive
--   2. ลบ wh_queue และ wh_trucks ให้ว่างสำหรับรอบใหม่
-- ปุ่ม "ล้างวันใหม่" ในแอปยังใช้งานได้ตามปกติ (เผื่อกดปิดงานนอกรอบ/เร็วกว่า 08:00)
-- ============================================================

-- 1) เปิด extension pg_cron (ถ้ายังไม่เปิด)
--    ถ้ารันแล้ว error เรื่องสิทธิ์ ให้ไปเปิดผ่าน
--    Dashboard → Database → Extensions → ค้นหา "pg_cron" → Enable
create extension if not exists pg_cron;

-- 2) ฟังก์ชันปิดงาน — คำนวณ archive_date = "เมื่อวาน" ของเวลา Bangkok เสมอ
--    งานนี้รันตอนเวลาตัดรอบ (ดูข้อ 3 ด้านล่าง) พอดี ซึ่งตรงกับจุดเริ่มต้นของวันทำงานใหม่ตาม
--    cycleDateStr() ใน App.jsx (hour < cutoffHour ถึงจะนับเป็นเมื่อวาน แต่ตรงนี้ hour ==
--    cutoffHour พอดีทุกครั้ง ไม่เคย < ) ข้อมูลที่กำลังจะ archive ตอนนี้คือของวันทำงานที่เพิ่งปิดไป
--    (เมื่อวาน) เสมอ จึงต้องลบ 1 วันตรง ๆ ไม่ใช่ port logic ก่อน/หลัง cutoff แบบ cycleDateStr มาใช้ตรงนี้
--    (เดิมจุดนี้ไม่ลบวัน ทำให้ archive_date เพี้ยนไปข้างหน้า 1 วันทุกครั้งที่ job รัน)
create or replace function close_work_day() returns void as $$
declare
  v_archive_date date := (now() at time zone 'Asia/Bangkok')::date - 1;
  v_queue        jsonb;
  v_trucks       jsonb;
begin
  select coalesce(jsonb_agg(data order by (data->>'seq')::numeric nulls last), '[]'::jsonb)
    into v_queue
    from wh_queue;

  select coalesce(jsonb_agg(data), '[]'::jsonb)
    into v_trucks
    from wh_trucks;

  insert into wh_archive (archive_date, queue, trucks)
  values (v_archive_date, v_queue, v_trucks)
  on conflict (archive_date) do update
    set queue  = excluded.queue,
        trucks = excluded.trucks;

  delete from wh_queue;
  delete from wh_trucks;
end;
$$ language plpgsql security definer;

-- 3) ตั้งเวลา — pg_cron ของ Supabase รันตาม UTC
--    01:00 UTC = 08:00 Asia/Bangkok (UTC+7, ไทยไม่มี DST จึงไม่ขยับ)
--    ⚠️ เวลานี้ต้องตรงกับ workDayCutoffHour ใน master setting เสมอ — ถ้าเปลี่ยนเวลาตัดรอบ
--    ในหน้า "ตั้งค่าระบบ" ต้องมาแก้ schedule ตรงนี้ด้วยมือทุกครั้ง (job นี้ไม่ได้อ่านค่าจาก DB)
--    รันซ้ำได้ปลอดภัย: ถ้ามี job ชื่อนี้อยู่แล้ว cron.schedule จะอัปเดตให้ ไม่สร้างซ้ำ
select cron.schedule(
  'close-work-day-8am',
  '0 1 * * *',
  $$ select close_work_day(); $$
);

-- ถ้าเคยรัน job เดิมชื่อ 'close-work-day-10am' ไว้ก่อนหน้านี้ ต้อง unschedule ตัวเก่าด้วย
-- ไม่งั้นจะมี job ปิดวันซ้ำสองอันทำงานคนละเวลากัน:
--   select cron.unschedule('close-work-day-10am');

-- ============================================================
-- ตรวจสอบหลังรัน
-- ============================================================
-- ดูว่า job ถูกตั้งไว้จริง:
--   select * from cron.job;
-- ดู log การรันแต่ละครั้ง (เช็คตอนเช้าวันถัดไปหลัง 08:00 ว่า status = 'succeeded'):
--   select * from cron.job_run_details order by start_time desc limit 5;
--
-- ⚠️ ห้ามรัน `select close_work_day();` ทดสอบตรง ๆ ในเวลาทำงานจริง
--   เพราะมันจะ archive + ลบ wh_queue/wh_trucks ทันทีเหมือนกดปุ่ม "ล้างวันใหม่" จริง
--
-- ยกเลิก automation (ถ้าต้องการ):
--   select cron.unschedule('close-work-day-8am');
-- ============================================================
