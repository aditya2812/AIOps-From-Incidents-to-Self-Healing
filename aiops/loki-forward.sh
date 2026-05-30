#!/bin/bash
while true; do
  echo "[loki-forward] starting port-forward..."
  kubectl port-forward -n monitoring svc/loki-gateway 3100:80
  echo "[loki-forward] died — restarting in 2s..."
  sleep 2
done
