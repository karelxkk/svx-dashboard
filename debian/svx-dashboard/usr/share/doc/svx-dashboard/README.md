# SVX Dashboard

Simple dashboard for SvxLink/M17. Static files are served under `/svx/`. The SSE stream is proxied at `/svx/events`. Runtime data live in `/run/svx/`. The package does **not** modify third‑party configs by default.

## Requirements
- Debian 12+
- `python3`, `svxlink-server`, `svxreflector`
- Web server: `apache2` or `nginx`

## Install from .deb
```bash
sudo dpkg -i svx-dashboard_*.deb
# Apache (optional)
sudo a2enconf svx-dashboard && sudo a2enmod alias proxy proxy_http headers
sudo apache2ctl -t && sudo apache2ctl -k graceful
# Nginx (optional)
echo 'include /etc/nginx/snippets/svx-dashboard.locations;' | sudo tee -a /etc/nginx/sites-available/default
sudo nginx -t && sudo systemctl reload nginx
# Services and runtime
sudo systemd-tmpfiles --create
sudo systemctl enable --now svx-sse.service svx-history-rotate.timer
```

## SvxLink integration (manual)
1. Ensure `[ReflectorLogic]` section exists in `/etc/svxlink/svxlink.conf`.
2. In `[GLOBAL]` add:
   ```ini
   EVENT_HANDLER=/etc/svxlink/events-dashboard.tcl
   ```
3. Create `/etc/svxlink/events-dashboard.tcl` (or copy from examples):
   ```tcl
   if {[file exists "/etc/svxlink/events.d/svx_backend.tcl"]} { source /etc/svxlink/events.d/svx_backend.tcl }
   if {[file exists "/etc/svxlink/events.d/EchoLink.tcl"]}    { source /etc/svxlink/events.d/EchoLink.tcl }
   ```
4. In `/etc/svxlink/svxreflector.conf` set in `[GLOBAL]`:
   ```ini
   HTTP_SRV_PORT=8880
   ```

## Paths
- Web root: `/var/www/svx/`
- Runtime: `/run/svx/{status.json,history.csv}` (created by tmpfiles)
- SSE daemon: `/usr/bin/svx_sse.py` (listens on 127.0.0.1:8890)
- Apache conf: `/etc/apache2/conf-available/svx-dashboard.conf`
- Nginx snippet: `/etc/nginx/snippets/svx-dashboard.locations`

## Verification
```bash
curl -I  http://127.0.0.1/svx/
curl -iN http://127.0.0.1/svx/events | head -n2  # GET only; HEAD returns 501
```

## Troubleshooting
- **404 /svx/**: missing content in `/var/www/svx` or conflicting `Alias /svx` elsewhere.
- **503 or 501 /svx/events**: `svx-sse.service` not running, or using HEAD instead of GET.
- Apache warning “ServerName”: `a2enconf servername && apache2ctl -t && apache2ctl -k graceful`.
