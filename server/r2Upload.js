import { AwsClient } from 'aws4fetch'

const ALLOWED_PREFIXES = ['qc/', 'sample/', 'loading/']

function base64ToUint8Array(base64) {
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}

export async function uploadBase64ToR2(env, path, dataBase64, contentType) {
  if (!path || !ALLOWED_PREFIXES.some(p => path.startsWith(p))) {
    throw new Error('เส้นทางไฟล์ไม่ถูกต้อง')
  }
  if (!dataBase64) {
    throw new Error('ไม่มีข้อมูลรูปภาพ')
  }

  const r2 = new AwsClient({
    accessKeyId: env.R2_ACCESS_KEY_ID,
    secretAccessKey: env.R2_SECRET_ACCESS_KEY,
    service: 's3',
    region: 'auto',
  })

  const endpoint = `https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`
  const url = `${endpoint}/${env.R2_BUCKET}/${path}`

  const res = await r2.fetch(url, {
    method: 'PUT',
    body: base64ToUint8Array(dataBase64),
    headers: { 'Content-Type': contentType || 'image/jpeg' },
  })
  if (!res.ok) throw new Error(`R2 upload failed: ${res.status}`)
  return `${env.R2_PUBLIC_URL}/${path}`
}
