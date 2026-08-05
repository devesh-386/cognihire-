# Ticket 9 — cloud VM (Ollama + face service)

One small always-on VM serves both the HR desktop app and the candidate web app,
so interviews work from anywhere, not just localhost.

## Steps

1. **Provision the VM.** Hetzner Cloud CX32 (2 vCPU / 8GB RAM), Ubuntu 24.04. 8GB is the
   floor for `qwen2.5:7b` running comfortably alongside the face service.
2. **Point a domain at it.** Any subdomain you own, A record → the VM's IP.
3. **SSH in and run the base setup:**
   ```bash
   scp cloud_vm_setup.sh root@<VM_IP>:
   ssh root@<VM_IP> 'bash cloud_vm_setup.sh'
   ```
   Installs Ollama, pulls `qwen2.5:7b`, sets up the firewall, installs nginx/certbot.
4. **Deploy the face service:**
   ```bash
   ssh root@<VM_IP>
   useradd -m -s /bin/bash cognihire
   mkdir -p /opt/cognihire && chown cognihire:cognihire /opt/cognihire
   su - cognihire
   git clone <this repo> /opt/cognihire/repo   # or scp service/ directly
   cp -r /opt/cognihire/repo/service /opt/cognihire/service
   cd /opt/cognihire/service
   python3 -m venv .venv
   .venv/bin/pip install -r requirements.txt
   exit  # back to root
   ```
   Edit `ALLOWED_ORIGINS` in `face-service.service` to the real HR/candidate app
   origins once Ticket 13 has them, then:
   ```bash
   cp face-service.service /etc/systemd/system/
   systemctl daemon-reload
   systemctl enable --now face-service
   ```
5. **Reverse proxy + TLS:**
   ```bash
   cp nginx-cognihire.conf /etc/nginx/sites-available/cognihire
   # edit YOUR_DOMAIN_HERE first
   ln -s /etc/nginx/sites-available/cognihire /etc/nginx/sites-enabled/
   nginx -t && systemctl reload nginx
   certbot --nginx -d <your-domain>
   ```
6. **Verify:**
   ```bash
   curl https://<your-domain>/ollama/api/tags
   curl https://<your-domain>/face/health   # or whatever health route main.py exposes
   ```
7. **Point the apps at it** — relaunch with:
   ```
   --dart-define=OLLAMA_BASE_URL=https://<your-domain>/ollama
   --dart-define=FACE_SERVICE_URL=https://<your-domain>/face
   ```

## Cost

Hetzner CX32 ≈ €13.10/mo (~$14). This is the only ongoing infra cost in the pivot —
Supabase (Ticket 8) is free tier.

---

# Ticket 11 — Google Form intake → Supabase

`intake-webhook` (deployed, `supabase functions deploy intake-webhook` if you ever
need to redeploy manually — see `infra/intake-webhook/index.ts`) turns one Google
Form response into a candidate + a scheduled invitation, with `code_send_at`/
`reminder_send_at` already computed from the candidate's requested time (T-60/T-30
minutes) — Ticket 12 only has to poll and send, not do the scheduling math.

## 1. Create the Google Form

Fields, exact titles (the Apps Script matches on these):
- **Full name** — short answer
- **Email** — short answer, "Response validation" → email
- **Which role are you applying for?** — short answer or dropdown. Must match an
  existing `Role.title` in your organisation *exactly* (case-insensitive) — HR
  creates the role in the app first, then you copy its title into the form.
- **Preferred interview time** — Date question with "Include time" on
- **Resume** — File upload, restrict to PDF/DOC/DOCX, max 1 file

## 2. Wire the Apps Script

1. In the Form, **⋮ → Script editor** (or Extensions → Apps Script).
2. Paste in `infra/google-form-apps-script.gs`.
3. Replace `WEBHOOK_SECRET` with: `wauVZueHxrCg-_ezPuqrZEjaildmrh_AGl-jdJmkxYg`
   (already set as the Edge Function's `INTAKE_WEBHOOK_SECRET` secret below —
   keep both in sync if you rotate it).
4. **Triggers** (clock icon in the left sidebar) → **+ Add Trigger** → function
   `onFormSubmit`, event source **From form**, event type **On form submit**.
   Authorize when prompted (it needs Drive access to read the uploaded résumé).

## 3. Set the Edge Function's secrets

Needs the Supabase CLI (`npm install -g supabase`, then `supabase login`):

```bash
supabase secrets set --project-ref foffzvwmxnsmbixkilxt \
  INTAKE_WEBHOOK_SECRET=wauVZueHxrCg-_ezPuqrZEjaildmrh_AGl-jdJmkxYg
```

`INTAKE_ORGANIZATION_ID` can't be set until you've registered your HR account
(Ticket 10 — `flutter run` → "New organisation? Create an account"), since that's
what creates the `organizations` row. Once you have, find your org id:

```bash
supabase --project-ref foffzvwmxnsmbixkilxt db query \
  "select id, name from organizations;"
```

then:

```bash
supabase secrets set --project-ref foffzvwmxnsmbixkilxt \
  INTAKE_ORGANIZATION_ID=<the id from above>
```

## 4. Verify

Submit the Google Form once with a role title that matches a real role you created.
Check it landed:

```bash
supabase --project-ref foffzvwmxnsmbixkilxt db query \
  "select c.name, i.status, i.scheduled_at, i.code_send_at from invitations i join candidates c on c.id = i.candidate_id order by i.created_at desc limit 1;"
```

Or check the function's own logs in the Supabase Dashboard → Edge Functions →
`intake-webhook` → Logs, if the submission didn't show up (wrong role title is the
most likely miss — it's an exact-title match against your roles table).
