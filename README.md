# Develop Server Setup — Interactive Installer (Ubuntu 22.04)

این اسکریپت یک **نصاب تعاملی** برای آماده‌سازی سریع یک سرور توسعه روی Ubuntu 22.04 است. در طول نصب، نام کاربری‌ها، کلمات عبور و پورت‌ها را **از شما می‌پرسد** و در پایان یک **گزارش خلاصه** روی صفحه و در فایل امن `/root/setup_summary.txt` ذخیره می‌کند.

> معماری نهایی مطابق تأیید شما:
>
> - **PostgreSQL (لوکال):** `127.0.0.1:5432` — از اینترنت بسته است.
> - **pgAdmin (لوکال):** `127.0.0.1:5050` — از طریق **Nginx Proxy Manager (NPM)** به اینترنت (HTTPS/دامنه) منتشر می‌شود.
> - **Metabase (Docker):** برای متادیتا از Postgres لوکال استفاده می‌کند (از طریق یک gateway داخلی).
> - **Nginx Proxy Manager (Docker):** پورت‌های 80/443/81 پابلیک؛ برای SSL و دامنه.
> - **Portainer (Docker):** مدیریت کانتینرها روی `9443`.
> - **code-server (لوکال/روت):** روی `127.0.0.1:8443` (در صورت نیاز با NPM منتشر کنید).
> - **UFW:** فقط پورت‌های وب و SSH باز؛ 5432/5050/8443 لوکال‌اند (پشت NPM/لوپ‌بک).

---

## چه چیزهایی نصب/راه‌اندازی می‌شود؟

### پکیج‌های پایه
- `curl`, `gnupg`, `unzip`, `git`, `nano`, `zip`, `ufw`, `software-properties-common`, `lsb-release`, `apt-transport-https`, `ca-certificates`

### Python
- **Python 3.11** + `venv`, `dev`, `distutils` و ست شدن به‌عنوان پیش‌فرض (`python3` و `pip3`).

### پایگاه داده
- **PostgreSQL (لوکال)** + ساخت یوزر/دیتابیس پیش‌فرض و دیتابیس/یوزر **Metabase**.

### سرویس‌های وب
- **pgAdmin 4 (لوکال)** — به‌صورت **standalone** روی `127.0.0.1:5050` (بدون Apache روی 80).
- **Metabase (Docker)** — برای UI تحلیلی؛ انتشار از طریق NPM.
- **Nginx Proxy Manager (Docker)** — پنل مدیریت معکوس، SSL Let’s Encrypt.
- **Portainer (Docker)** — پنل مدیریت Docker روی `9443` (HTTPS).
- **code-server (لوکال/روت)** — VS Code تحت وب روی `127.0.0.1:8443`.

### فایروال
- باز: `22/tcp` (SSH), `80/tcp`, `81/tcp`, `443/tcp`, `9443/tcp`
- بسته/لوکال: `5432/tcp` (Postgres), `5050/tcp` (pgAdmin), `8443/tcp` (code‑server)

---

## پورت‌ها و دسترسی سرویس‌ها

| سرویس | نوع نصب | آدرس/پورت | دسترسی اینترنتی |
|---|---|---|---|
| PostgreSQL | Local (apt) | `127.0.0.1:5432` | ❌ بسته (لوکال) |
| pgAdmin 4 | Local (apt) | `127.0.0.1:5050` | ✅ از طریق NPM/دامنه/SSL |
| Metabase | Docker | داخلی روی پورت `3000` | ✅ از طریق NPM/دامنه/SSL |
| Nginx Proxy Manager | Docker | 80/81/443 | ✅ مستقیم (Public) |
| Portainer | Docker | `9443` (HTTPS) | ✅ مستقیم (Public) |
| code-server | Local (systemd) | `127.0.0.1:8443` | ❌ لوکال (در صورت نیاز با NPM منتشر کنید) |

> **نکته:** Metabase به Postgres لوکال از طریق یک **gateway کانتینری (socat)** متصل می‌شود؛ این پل فقط داخل شبکه‌ی Docker فعال است و **5432 را به اینترنت باز نمی‌کند**.

---

## دانلود (بدون استفاده از کش گیت‌هاب)

برای جلوگیری از کشِ CDN، از یک پارامتر تصادفی و هدرهای ضدکش استفاده کنید:

```bash
# Linux/macOS
URL='https://raw.githubusercontent.com/BigPyth0n/Develop-Server-Setup/refs/heads/main/setup_server.sh'
TS="$(date +%s)"
curl -fsSL "${URL}?nocache=${TS}" \
  -H 'Cache-Control: no-cache' \
  -H 'Pragma: no-cache' \
  -H 'If-None-Match:' \
  -o setup_server.sh
```

```powershell
# Windows PowerShell
$URL = 'https://raw.githubusercontent.com/BigPyth0n/Develop-Server-Setup/refs/heads/main/setup_server.sh'
$TS  = [int][double]::Parse((Get-Date -UFormat %s))
curl "$URL?nocache=$TS" `
  -H 'Cache-Control: no-cache' `
  -H 'Pragma: no-cache' `
  -H 'If-None-Match:' `
  -o setup_server.sh
```

> اگر `curl` در ویندوز موجود نیست، از WSL/Git Bash استفاده کنید یا `Invoke-WebRequest` با هدرهای مشابه به‌کار ببرید.

---

## اعطای مجوز و اجرا

> **هشدار:** این اسکریپت باید با **sudo/روت** اجرا شود.

```bash
chmod +x setup_server.sh
sudo ./setup_server.sh
```

اسکریپت به‌صورت **تعاملی** اطلاعات موردنیاز (یوزرنیم، پسوردها، پورت‌ها، تایم‌زون و …) را از شما می‌پرسد. پس از اتمام نصب:

- خلاصه‌ی تنظیمات روی صفحه چاپ می‌شود.
- همان خلاصه در فایل **`/root/setup_summary.txt`** (فقط دسترسی روت، `0600`) ذخیره می‌گردد.

---

## مراحل بعد از نصب

1. **ورود به Nginx Proxy Manager (پورت 81):**  
   - `http://<SERVER_IP>:81`  
   - یک اکانت ادمین بساز/پسورد پیش‌فرض را تغییر بده.
2. **انتشار pgAdmin پشت NPM:**  
   - *Proxy Host* جدید → `pgadmin.yourdomain.com` → Forward: `127.0.0.1 : 5050`  
   - SSL: دریافت Let’s Encrypt + Force SSL + HTTP/2
3. **انتشار Metabase پشت NPM:**  
   - *Proxy Host* جدید → `metabase.yourdomain.com` → Forward: `metabase : 3000`  
   - SSL: دریافت Let’s Encrypt + Force SSL + HTTP/2
4. **اتصال pgAdmin به Postgres (داخل UI pgAdmin):**  
   - Host: `127.0.0.1` — Port: `5432`  
   - Username/Password: همان‌هایی که هنگام نصب وارد کرده‌اید.  
   - (Postgres از اینترنت باز نیست؛ اتصال در خود سرور برقرار می‌شود.)

---

## پیش‌نیازها و نکات امنیتی

- Ubuntu 22.04 و دسترسی روت/سودو
- پورت‌های `80/81/443/9443` در فایروال باز می‌شوند؛ `5432/5050/8443` لوکال می‌مانند.
- پسوردهای قوی انتخاب کنید؛ فایل خلاصه را امن نگه دارید.
- برای دسترسی توسعه به Postgres بدون باز کردن اینترنتی، از **Tunnel SSH** یا **pgAdmin** استفاده کنید.

---

## رفع اشکال سریع

- **pgAdmin باز نمی‌شود:** سرویس `pgadmin4` را بررسی/راه‌اندازی مجدد کنید:  
  ```bash
  sudo systemctl status pgadmin4
  sudo systemctl restart pgadmin4
  ```
- **Metabase به DB وصل نمی‌شود:** سرویس `pg-gateway` و Postgres لوکال را بررسی کنید:  
  ```bash
  docker ps
  systemctl status postgresql
  ```
- **SSL در NPM:** ساعت/تایم‌زون و DNS دامنه را بررسی کنید؛ دوباره از NPM درخواست گواهی بدهید.

---

## لایسنس

این README برای راه‌اندازی سریع محیط توسعه تهیه شده و قابل سفارشی‌سازی است. با مسئولیت خود استفاده کنید؛ پیشنهاد می‌شود قبل از اعمال در محیط تولید، در یک سرور تست اجرا کنید.
