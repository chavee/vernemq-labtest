#!/bin/bash

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
