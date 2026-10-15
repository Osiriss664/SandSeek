# Safety test

A test of the web sandbox that runs by itself, with nobody at the keyboard, plus
a short list of checks a person does by hand. It looks at a sandbox that is
running and tries what an attacker, or a mistake, could try. It is evidence, not
proof: see [SECURITY.md](SECURITY.md) for what the sandbox promises.

## Run it

```sh
Scripts/full_test.sh --safety        # the whole run, with the safety test before the final stop
Scripts/safety_probe.sh              # only the probe, against a sandbox that is already running
Scripts/safety_lifecycle.sh          # only the fake sandbox and lifecycle parts (starts its own sandbox)
```

Nothing asks for input, a password or a click. `SKIP_PORT_SCAN=1` skips the scan
of every port of the Mac, which is the longest part. `SKIP_FAKE_SANDBOX=1` and
`SKIP_LIFECYCLE=1` skip the parts of `safety_lifecycle.sh`. A full run takes
roughly 6 to 12 minutes on an M-series Mac. Each script prints PASS, FAIL, NOTE
and SKIP lines and ends with `Result: N pass, M fail`; it exits 0 only with no
FAIL. In `full_test.sh` the lines are in `report.md` under "Safety test". The
sandbox's secret is never printed.

## What each part proves

**Probe (`safety_probe.sh`, nothing is changed)**

- *Mac side:* one sandseek VM; the port is bound to 127.0.0.1 only; an unsigned
  request gets 401, a foreign `Host` 403, a browser-style POST and a CORS
  preflight are refused and no CORS header is sent; the secret file is 0600 in a
  0700 folder; the secret is on no process command line and not in
  `container inspect`.
- *Firewall, read inside the VM:* input and output policy drop; inbound only the
  server's port from the gateway; the blocked sets and the private ranges are
  rejected; the DNS exception covers only the name servers in `resolv.conf`; no
  other accept rule. Every address the Mac has now is in the blocked sets or
  covered by a range rule.
- *Reachability as the server's user:* a public connection and a name lookup
  work first (otherwise the refusals mean nothing); then the gateway on common
  ports and on the published port, private, shared and metadata addresses, and
  every address of the Mac on port 80 are refused; then a scan of all TCP ports
  of the Mac finds none.
- *Privileges:* the server runs as an unprivileged user with no capabilities and
  NoNewPrivs; no unexpected root process; `nft` is refused for that user; a
  user-namespace attempt to flush the firewall leaves it in place; `/app` is
  not writable.
- *Hostile requests through the signed API:* private, loopback, link-local,
  IPv4-mapped, NAT64, 6to4 and Teredo addresses, the gateway and each Mac
  address, credentials in the address, other schemes and ports are refused with
  the right error code; a redirect to a private address is refused when a public
  redirect service answers.

**Fake sandbox (`safety_lifecycle.sh`).** The sandbox is stopped and a program
that is not the sandbox answers on its port, first with an unsigned `/health`
body and then with one signed by a wrong key. The `sandseek` command must refuse
it with a plain error, print no answer and send no question.

**Lifecycle (`safety_lifecycle.sh`).** A second `start` is refused with the busy
message and leaves the first sandbox alone. After `kill -9` of the lock holder
the next `start` removes the left VM and files and comes up with exactly one VM.
After `stop` there is no VM, no secret, port, vm-name or blocked-addresses file,
no lock holder and nothing on the old port.

## Skipped, and why

- *Oversize or compressed page:* the server has no test hook for it (its limits
  come from the image), so this is only covered by `Sandbox/test_server.py`.
- *Redirect check:* needs the internet and a public redirect service; it is
  skipped with a note when none answers.
- *Fake sandbox:* skipped when the `sandseek` command is not built.
- `/v1/search` takes text, not an address, so address forms go to `/v1/fetch`.

## Known and accepted limits

- DNS goes through the Mac when the Mac is the VM's name server; port 53 of the
  Mac is the one open port, and the Mac sees looked-up names.
- The VM can reach every public address; search terms and visited sites leave
  the Mac.
- An address the Mac gains after the sandbox starts (a rotated temporary IPv6
  address, a VPN) is not in the blocked sets until the next start. The probe
  reports it as a FAIL; stop and start the sandbox and run it again. The bridge
  address the Mac gets while the VM runs is private and already refused.
- A host on your network with a global IPv6 address is reachable if the VM has
  IPv6; the probe says whether it does.
- The secret is readable inside the VM. It protects against other programs on
  the Mac, not against code that took over the server.
- Any program on the Mac can reach the sandbox's loopback port; it needs the
  secret to be served.

## By hand (not automated)

Do these when the app changes, with a person at the keyboard.

1. **App-started VM:** start the sandbox with the app's Start button, keep the
   app running, and run `Scripts/safety_probe.sh` in a terminal. It should give
   the same result as for a sandbox started by script.
2. **Fake sandbox while the app is open:** with the app's sandbox ready, run
   `container stop <VM name>` (the name is in `container list`), then start
   `python3 -m http.server <port> --bind 127.0.0.1` on the same port. Ask a
   question that needs the web. The app must show a sandbox error, no answer
   built from a page, and the sandbox card must not say Ready. Stop the fake
   program and ask again: a fresh sandbox starts and answers.
3. **Quit and force quit:** press Cmd-Q; within a few seconds no sandseek VM and
   no secret file should remain. Start the sandbox again, force quit the app
   (Activity Monitor), then relaunch and click Start Sandbox: the old VM is
   removed at that start (not when the app opens) and exactly one new one runs.
