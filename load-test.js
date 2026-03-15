import { check, sleep } from 'k6';
const mqtt = require('k6/x/mqtt');

export const options = {
  scenarios: {
    mqtt_load: {
      executor: 'constant-vus',
      vus: 500, // ลด VUs ลงก่อนเพื่อทดสอบว่าไม่โดน Kill
      duration: '30s', // ระยะเวลาที่เทส
    },
  },
};

const host = "127.0.0.1";
const port = "1883";
const clientId = `k6-client-${__VU}`;
const connectTimeout = 2000;
const publishTimeout = 2000;
const closeTimeout = 2000;

// สร้าง Client หนึ่งตัวต่อ VU (Virtual User) ในรอบ Init
let client = new mqtt.Client(
    [host + ":" + port],
    "",     // username (anonymous)
    "",     // password
    true,   // clean session
    clientId,
    connectTimeout
);

let connectErr;
try {
    client.connect();
} catch (error) {
    connectErr = error;
}

if (connectErr !== undefined) {
    console.error("MQTT Connect Error:", connectErr);
}

export default function () {
    // เช็คว่าต่อสำเร็จ (อิงจาก state ที่ connect ไว้ตอน init)
    check(client, {
      'connected': (c) => c.isConnected(),
    });

    if (!client.isConnected()) {
        sleep(1);
        return;
    }

    let publishErr;
    try {
        // publish payload เล็กที่สุด พร้อม QoS 0 (ยิงแล้วจบ ไม่รอ ACK เพื่อ latency ต่ำที่สุด)
        client.publish(
            'test/latency',
            0,             // QoS
            'ok',          // Payload
            false,         // Retain
            publishTimeout // Timeout
        );
    } catch (error) {
        publishErr = error;
    }

    check(publishErr, {
      'published': (err) => err === undefined,
    });

    // เพิ่มเวลาหน่วงเพื่อไม่ให้กิน CPU ฝั่ง k6 มากเกินไปจนโดน OS kill
    sleep(0.05);
}

export function teardown() {
    if (client && client.isConnected()) {
        client.close(closeTimeout);
    }
}
