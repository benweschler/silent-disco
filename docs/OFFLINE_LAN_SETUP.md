# Offline LAN setup and acceptance test

Target: the current Mac on macOS 15.7.5 and an **iPhone 14 Pro Max on iOS 18.6.2**.
This is an experimental manual setup, not a supported hotspot-management API.
The apps never change Internet Sharing, DHCP, firewall, or network services.

## 1. Install before going offline

Build/run the Mac app from this repository and the iPhone app from the sibling
`silent_disco` project. For the physical iPhone, enable Developer Mode if needed,
use the configured Apple development team in Xcode, and install a signed build.
An unsigned `flutter build ios --no-codesign` verifies compilation only; it cannot
be installed directly. Launch the installed app normally after unplugging USB.

Allow Local Network access for both apps. On iOS 18.6.2 this is in Settings →
Privacy & Security → Local Network. On macOS use System Settings → Privacy &
Security → Local Network. Allow the Mac app's incoming connections if the firewall
asks. Do not disable the firewall globally.

## 2. Record existing settings

Take notes/screenshots of System Settings → General → Sharing → Internet Sharing,
including the source/destination and whether it was enabled. In Terminal inspect:

```sh
sw_vers
networksetup -listallhardwareports
networksetup -listnetworkserviceorder
networksetup -listallnetworkservices
ifconfig
netstat -rn
```

Record the Wi-Fi service/interface and current configuration. Do not assume Wi-Fi
is `en0`, the sharing bridge has a particular name, or the LAN uses a particular
subnet. Do not overwrite existing services. If `Silent Disco Offline` already
exists or `10.10.10.1` conflicts with an existing address/route, stop and resolve
that conflict before using the commands below.

## 3. Create the dummy upstream service

Run these commands individually; `sudo` requests administrator authentication:

```sh
sudo networksetup -createnetworkservice "Silent Disco Offline" lo0
sudo networksetup -setmanual "Silent Disco Offline" 10.10.10.1 255.255.255.255
networksetup -getinfo "Silent Disco Offline"
```

After configuration, check `ifconfig lo0` still includes `127.0.0.1`. On this Mac,
the dummy service displaced that standard loopback address. If absent, restore it
alongside the dummy address using `sudo ifconfig lo0 inet 127.0.0.1 netmask 255.0.0.0 alias`.
This repair does not remove 10.10.10.1; verify again after reboot. See AUDIO_TESTING.md.

Confirm the new service exists and has the intended address. A failure is a real
setup failure: do not suppress it, run downloaded scripts, or alter unrelated
loopback configuration to force this experiment to work.

The source for this workaround is the [original setup script](https://gist.github.com/zhuhuilin/01656866b3e73a677a434c21183b40d2).
Apple documents the ordinary [Internet Sharing UI](https://support.apple.com/guide/mac-help/share-internet-connection-mac-network-users-mchlp1540/mac),
but does not guarantee this dummy-upstream configuration.

## 4. Enable sharing manually

1. Keep Mac Wi-Fi on but disconnect it from other Wi-Fi networks.
2. Open System Settings → General → Sharing → Internet Sharing settings.
3. Share your connection from **Silent Disco Offline** to **Wi-Fi**.
4. In Wi-Fi Options use **SilentDisco-Test**, set a password, and use the strongest
   security option offered that both devices support. Record the channel if shown.
5. Enable Internet Sharing. Disconnect other upstream connections; turn off
   Personal Hotspot. Do not change NAT preferences or DHCP ranges.

`10.10.10.1` is the dummy upstream address, **not the address the phone should use**.
Internet Sharing chooses the downstream subnet and acts as DHCP server.

## 5. Join with the phone and prove the path

1. Unplug the phone's USB cable.
2. On the iPhone enable Airplane Mode, then manually reenable Wi-Fi.
3. Join **SilentDisco-Test**. Stay connected if warned that internet is unavailable.
4. In the Wi-Fi network details, leave Configure IP on Automatic and record the IP,
   subnet mask, and router. An absent address or self-assigned `169.254.*` address
   does not prove successful DHCP.
5. Keep the app visible. Start the Mac server; tap **Find hubs / retry**, then
   **Connect** on the phone. Wait for **connected**, meaning TCP and UDP are ready.
6. Enter the recorded details and confirm the offline-setup checkbox in whichever
   app starts the test. The checkbox is a user assertion, not automatic proof.

Bonjour should find the server within 10 seconds after joining and granting
permission. If discovery fails, manual connection takes the Mac's downstream IP
(the phone's router address is a useful candidate) and the TCP port shown on the
Mac. Do not enter the dummy loopback address. The app lists interface addresses
without guessing which interface is Internet Sharing. Manual success isolates a
Bonjour issue but does not count as passing the discovery test.

## 6. Fast acceptance sequence

- Run **Connectivity** (30 seconds). Confirm TCP and echoed UDP counters increase.
- Run **One-channel baseline** once (10 minutes). No profile lasts longer than
  10 minutes. Allow up to five additional seconds for draining/final reporting.
- Initial gates: no disconnect, directional loss below 0.1%, p95 RTT below 50 ms,
  and no receive gap over 250 ms. Preserve a failing report rather than adjusting
  thresholds to make it pass. Sender errors/overruns are recorded separately.
- Use short connectivity runs for Wi-Fi off/on, server restart, permission denial
  and restoration, and lock/unlock. The app should report interruption, never
  resume an old run, and reconnect within 15 seconds once the LAN/server are back.
- Reboot the Mac, manually reenable sharing if necessary, and repeat only the
  30-second test. No second 10-minute run is needed without a new failure/change.
- Export the JSON report from the Mac. The last 20 reports persist in its sandbox's
  Application Support/SilentDiscoDiagnostics/Reports directory.

The optional **Three-channel preview** also lasts 10 minutes. It tests three
synthetic streams to one phone, not ten listeners or audio playback, and is not
required for step 1 acceptance. Phone automatic locking is disabled only during
an active run; manually locking/backgrounding interrupts it. Background audio
comes later.

## 7. Roll back

1. Disable Internet Sharing.
2. If and only if this experiment created `Silent Disco Offline`, remove it:

```sh
sudo networksetup -removenetworkservice "Silent Disco Offline"
```

3. Inspect `ifconfig lo0`. If the `10.10.10.1` alias remains, and your initial notes
   establish that this experiment added it, remove only that alias:

```sh
sudo ifconfig lo0 inet 10.10.10.1 -alias
```

4. Restore the recorded sharing settings, reconnect the usual Wi-Fi/upstream,
   and restore the phone's normal Airplane Mode/cellular state.
5. Confirm normal networking works. Never remove `127.0.0.1`, an existing loopback
   service, or an address not created by this experiment.

If hosting cannot be made to work on this machine, mark offline hosting **blocked**.
The diagnostics apps can still run on an ordinary LAN for debugging, but that is
not evidence that the Mac-hosted offline requirement passed.
