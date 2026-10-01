import { uploadBase64ToR2 } from '../server/r2Upload.js'

export default {
  async fetch(request, env) {
    const url = new URL(request.url)

    if (url.pathname === '/api/upload-photo') {
      if (request.method !== 'POST') {
        return Response.json({ error: 'Method not allowed' }, { status: 405 })
      }
      try {
        const { path, dataBase64, contentType } = await request.json()
        const uploadedUrl = await uploadBase64ToR2(env, path, dataBase64, contentType)
        return Response.json({ url: uploadedUrl })
      } catch (e) {
        return Response.json({ error: e.message }, { status: 400 })
      }
    }

    return env.ASSETS.fetch(request)
  },
}
