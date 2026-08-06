# MVI Edge MQTT Telemetry

Streams detection data from MVI Edge into Grafana over MQTT. The stack bundles Mosquitto, a JSON fixer, Telegraf, InfluxDB, and Grafana, all running in Docker.

## Installation

Copy all the files to your server, keeping the folder structure intact.

Before running the installer, open `install.sh` and edit the `BROKER_IP` variable near the top so it matches your server's actual IP address.

Then make the script executable and run it:

```bash
chmod +x install.sh
./install.sh
```

This creates all the required folders and config files, generates a TLS certificate, sets random credentials, and spins up every container.

At the end, the installer prints your InfluxDB and Grafana passwords; save them right away. They're also stored in the `.env` file in the same folder, but they won't be shown again automatically.

## Accessing Grafana

Open `http://<BROKER_IP>:3000` and log in with user `admin` and the password the installer gave you (or check `.env` under `GRAFANA_PASSWORD`).

The `MVI Edge - Detecciones` dashboard is already provisioned and starts showing incoming detections right away.

## Configuring MVI Edge

In MVI Edge, go to **Settings > MQTT** and set:

- **Host:** the same `BROKER_IP` you used in `install.sh`
- **Port:** `1883`
- **Encryption (TLS):** off
- **Username:** empty
- **Password:** empty

## Topic

MVI Edge must publish to the `edge-result` topic. Don't change this; the JSON fixer, Telegraf, and the Grafana dashboard all depend on that exact name.

## Notes

Lost your credentials? Just run:

```bash
cat .env
```

## Licenses

This project orchestrates (via Docker Compose) the following third-party components, each under its own license:

| Component | License | Link |
| --- | --- | --- |
| Eclipse Mosquitto | EPL 2.0 / EDL 1.0 | https://github.com/eclipse/mosquitto/blob/master/LICENSE.txt |
| paho-mqtt (Python) | EPL 2.0 / EDL 1.0 | https://github.com/eclipse/paho.mqtt.python/blob/master/LICENSE |
| InfluxDB 2.7 | MIT | https://github.com/influxdata/influxdb/blob/master/LICENSE |
| Telegraf | MIT | https://github.com/influxdata/telegraf/blob/master/LICENSE |
| Grafana 11.1.0 | AGPLv3 | https://github.com/grafana/grafana/blob/main/LICENSE |
| Python | PSF License | https://docs.python.org/3/license.html |

The original code in this repository (`fixer.py`, configuration files, `install.sh`, dashboards) is licensed under the [Apache License 2.0](LICENSE), unless otherwise noted.
