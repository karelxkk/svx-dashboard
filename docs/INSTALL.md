# INSTALL

## 1) Install the package
```bash
sudo dpkg -i svx-dashboard_*.deb
sudo systemd-tmpfiles --create
sudo systemctl enable --now svx-sse.service svx-history-rotate.timer
```

## 2) Web server
### Apache
```bash
sudo a2enconf svx-dashboard
sudo a2enmod alias proxy proxy_http headers
sudo apache2ctl -t && sudo apache2ctl -k graceful
```
### Nginx
```bash
echo 'include /etc/nginx/snippets/svx-dashboard.locations;' | sudo tee -a /etc/nginx/sites-available/default
sudo nginx -t && sudo systemctl reload nginx
```

## 3) SvxLink
```ini
# /etc/svxlink/svxlink.conf
[GLOBAL]
EVENT_HANDLER=/etc/svxlink/events-dashboard.tcl
```
```tcl
# /etc/svxlink/events-dashboard.tcl
if {[file exists "/etc/svxlink/events.d/svx_backend.tcl"]} { source /etc/svxlink/events.d/svx_backend.tcl }
if {[file exists "/etc/svxlink/events.d/EchoLink.tcl"]}    { source /etc/svxlink/events.d/EchoLink.tcl }
```
```ini
# /etc/svxlink/svxreflector.conf
[GLOBAL]
HTTP_SRV_PORT=8880
```

## 4) Test
```bash
curl -I  http://127.0.0.1/svx/
curl -iN http://127.0.0.1/svx/events | head -n2
```

## Notes
- `/run/svx/` is tmpfs and recreated by tmpfiles at boot.
- Package does not modify third‑party config files automatically.
