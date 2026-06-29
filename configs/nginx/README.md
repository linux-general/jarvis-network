# nginx configs for the Jarvis Network voice front

`jarvis-voice.conf` is the canonical reverse-proxy config running on
**nginx (100.64.0.3, voice.jarvisnetwork.org)**. It maps Twilio webhook +
Media Stream paths to whichever orchestrator (ws-47 / bm-42 / vx-test) owns
them, with passive failover and a static TwiML fallback for HTTP voice
webhooks when all upstreams are down.

## Deploy

```bash
# from any machine with ssh access to nginx
scp configs/nginx/jarvis-voice.conf root@100.64.0.3:/etc/nginx/sites-available/jarvis-voice
ssh root@100.64.0.3 'nginx -t && systemctl reload nginx'
```

The reload is zero-downtime — existing connections drain on the old workers.

## Failover policy

| Path prefix          | Primary             | Backup                    | Static fallback       |
|----------------------|---------------------|---------------------------|-----------------------|
| `/voice/*`           | bm-42:18792 (v1)    | none                      | TwiML on HTTP webhook |
| `/twilio/voice|stream|tts`  | ws-47:8444 (v3) | bm-42:8444 (down)   | TwiML on HTTP webhook |
| `/twilio/v4/*`       | ws-47:8445          | bm-42:8445 (down)         | TwiML on HTTP webhook |
| `/twilio/v5/*`       | ws-47:8446          | bm-42:8446 (down)         | TwiML on HTTP webhook |
| `/twilio/steno/*`    | ws-47:8447          | bm-42:8447 (down)         | TwiML on HTTP webhook |
| `/cliq/*`            | ws-47:8470          | bm-42:8470 (down)         | none (HTTP only)      |
| `/vx-test/*`         | vx-test-01:8446     | none                      | none                  |

Passive health check: `max_fails=3 fail_timeout=30s`. After three connection
errors within 30s, the primary is marked unhealthy and nginx routes the next
30s of requests to the backup before retrying primary.

## Enabling bm-42 as a real backup (after task #9 lands)

Currently each backup line has the `down` marker which means nginx never
sends traffic there even on primary failure (calls just fail). To enable
real failover after bm-42 is running the orchestrator:

```bash
ssh root@100.64.0.3 '
  sed -i.before-flip "s/100.64.0.26:\([0-9]\+\) backup down/100.64.0.26:\1 backup/" \
    /etc/nginx/sites-available/jarvis-voice
  nginx -t && systemctl reload nginx
'
```

## What this doesn't solve (yet)

**Mid-call websocket survival.** Twilio Media Streams open a long-lived
WebSocket from Twilio → nginx → ws-47:8446. nginx doesn't re-establish that
socket if ws-47 dies mid-call. Twilio MAY retry the call via the voice
webhook, but in-progress calls drop. Solving this requires a stateful
bridge service that holds the Twilio side while reconnecting backends —
deferred to a later task.

**Cloud-API LLM/STT/TTS fallback.** Even with bm-42 backup, both nodes use
local STT/TTS/LLM. The orchestrator code on those nodes is responsible for
its own cloud-fallback chain. nginx is not the right place for that.
