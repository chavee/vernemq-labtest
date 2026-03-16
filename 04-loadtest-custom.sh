echo "🔥 Running load test on Custom Vernemq..."
./k6 run -e PORT=1993 loadtest.js
