-- ============================================================
-- เพิ่มตาราง wh_settings สำหรับค่า config ที่เคย hardcode ไว้ใน App.jsx
-- รันสคริปต์นี้ครั้งเดียวใน Supabase SQL Editor ของ project จริง
--
-- key ที่แอปรู้จัก (ดู src/lib/settings.js):
--   work_day_cutoff_minutes number เวลาตัดรอบวันทำงาน เป็นนาทีนับจากเที่ยงคืน (450 = 07:30)
--                                  (แทน work_day_cutoff_hour เดิมที่ตั้งได้แค่ชั่วโมงเต็ม)
--   waiting_urgent_minutes number  รอเกินกี่นาทีถึงจะขึ้นเตือน "urgent" สีแดง
--   max_photo_uploads      number  จำนวนรูปสูงสุดต่อครั้งที่แนบได้
--   max_waiting_reasons    number  จำนวนเหตุผลรอสินค้าสูงสุดต่อครั้ง
--   geofence               object  { lat, lng, radiusM } พิกัด+รัศมีเช็คอินคนขับ
--
-- ไม่ insert ค่าเริ่มต้นไว้ในสคริปต์นี้ — แอปมีค่า default ในโค้ดอยู่แล้ว
-- (src/lib/settings.js) ถ้ายังไม่มีแถวในตารางนี้แอปจะใช้ค่า default ไปก่อน
-- พอมีคนแก้ผ่านหน้า "ตั้งค่าระบบ" ค่อยสร้างแถวขึ้นมาเอง (upsert)
-- ============================================================

create table if not exists wh_settings (
  id    text primary key,
  value jsonb
);

alter table wh_settings enable row level security;
drop policy if exists "allow all" on wh_settings;
create policy "allow all" on wh_settings for all using (true) with check (true);
