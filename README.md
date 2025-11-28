# svx-dashboard

Simple web dashboard for SvxLink and M17 with SSE backend, ELB backend, and SVXLink event scripts.

## Installation using the official .deb package

The project provides an official Debian package `svx-dashboard_*.deb`.  
It installs:

- static web UI under `/usr/share/svx-dashboard/html/`
- SSE backend (`svx-sse.service`)
- ELB backend (`elb-daemon.service`)
- history rotation timer (`svx-history-rotate.timer`)
- SVXLink event hooks (`/etc/svxlink/events.d/…`)
- Apache and Nginx configuration snippets
- tmpfiles rules for `/run/svxlink` and history files

### 1) Install the package

```bash
sudo dpkg -i svx-dashboard_*.deb
sudo apt-get -f install
```

### 2) (Optional) Enable Apache integration

A configuration snippet is installed into:

```
/etc/apache2/conf-available/svx-dashboard.conf
```

To enable it:

```bash
sudo a2enconf svx-dashboard
sudo a2enmod alias proxy proxy_http headers
sudo apache2ctl -t && sudo apache2ctl -k graceful
```

### 3) (Optional) Enable Nginx integration

A snippet for Nginx is installed into:

```
/etc/nginx/snippets/svx-dashboard.locations
```

To enable it in your server block:

```bash
echo 'include /etc/nginx/snippets/svx-dashboard.locations;'   | sudo tee -a /etc/nginx/sites-available/default

sudo nginx -t && sudo systemctl reload nginx
```

### 4) Start the backend services

```bash
sudo systemd-tmpfiles --create
sudo systemctl enable --now svx-sse.service svx-history-rotate.timer elb-daemon.service
```

## SvxLink Integration

Your SVXLink installation must load the event scripts provided by the package.

### 1) In `/etc/svxlink/svxlink.conf`

Ensure `[GLOBAL]` contains:

```ini
EVENT_HANDLER=/etc/svxlink/events.tcl
```

### 2) Provided event handlers

These are installed automatically:

```
/etc/svxlink/events.tcl
/etc/svxlink/events.d/svx_backend.tcl
/etc/svxlink/events.d/svx_serial.tcl
/etc/svxlink/events.d/svx_usrp.tcl
/etc/svxlink/events.d/EchoLink.tcl
```

### 3) SvxReflector (optional)

In `/etc/svxlink/svxreflector.conf`:

```ini
HTTP_SRV_PORT=8880
```

## Paths (installed by the .deb package)

- Web UI: `/usr/share/svx-dashboard/html/`
- Runtime state (tmpfiles): `/run/svxlink/{status.json,history.csv}`
- SSE backend: `/usr/lib/svx-dashboard/svx_sse.py`
- ELB backend: `/usr/lib/svx-dashboard/elb_daemon.tcl`
- History rotation: `/usr/lib/svx-dashboard/svx_history_rotate.sh`
- systemd units:
  - `svx-sse.service`
  - `svx-history-rotate.timer`
  - `svx-history-rotate.service`
  - `elb-daemon.service`
- Apache config: `/etc/apache2/conf-available/svx-dashboard.conf`
- Nginx snippet: `/etc/nginx/snippets/svx-dashboard.locations`

## Verification

```bash
curl -I  http://127.0.0.1/svx/
curl -iN http://127.0.0.1/svx/events | head -n2
```

## Troubleshooting

- **404 /svx/**  
  Web server does not include the provided snippet.

- **503 or empty SSE**  
  `svx-sse.service` is not running or blocked by firewall.

- **ELB backend not reporting**  
  Check logs:  
  `journalctl -u elb-daemon.service`

- **Missing history.csv or status.json**  
  Run: `sudo systemd-tmpfiles --create`
