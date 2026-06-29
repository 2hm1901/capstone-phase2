FROM python:3.11-slim

WORKDIR /app

# Install dependencies as root
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source code
COPY generator.py .

# Hardening: Run as non-root user
USER 1000

CMD ["python", "generator.py"]
