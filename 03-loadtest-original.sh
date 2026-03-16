echo "🔥 Running load test on Original Vernemq..."
./k6 run -e PORT=1883 loadtest.js
