#!/bin/bash

echo "🚀 Starting VerneMQ using Docker Compose..."
docker compose up -d

echo "⏳ Waiting for VerneMQ Original to be healthy..."
sleep 10

#echo "📜 Loading custom Redis counter script..."
#docker compose exec vernemq-original vmq-admin script load path=/etc/vernemq/lua/auth.lua || true
