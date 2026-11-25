# R15 M · Link — native iOS BLE app (sideloaded, no Mac needed)

A SwiftUI + CoreBluetooth app that connects to the Yamaha R15 M's BLE module
(`YCCU_0008040003FC92`), authenticates with your cloud-fetched passKey, **holds the
connection in the background** (fixes the Y-Connect drop/reconnect bug), and logs/decodes
telemetry. v0.1 = connect + auth + raw telemetry logger + reconnect.

## How to build it without owning a Mac

The build runs on GitHub's **free macOS cloud runner**. You never touch Xcode.

1. Create a new GitHub repo (private is fine) and push this folder to it
   (or upload the files via the GitHub web UI). Keep the structure:
   ```
   project.yml
   App/…swift, App/Info.plist
   .github/workflows/build.yml
   ```
2. Go to the repo's **Actions** tab → the **Build unsigned IPA** workflow runs on push
   (or click **Run workflow**).
3. When it finishes (~3–4 min), open the run → **Artifacts** → download
   **`R15Link-unsigned-ipa`** → unzip to get `R15Link.ipa`.

## How to install it on your iPhone (from Windows)

Use **Sideloadly** (https://sideloadly.io) or **AltStore** — both run on Windows.

1. Install Sideloadly on your PC, connect the iPhone by USB, trust the computer.
2. Drag `R15Link.ipa` into Sideloadly, enter your **Apple ID** (a free one works).
3. Click **Start**. First launch: on the iPhone go to
   **Settings → General → VPN & Device Management → [your Apple ID] → Trust**.
4. Open the app, tap **Connect & Authenticate** with the bike awake and nearby.

Notes:
- Free Apple ID → the app stops working after **7 days** and must be re-installed.
  **AltStore** can auto-refresh it over WiFi while your PC is on. A paid Apple Developer
  account ($99/yr) makes it last a year.
- Credentials are pre-filled (ccuId `0008040003FC92`, passKey `447848`); change them in
  the app's **gear → Settings** if needed, and pick the passKey encoding there.

## First-run test (important)

The application-layer auth frame is reverse-engineered as:
`01 01` (opcode) + ccuId (7 bytes) + passKey. The one thing to confirm on real hardware is
the transport framing. On the first connection, watch the **log** (and tap it to copy) —
the bike's response to the AUTH frame tells us if it's accepted. Send that log back to tune
the protocol and start decoding the `LocalId` telemetry (speed, distance, location, etc.).
