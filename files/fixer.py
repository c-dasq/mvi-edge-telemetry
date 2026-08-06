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
