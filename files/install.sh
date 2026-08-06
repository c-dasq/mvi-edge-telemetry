#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BROKER_IP="192.168.1.XXX"
BROKER_PORT="8883"

echo "=== 1/6: Verificando Docker ==="
if ! command -v curl >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y curl
fi

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

if ! docker compose version >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y docker-compose-plugin
fi

echo "=== 2/6: Creando estructura de carpetas ==="
mkdir -p mosquitto/config
mkdir -p mosquitto/data
mkdir -p mosquitto/log
mkdir -p mosquitto/certs
mkdir -p mqtt-fixer
mkdir -p telegraf
mkdir -p influxdb/data
mkdir -p influxdb/config
mkdir -p grafana/data
mkdir -p grafana/provisioning/datasources
mkdir -p grafana/provisioning/dashboards
mkdir -p grafana/dashboards

echo "=== 3/6: Escribiendo archivos de configuracion ==="

cat > docker-compose.yml << 'EOF'
services:
  mosquitto:
    image: eclipse-mosquitto:2
    container_name: mosquitto
    restart: unless-stopped
    ports:
      - "1883:1883"
      - "8883:8883"
    volumes:
      - ./mosquitto/config:/mosquitto/config
      - ./mosquitto/data:/mosquitto/data
      - ./mosquitto/log:/mosquitto/log
      - ./mosquitto/certs:/mosquitto/certs

  mqtt-fixer:
    image: python:3.12-slim
    container_name: mqtt-fixer
    restart: unless-stopped
    depends_on:
      - mosquitto
    environment:
      - PYTHONUNBUFFERED=1
    volumes:
      - ./mqtt-fixer/fixer.py:/app/fixer.py:ro
    command: sh -c "pip install --quiet paho-mqtt && python -u /app/fixer.py"

  influxdb:
    image: influxdb:2.7
    container_name: influxdb
    restart: unless-stopped
    ports:
      - "8086:8086"
    environment:
      - DOCKER_INFLUXDB_INIT_MODE=setup
      - DOCKER_INFLUXDB_INIT_USERNAME=admin
      - DOCKER_INFLUXDB_INIT_PASSWORD=${INFLUXDB_PASSWORD}
      - DOCKER_INFLUXDB_INIT_ORG=${INFLUXDB_ORG}
      - DOCKER_INFLUXDB_INIT_BUCKET=${INFLUXDB_BUCKET}
      - DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=${INFLUXDB_TOKEN}
    volumes:
      - ./influxdb/data:/var/lib/influxdb2
      - ./influxdb/config:/etc/influxdb2

  telegraf:
    image: telegraf:1.31
    container_name: telegraf
    restart: unless-stopped
    depends_on:
      - mosquitto
      - influxdb
      - mqtt-fixer
    volumes:
      - ./telegraf/telegraf.conf:/etc/telegraf/telegraf.conf:ro
    environment:
      - INFLUXDB_TOKEN=${INFLUXDB_TOKEN}
      - INFLUXDB_ORG=${INFLUXDB_ORG}
      - INFLUXDB_BUCKET=${INFLUXDB_BUCKET}

  grafana:
    image: grafana/grafana:11.1.0
    container_name: grafana
    restart: unless-stopped
    ports:
      - "3000:3000"
    depends_on:
      - influxdb
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
      - INFLUXDB_TOKEN=${INFLUXDB_TOKEN}
      - INFLUXDB_ORG=${INFLUXDB_ORG}
      - INFLUXDB_BUCKET=${INFLUXDB_BUCKET}
    volumes:
      - ./grafana/data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
      - ./grafana/dashboards:/var/lib/grafana/dashboards
EOF

cat > mosquitto/config/mosquitto.conf << 'EOF'
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log

listener 1883
protocol mqtt
allow_anonymous true

listener 8883
protocol mqtt
allow_anonymous true
certfile /mosquitto/certs/server.crt
keyfile /mosquitto/certs/server.key
EOF

cat > mqtt-fixer/fixer.py << 'EOF'
import re
import json
import paho.mqtt.client as mqtt

BROKER = "mosquitto"
PORT = 1883
TOPIC_IN = "edge-result"
TOPIC_OUT = "edge-result-clean"

def fix_json(raw):
    fixed = re.sub(r'"text"\s*:\s*,', '"text":"",', raw)
    fixed = re.sub(r',\s*}', '}', fixed)
    fixed = re.sub(r',\s*]', ']', fixed)
    return fixed

def on_connect(client, userdata, flags, rc, properties=None):
    print(f"Conectado al broker, rc={rc}", flush=True)
    client.subscribe(TOPIC_IN)

def on_message(client, userdata, msg):
    raw = msg.payload.decode("utf-8", errors="replace")
    fixed = fix_json(raw)
    try:
        json.loads(fixed)
        client.publish(TOPIC_OUT, fixed)
        print(f"OK: republicado en {TOPIC_OUT}", flush=True)
    except json.JSONDecodeError as e:
        print(f"No se pudo reparar el JSON: {e}", flush=True)

client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
client.on_connect = on_connect
client.on_message = on_message
client.connect(BROKER, PORT, 60)
client.loop_forever()
EOF

cat > telegraf/telegraf.conf << 'EOF'
[agent]
  interval = "10s"
  flush_interval = "10s"

[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto:1883"]
  topics = ["edge-result-clean"]
  topic_tag = "topic"
  data_format = "json_v2"
  name_override = "mvi_edge"

  [[inputs.mqtt_consumer.json_v2]]
    [[inputs.mqtt_consumer.json_v2.object]]
      path = "detectedobjects"
      tags = ["label"]
      excluded_keys = ["text"]

[[outputs.influxdb_v2]]
  urls = ["http://influxdb:8086"]
  token = "$INFLUXDB_TOKEN"
  organization = "$INFLUXDB_ORG"
  bucket = "$INFLUXDB_BUCKET"
EOF

cat > grafana/provisioning/datasources/influxdb.yml << 'EOF'
apiVersion: 1

datasources:
  - name: InfluxDB
    uid: InfluxDB
    type: influxdb
    access: proxy
    url: http://influxdb:8086
    jsonData:
      version: Flux
      organization: ${INFLUXDB_ORG}
      defaultBucket: ${INFLUXDB_BUCKET}
      tlsSkipVerify: true
    secureJsonData:
      token: ${INFLUXDB_TOKEN}
    isDefault: true
    editable: true
EOF

cat > grafana/provisioning/dashboards/dashboard.yml << 'EOF'
apiVersion: 1

providers:
  - name: "MVI Edge"
    orgId: 1
    folder: ""
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
EOF

cat > grafana/dashboards/mvi_dashboard.json << 'EOF'
{
  "title": "MVI Edge - Detecciones",
  "uid": "mvi-edge-raw",
  "timezone": "browser",
  "schemaVersion": 39,
  "version": 4,
  "refresh": "5s",
  "time": { "from": "now-1h", "to": "now" },
  "panels": [
    {
      "id": 1,
      "type": "table",
      "title": "Ultimas detecciones",
      "gridPos": { "h": 10, "w": 24, "x": 0, "y": 0 },
      "datasource": { "type": "influxdb", "uid": "InfluxDB" },
      "targets": [
        {
          "datasource": { "type": "influxdb", "uid": "InfluxDB" },
          "query": "from(bucket: \"mvi-bucket\") |> range(start: -1h) |> filter(fn: (r) => r._measurement == \"mvi_edge\") |> sort(columns: [\"_time\"], desc: true) |> limit(n: 50)",
          "refId": "A"
        }
      ]
    },
    {
      "id": 2,
      "type": "timeseries",
      "title": "Score por tipo de objeto",
      "gridPos": { "h": 10, "w": 24, "x": 0, "y": 10 },
      "datasource": { "type": "influxdb", "uid": "InfluxDB" },
      "targets": [
        {
          "datasource": { "type": "influxdb", "uid": "InfluxDB" },
          "query": "from(bucket: \"mvi-bucket\") |> range(start: -1h) |> filter(fn: (r) => r._measurement == \"mvi_edge\") |> filter(fn: (r) => r._field == \"score\")",
          "refId": "A"
        }
      ]
    }
  ]
}
EOF

echo "=== 4/6: Generando certificado TLS para Mosquitto ($BROKER_IP:$BROKER_PORT) ==="
if [ ! -f mosquitto/certs/server.crt ]; then
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout mosquitto/certs/server.key \
    -out mosquitto/certs/server.crt \
    -days 3650 \
    -subj "/CN=$BROKER_IP"
fi

echo "=== 4.1/6: Ajustando permisos ==="
chmod -R 777 mosquitto/data mosquitto/log mosquitto/certs
chmod -R 777 grafana/data
chmod 644 mosquitto/certs/server.crt mosquitto/certs/server.key

echo "=== 5/6: Generando credenciales (.env) ==="
if [ ! -f .env ]; then
  RAND_TOKEN=$(openssl rand -hex 32)
  RAND_INFLUX_PW=$(openssl rand -hex 12)
  RAND_GRAFANA_PW=$(openssl rand -hex 8)

  cat > .env << ENVEOF
INFLUXDB_ORG=mvi-org
INFLUXDB_BUCKET=mvi-bucket
INFLUXDB_TOKEN=$RAND_TOKEN
INFLUXDB_PASSWORD=$RAND_INFLUX_PW
GRAFANA_PASSWORD=$RAND_GRAFANA_PW
ENVEOF

  cat .env
fi

echo "=== 6/6: Levantando el stack ==="
docker compose down -v 2>/dev/null || true
docker compose up -d

sleep 10
source .env

echo ""
echo "================================================================"
echo " Mosquitto (sin TLS): $BROKER_IP:1883"
echo " Mosquitto (TLS, para MVI Edge): $BROKER_IP:$BROKER_PORT"
echo " InfluxDB UI: http://$BROKER_IP:8086 (admin / $INFLUXDB_PASSWORD)"
echo " Grafana: http://$BROKER_IP:3000 (admin / $GRAFANA_PASSWORD)"
echo ""
echo " docker ps"
echo " docker logs mqtt-fixer -f"
echo " mosquitto_sub -h $BROKER_IP -p 1883 -t 'edge-result-clean' -v"
echo "================================================================"
