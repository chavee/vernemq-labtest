#!/bin/bash

echo "🚀 Starting VerneMQ using Docker Compose..."
docker compose up -d

echo "⏳ Waiting for VerneMQ to be healthy..."
sleep 10

echo "📜 Loading custom Redis counter script..."
docker compose exec vernemq vmq-admin script load path=/etc/vernemq/lua/auth.lua || true

echo "🛠 Building custom k6 with MQTT support (xk6-mqtt)..."
# ต้องใช้ xk6 ในการ build k6 ที่รองรับ MQTT
export PATH=$PATH:$(go env GOPATH)/bin
if ! command -v xk6 &> /dev/null
then
    echo "Installing xk6..."
    go install go.k6.io/xk6/cmd/xk6@latest
fi

# Build k6 พร้อม mqtt extension
xk6 build --with github.com/pmalhaire/xk6-mqtt@latest

echo "🔥 Running load test..."
./k6 run load-test.js

echo "🛑 Stopping VerneMQ..."
# docker compose down
