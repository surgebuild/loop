#!/bin/bash

# The absolute directory this file is located in.
COMPOSE="docker compose -p signet"

# Configuration for your existing LND
LND_DIR=${LND_DIR:-"/root/.lnd"}

function bitcoin() {
  # Connect to your existing bitcoind container
  docker exec -ti bitcoind bitcoin-cli -signet -rpcuser=bitcoin -rpcpassword=bitcoin "$@"
}

function lnd() {
  # Connect to your existing LND node on host
  lncli --network signet --rpcserver=localhost:10009 --macaroonpath="${LND_DIR}/data/chain/bitcoin/signet/admin.macaroon" --tlscertpath="${LND_DIR}/tls.cert" "$@"
}

function loop() {
  docker exec -ti loopclient-signet loop --network signet "$@"
}

function start() {
  echo "Starting Loop signet environment..."
  echo "Connecting to your existing LND at localhost:10009"
  echo "LND directory: $LND_DIR"
  
  # Export LND directory for docker compose
  export LND_DIR="$LND_DIR"
  
  # Check if your LND is accessible
  if ! lnd getinfo >/dev/null 2>&1; then
    echo "WARNING: Cannot connect to your LND at localhost:10009"
    echo "Please ensure your LND is running and accessible"
    echo "Expected LND config location: $LND_DIR"
    echo ""
    echo "Continue anyway? (y/n)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
      exit 1
    fi
  else
    echo "✓ Successfully connected to your existing LND"
  fi
  
  $COMPOSE up --force-recreate -d
  echo "Waiting for services to start..."
  sleep 10
  setup
}

function setup() {  
  echo "Copying aperture configuration files"
  setup_aperture_config

  echo "Checking Bitcoin signet status"
  bitcoin getblockchaininfo || echo "Warning: Could not connect to your Bitcoin signet node"

  echo "Checking your existing LND"
  LND_INFO=$(lnd getinfo 2>/dev/null)
  
  if [ $? -eq 0 ]; then
    echo "✓ Connected to your existing LND successfully"
    PUBKEY=$(echo "$LND_INFO" | jq -r .identity_pubkey)
    BALANCE=$(lnd walletbalance 2>/dev/null | jq -r .confirmed_balance || echo "0")
    
    echo "LND Pubkey: $PUBKEY"
    echo "Wallet Balance: $BALANCE sats"
    
    if [ "$BALANCE" = "0" ]; then
      echo ""
      echo "Your LND wallet appears to be empty."
      echo "You may need to fund it with signet coins for testing Loop."
      ADDR=$(lnd newaddress p2wkh | jq -r .address 2>/dev/null)
      echo "LND Address: $ADDR"
    fi
    
    echo ""
    echo "Your LND CLTV settings from config:"
    echo "- max-cltv-expiry=300 (this should fix the CLTV delta error!)"
    echo "- bitcoin.timelockdelta=20"
    echo ""
    echo "Local Loop server is now running and should respect these limits."
    echo "Test with: ./signet.sh loop getinfo"
  else
    echo "✗ Could not connect to your LND"
    echo "Please check:"
    echo "1. LND is running on localhost:10009"
    echo "2. LND directory path: $LND_DIR"
    echo "3. Macaroon and TLS cert are accessible"
  fi
}

function setup_aperture_config() {
  # Create the aperture config
  write_aperture_config
  
  # Wait for aperture container to be ready and copy config
  echo "Waiting for aperture container..."
  while ! docker exec aperture-signet ls /root/.aperture >/dev/null 2>&1; do
    sleep 2
  done
  
  docker cp /tmp/aperture.yaml aperture-signet:/root/.aperture/aperture.yaml
  
  # Copy your LND TLS cert to aperture
  if [ -f "${LND_DIR}/tls.cert" ]; then
    docker cp "${LND_DIR}/tls.cert" aperture-signet:/root/.aperture/lnd-tls.cert
  fi
  
  # Get aperture TLS cert for loop client
  sleep 5
  docker cp aperture-signet:/root/.aperture/tls.cert /tmp/aperture-tls.cert 2>/dev/null || echo "Aperture TLS cert not ready yet"
  chmod 644 /tmp/aperture-tls.cert 2>/dev/null
  docker cp /tmp/aperture-tls.cert loopclient-signet:/root/.loop/aperture-tls.cert 2>/dev/null || echo "Will copy aperture cert later"
}

function write_aperture_config() {
  rm -rf /tmp/aperture.yaml
  touch /tmp/aperture.yaml && cat > /tmp/aperture.yaml <<EOF
listenaddr: '0.0.0.0:11018'
staticroot: '/root/.aperture/static'
servestatic: true
debuglevel: trace
insecure: false
writetimeout: 0s

servername: aperture
autocert: false

authenticator:
 lndhost: localhost:10009
 tlspath: /root/.aperture/lnd-tls.cert
 macdir: /root/.lnd/data/chain/bitcoin/signet
 network: signet

etcd:
 host: 'localhost:2379'
 user:
 password:

services:
 - name: loop
   hostregexp: '^.*$'
   pathregexp: '^/looprpc.*$'
   address: 'localhost:11009'
   protocol: https
   tlscertpath: /root/.aperture/loopserver-tls.cert
   price: 1000
   authwhitelistpaths:
     - '^/looprpc.SwapServer/LoopOutTerms.*$'
     - '^/looprpc.SwapServer/LoopOutQuote.*$'
     - '^/looprpc.SwapServer/LoopInTerms.*$'
     - '^/looprpc.SwapServer/LoopInQuote.*$'
EOF
}

function status() {
  echo "=== Bitcoin Signet Status ==="
  bitcoin getblockchaininfo || echo "Could not connect to Bitcoin signet"
  echo ""
  echo "=== Your Existing LND Status ==="
  lnd getinfo || echo "Could not connect to your LND"
  echo ""
  echo "=== LND Wallet Balance ==="
  lnd walletbalance || echo "Could not get wallet balance"
  echo ""
  echo "=== LND Channels ==="
  lnd listchannels || echo "Could not list channels"
  echo ""
  echo "=== Loop Server Status ==="
  docker logs loopserver-signet --tail=5 2>/dev/null || echo "Loop server not ready"
  echo ""
  echo "=== Loop Client Status ==="
  loop getinfo || echo "Loop client not ready yet"
}

function stop() {
  $COMPOSE down
}

function logs() {
  $COMPOSE logs -f "$@"
}

case "$1" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  status)
    status
    ;;
  logs)
    shift
    logs "$@"
    ;;
  bitcoin)
    shift
    bitcoin "$@"
    ;;
  lnd)
    shift
    lnd "$@"
    ;;
  loop)
    shift
    loop "$@"
    ;;
  *)
    echo "Usage: $0 {start|stop|status|logs|bitcoin|lnd|loop}"
    echo ""
    echo "Custom Signet Loop Environment"
    echo "Connects to your existing LND with max-cltv-expiry=300"
    echo "Runs LOCAL Loop server that respects your CLTV limits"
    echo ""
    echo "Set LND_DIR environment variable if not in /root/.lnd"
    echo "Example: LND_DIR=/path/to/lnd $0 start"
    exit 1
    ;;
esac 