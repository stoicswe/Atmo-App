#!/bin/sh
# Manages the Pass Type ID signing material the app uses to build Wallet
# profile passes on the device (Resources/WalletPass/Signing/, gitignored
# except Apple's intermediate). Uses only openssl — no Keychain Access.
#
#   Scripts/wallet-pass-cert.sh request [--force]
#       Makes pass-key.pem (RSA 2048) and a signing request, pass.csr, to
#       upload in the developer portal (Identifiers → Pass Type IDs →
#       your ID → Create Certificate). Won't overwrite an existing key
#       without --force.
#   Scripts/wallet-pass-cert.sh install <pass.cer>
#       Converts the certificate the portal issued into pass.pem, checks
#       it matches the key, and shows what the app will read from it.
#   Scripts/wallet-pass-cert.sh status
#       What's in place, whether the pair matches, and expiry dates.
#   Scripts/wallet-pass-cert.sh wwdr
#       Refreshes Apple's WWDR G4 intermediate (public, committed).
set -e
cd "$(dirname "$0")/.."

DIR=Resources/WalletPass/Signing
KEY=$DIR/pass-key.pem
CERT=$DIR/pass.pem
CSR=$DIR/pass.csr
WWDR=$DIR/AppleWWDRCAG4.pem
WWDR_URL=https://www.apple.com/certificateauthority/AppleWWDRCAG4.cer

die() { echo "error: $*" >&2; exit 1; }

# Public-key digest, so a certificate and a key can be compared.
cert_pub() { openssl x509 -in "$1" -noout -pubkey 2>/dev/null | openssl sha256 | awk '{print $NF}'; }
key_pub()  { openssl rsa  -in "$1" -pubout 2>/dev/null | openssl sha256 | awk '{print $NF}'; }

subject_field() {
    # $1 cert, $2 attribute (UID / OU) — the app reads the Pass Type ID
    # from UID and the team from OU.
    openssl x509 -in "$1" -noout -subject -nameopt sep_multiline,utf8 2>/dev/null \
        | awk -v k="$2" -F'=' '$1 ~ "^ *"k"$" { sub(/^[^=]*=/, ""); print; exit }'
}

cmd_request() {
    mkdir -p "$DIR"
    if [ -f "$KEY" ] && [ "$1" != "--force" ]; then
        die "$KEY already exists. Reuse it (just run 'install' on a new .cer) or pass --force to replace it — existing passes stay valid either way."
    fi
    umask 077
    openssl genrsa -out "$KEY" 2048 2>/dev/null
    openssl req -new -key "$KEY" -out "$CSR" -subj "/CN=Atmo Wallet Pass/O=Atmo" 2>/dev/null
    umask 022
    echo "Wrote $KEY and $CSR."
    echo
    echo "Next: developer portal → Certificates, IDs & Profiles → Identifiers →"
    echo "Pass Type IDs → your ID → Create Certificate → upload $CSR."
    echo "Download the .cer it issues, then:"
    echo
    echo "    Scripts/wallet-pass-cert.sh install ~/Downloads/pass.cer"
}

cmd_install() {
    src=$1
    [ -n "$src" ] || die "usage: $0 install <pass.cer>"
    [ -f "$src" ] || die "no such file: $src"
    [ -f "$KEY" ] || die "no $KEY — run 'request' first (the certificate must be issued for that key)."
    mkdir -p "$DIR"
    tmp=$(mktemp)
    # The portal hands out DER; accept PEM too.
    if ! openssl x509 -inform der -in "$src" -out "$tmp" 2>/dev/null; then
        openssl x509 -inform pem -in "$src" -out "$tmp" 2>/dev/null || die "$src isn't a DER or PEM certificate."
    fi
    if [ "$(cert_pub "$tmp")" != "$(key_pub "$KEY")" ]; then
        rm -f "$tmp"
        die "that certificate wasn't issued for $KEY. Upload $CSR in the portal and install the certificate it returns (or 'request --force' for a fresh pair and re-issue)."
    fi
    mv "$tmp" "$CERT"
    chmod 644 "$CERT"
    rm -f "$CSR"
    echo "Installed $CERT."
    show_cert
    [ -f "$WWDR" ] || { echo; echo "Apple's intermediate is missing — fetching."; cmd_wwdr; }
}

show_cert() {
    passtype=$(subject_field "$CERT" UID)
    team=$(subject_field "$CERT" OU)
    expires=$(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2)
    echo "  Pass Type ID: ${passtype:-MISSING (the app needs UID in the subject)}"
    echo "  Team:         ${team:-MISSING (the app needs OU in the subject)}"
    echo "  Expires:      $expires"
    [ -n "$passtype" ] && [ -n "$team" ] || echo "  This doesn't look like a Pass Type ID certificate from Apple's portal." >&2
}

cmd_status() {
    ok=1
    if [ -f "$KEY" ]; then echo "key:          $KEY"; else echo "key:          missing (run 'request')"; ok=0; fi
    if [ -f "$CSR" ]; then echo "request:      $CSR (upload it in the portal, then 'install' the .cer)"; fi
    if [ -f "$CERT" ]; then
        echo "certificate:  $CERT"
        show_cert
        if [ -f "$KEY" ]; then
            if [ "$(cert_pub "$CERT")" = "$(key_pub "$KEY")" ]; then
                echo "  Key match:    yes"
            else
                echo "  Key match:    NO — the app will fail to sign; re-run 'install' with the right .cer"; ok=0
            fi
        fi
    else
        echo "certificate:  missing (run 'request', then 'install')"; ok=0
    fi
    if [ -f "$WWDR" ]; then
        echo "intermediate: $WWDR (expires $(openssl x509 -in "$WWDR" -noout -enddate | cut -d= -f2))"
    else
        echo "intermediate: missing (run 'wwdr')"; ok=0
    fi
    echo
    if [ "$ok" = 1 ]; then
        echo "Ready: the app can sign Wallet passes."
    else
        echo "Not ready: release builds hide Add to Apple Wallet; debug builds show it disabled."
        exit 1
    fi
}

cmd_wwdr() {
    mkdir -p "$DIR"
    tmp=$(mktemp)
    curl -sSL -o "$tmp" "$WWDR_URL" || die "couldn't download $WWDR_URL"
    openssl x509 -inform der -in "$tmp" -out "$WWDR" || die "downloaded file isn't a DER certificate"
    rm -f "$tmp"
    echo "Wrote $WWDR (expires $(openssl x509 -in "$WWDR" -noout -enddate | cut -d= -f2))."
}

case "$1" in
    request) shift; cmd_request "$@" ;;
    install) shift; cmd_install "$@" ;;
    status)  cmd_status ;;
    wwdr)    cmd_wwdr ;;
    *) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 1 ;;
esac
