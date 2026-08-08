#!/usr/bin/env bash
# Generates a self-signed cert/key pair for bin/webhook_demo.ml. Not part
# of the library -- X.509 generation needs its own dependency this
# library doesn't otherwise want (see lib/admission.mli), so this is
# deliberately just a shell script wrapping openssl, the same tool anyone
# would reach for by hand.
#
# SAN includes host.docker.internal specifically so a `kind` cluster on
# Docker Desktop can reach a webhook_demo.exe running on the host and
# have TLS hostname verification actually pass -- see "Admission
# webhooks" in the README for the full setup this cert is one piece of.
set -euo pipefail
DIR="${1:-.}"
mkdir -p "$DIR"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$DIR/webhook-key.pem" \
  -out "$DIR/webhook-cert.pem" \
  -days 3650 \
  -subj "/CN=webhook-demo" \
  -addext "subjectAltName=DNS:host.docker.internal,DNS:localhost,IP:127.0.0.1"
echo "wrote $DIR/webhook-cert.pem and $DIR/webhook-key.pem"
