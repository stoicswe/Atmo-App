# Wallet pass signing material

The app signs profile passes on the device with a Pass Type ID
certificate. Three PEM files live here; the whole folder is copied into
the app bundle as `WalletPass/Signing/`.

| File | Committed | What |
|------|-----------|------|
| `AppleWWDRCAG4.pem` | yes | Apple's WWDR G4 intermediate (public; expires 2030-12-10). |
| `pass.pem` | **no** (gitignored) | Your Pass Type ID certificate. |
| `pass-key.pem` | **no** (gitignored) | Its RSA private key. |

Without `pass.pem` and `pass-key.pem` the build has no signer: release
builds hide "Add to Apple Wallet"; debug builds show it disabled.

## One-time setup

`Scripts/wallet-pass-cert.sh` does the openssl work (Keychain Access
works too, but its `.p12` export is greyed out unless the certificate
is paired with the key under *My Certificates*, which is easy to lose).

1. Developer portal → Certificates, IDs & Profiles → Identifiers → **+**
   → Pass Type IDs. Register one (e.g. `pass.stoicswe.atmo`). The
   identifier and team are read from the certificate at runtime, so the
   value itself doesn't appear in code.
2. `Scripts/wallet-pass-cert.sh request` — writes `pass-key.pem` and a
   signing request, `pass.csr`.
3. Open the Pass Type ID → Create Certificate, upload `pass.csr`, and
   download the `.cer` it issues.
4. `Scripts/wallet-pass-cert.sh install ~/Downloads/pass.cer` — converts
   it to `pass.pem`, checks it matches the key, and prints the Pass Type
   ID, team, and expiry the app will read.
5. Build. `Scripts/wallet-pass-cert.sh status` shows the state at any
   time. The certificate is valid for about a year; when it expires,
   repeat steps 3–4 (the key can stay — existing passes keep working).

If you do have a paired certificate in Keychain Access, export it as
`pass.p12` and split it instead:

```sh
openssl pkcs12 -in pass.p12 -clcerts -nokeys -out Resources/WalletPass/Signing/pass.pem
openssl pkcs12 -in pass.p12 -nocerts -nodes  -out Resources/WalletPass/Signing/pass-key.pem
```

(`-nodes` leaves the key unencrypted — the app can't prompt for a
passphrase. If LibreSSL refuses the `.p12`, add `-legacy` or use
Homebrew's OpenSSL.)

Refresh the intermediate when Apple rotates it:
`Scripts/wallet-pass-cert.sh wwdr`.

The key shipping in the app means it can be extracted; all it can sign
is passes under this Pass Type ID, and the certificate can be revoked
and reissued from the portal at any time.
