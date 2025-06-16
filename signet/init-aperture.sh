#!/bin/bash

# Initialize Aperture with proper TLS certificate generation
echo "Initializing Aperture for Loop Signet environment..."

# Create necessary directories
mkdir -p /root/.aperture
mkdir -p /root/.loop

# Wait for ETCD to be ready
echo "Waiting for ETCD to be ready..."
while ! nc -z localhost 2379; do
  sleep 1
done
echo "ETCD is ready"

# Wait for LND to be accessible
echo "Waiting for LND to be accessible..."
while ! nc -z localhost 10009; do
  sleep 1
done
echo "LND is accessible"

# Start Aperture
echo "Starting Aperture..."
exec /bin/aperture --configfile=/root/.aperture/aperture.yaml 