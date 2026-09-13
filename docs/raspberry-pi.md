# Raspberry Pi / home-server deployment

Target: **Raspberry Pi 4, 8 GB, Raspberry Pi OS Lite 64-bit**, CPU-only
llama.cpp. **Not tested on physical Raspberry Pi hardware.** This is a manual
starting procedure, not a validated performance claim. Keep issue #5 open until
the hardware checklist below has recorded evidence. Other Linux home servers
can adapt the paths/account and build natively; their results are separate.

Nothing here provisions cloud infrastructure, changes disk layouts, or runs an
unattended installer. Review commands before running them. Only the explicitly
marked administrator steps need sudo. Do not run inference as root.

## 1. Prepare the host

Use your existing Raspberry Pi OS Lite **64-bit** installation and an SSH-enabled
administrative login. Keep OS security updates maintained through your normal
administration process. Check `uname -m` reports `aarch64` and
`getconf LONG_BIT` reports `64` before building.

Raspberry Pi's official getting-started guidance specifies **5 V / 3 A** power
for Pi 4. Use an appropriate quality supply and cooling; USB storage also needs
power budget. Start with a heatsink/fan and monitor temperature and throttling
under sustained load rather than assuming a successful boot proves stability.
Have sufficient free space for source, build outputs and the selected GGUF; do
not fill the OS card. An SSD is an option, not a requirement. Do not enlarge swap
as a substitute for choosing a smaller model.

Administrator steps (skip account creation if already configured):

```sh
sudo apt-get update
sudo apt-get install build-essential cmake git curl ca-certificates libssl-dev
sudo adduser --disabled-password --gecos '' swapai
sudo -iu swapai
```

`swapai` needs no sudo-group membership. The examples assume its home is
`/home/swapai`. Keep an independent administrative SSH login; the service account
need not accept SSH connections. All commands in sections 2–3 run in that
non-root account's shell.

## 2. Install SwapAI and build llama.cpp

Use a reviewed SwapAI checkout at `/home/swapai/src/SwapAI` (clone it or copy your
reviewed tree there). The installer writes only the user's local directories;
inspect it first and do not use sudo. Existing local installations can be
replaced by this installer, so preserve your previous version if needed.

```sh
mkdir -p "$HOME/src" "$HOME/models" "$HOME/deployment-records"
cd "$HOME/src"
git clone https://github.com/wuisabel-gif/SwapAI.git
cd SwapAI
git rev-parse HEAD
git status --short
./install.sh
export PATH="$HOME/.local/bin:$PATH"
swapai init

cd "$HOME/src"
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
git rev-parse HEAD
cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_CUDA=OFF -DGGML_VULKAN=OFF -DGGML_BLAS=OFF
cmake --build build --config Release --target llama-server -j 2
./build/bin/llama-server --version
./build/bin/llama-server --help > "$HOME/deployment-records/llama-server-help.txt"
```

For repeat deployments, check out the **recorded exact commit** before building,
not a moving branch. Build on the Pi: do not copy a native x86 or Pi 5 binary.
Two build jobs are a conservative starting choice; reduce to `-j 1` if memory is
tight. No GPU or BLAS setup is required. The upstream CPU build uses CMake;
`BUILD_SHARED_LIBS=OFF` avoids depending on separately installed llama shared
libraries (it does not make all system dependencies static). Current upstream
uses OpenSSL development libraries for optional HTTPS support; do not copy old
`LLAMA_CURL` build flags. Inspect the help from **your pinned build** if any
option below is rejected. See official sources at the end.

## 3. Select a small model and configure the CPU profile

Tentative starting range: **roughly 0.5–1.5B parameters, GGUF Q4 quantization**,
preferably a chat/instruct model supported by your llama.cpp revision. This is
not a benchmark or a guarantee of useful speed, accuracy, or memory fit. Start
at the smaller end. Download manually from a publisher you trust, review its
license and model card, and record repository/revision, exact filename, size
and SHA-256. Q4 is not a total RAM budget: context/KV cache, working buffers and
the OS need memory too. Do not start with a 7B model or concurrent users.

Place the selected file at `/home/swapai/models/pi-model-q4.gguf` (this is a
local example filename, not a downloadable model ID). Keep paths and profile
arguments free of spaces: SwapAI extra arguments use whitespace splitting, not
shell quote interpretation. Do not put `--host` or `--port` in extra arguments:
these could override SwapAI's loopback settings.

```sh
export SWAPAI_LLAMA_SERVER="$HOME/src/llama.cpp/build/bin/llama-server"
export SWAPAI_HOST=127.0.0.1
export SWAPAI_PORT=11435
export SWAPAI_CONFIG_HOME="$HOME/.config/swapai"
export SWAPAI_STATE_HOME="$HOME/.local/state/swapai"
export SWAPAI_START_TIMEOUT=300
export SWAPAI_STOP_TIMEOUT=15
sha256sum "$HOME/models/pi-model-q4.gguf"
swapai add pi-cpu llamacpp "$HOME/models/pi-model-q4.gguf" \
  --n-gpu-layers 0 --threads 3 --threads-batch 3 \
  --ctx-size 1024 --batch-size 128 --ubatch-size 64 --parallel 1 --n-predict 128
swapai doctor
swapai switch pi-cpu
swapai status
swapai endpoint
curl --fail --max-time 10 http://127.0.0.1:11435/v1/models
```

These are deliberately modest trial settings, not tuned Pi results. Use short
prompts and bounded output. If `pi-cpu` already exists, edit that TSV row instead
of adding it again. `swapai init` also provides example profiles; do not switch
to an unrelated large model accidentally. Keep this environment in your shell
when managing manually; the service below sets the same values explicitly.

## 4. Client access without exposing the API

Keep the server bound to **127.0.0.1**, not `0.0.0.0`. This example configures no
API authentication or TLS. Do not forward the API port on a router, publish it
to the internet, or open a LAN firewall rule for it. Local host users can access
the loopback API; use a trusted host and protect model/config/state permissions.

On your laptop, use your administrative SSH account and actual Pi hostname:

```sh
ssh -N -T -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:11435:127.0.0.1:11435 admin@pi-host
```

Keep that connection open. Configure the client base URL as
`http://127.0.0.1:11435/v1`; obtain its model ID from `/v1/models`, not the SwapAI
profile name. If the client insists on an API key, a placeholder is not server
security. If laptop port 11435 is occupied, use local port 11436 on the left of
`-L` and update the client URL; leave the remote port unchanged.

In a second laptop terminal (replace MODEL_ID with the returned ID):

```sh
curl --fail --max-time 10 http://127.0.0.1:11435/v1/models
curl --fail --max-time 300 http://127.0.0.1:11435/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"MODEL_ID","messages":[{"role":"user","content":"Say hello in one sentence."}],"max_tokens":32,"stream":false}'
```

## 5. Optional systemd boot service

The repository includes `examples/systemd/swapai.service`. It is **opt-in** and
is not installed by `install.sh`. Review every path and environment setting
before copying. First stop the manually started process **as swapai**:

```sh
swapai stop
exit
```

The following commands run from your administrative login:

```sh
sudo systemd-analyze verify /home/swapai/src/SwapAI/examples/systemd/swapai.service
sudo install -m 0644 /home/swapai/src/SwapAI/examples/systemd/swapai.service /etc/systemd/system/swapai.service
sudo systemctl daemon-reload
sudo systemctl enable --now swapai.service
systemctl status swapai.service
sudo journalctl -u swapai.service -b --no-pager
sudo -iu swapai /home/swapai/.local/bin/swapai status
sudo -iu swapai /home/swapai/.local/bin/swapai logs
ss -ltnp 'sport = :11435'
```

Those read-only CLI calls use the dedicated account's default config/state
paths, which match the unit. If you customize paths, pass the same explicit
`SWAPAI_CONFIG_HOME` and `SWAPAI_STATE_HOME` with `env` after `sudo -iu swapai`;
do not rely on your administrative shell's environment being preserved.

Expect a loopback listener and `active (exited)`: `swapai switch` starts a
`nohup` child, writes its PID/state, checks readiness, then exits. Thus the unit
uses **Type=oneshot + RemainAfterExit**, not `Type=simple`. `ExecStop` invokes
SwapAI's graceful TERM/15-second/KILL shutdown; `KillMode=control-group` also
cleans up remaining service children. The systemd startup timeout leaves room
for SwapAI readiness iterations (each can include both a curl timeout and a
sleep). Runtime output is in `/home/swapai/.local/state/swapai/runtime.log`;
the journal contains lifecycle output. Runtime log content is replaced on each
start, so save relevant diagnostics before restarting.

**This unit does not supervise backend crashes or automatically restart them.**
After a backend dies, systemd can still show `active (exited)`. Check both
`swapai status` and `/v1/models`; inspect logs/memory/power before manually
recovering with `sudo systemctl restart swapai.service`. Do not add
`Restart=always` to a oneshot unit or mistake service activation for ongoing
health. Automatic crash recovery requires a separately designed supervisor.

While enabled, use `systemctl stop/start/restart swapai` for lifecycle changes.
Do not concurrently issue manual `swapai switch`, `run`, or `stop` against the
same state directory: the unit and CLI would disagree on ownership, and service
cleanup can kill a manually switched child. To change profiles, stop the unit,
edit the configuration and/or ExecStart, run daemon-reload if the unit changed,
then start it. Do not share this account's state directory with another service.

To opt out without deleting models or user configuration:

```sh
sudo systemctl disable --now swapai.service
```

## 6. Record versions and diagnose resource limits

As `swapai`, save this output alongside results; redact host/user information
before publishing. Record the original OS image release as well as installed
OS/kernel versions. No physical-Pi results are supplied by this PR.

```sh
{
  date -u '+%Y-%m-%dT%H:%M:%SZ'
  cat /etc/os-release
  uname -a
  getconf LONG_BIT
  cat /proc/device-tree/model; printf '\n'
  lscpu
  cmake --version
  c++ --version
  systemctl --version
  git -C "$HOME/src/SwapAI" rev-parse HEAD
  git -C "$HOME/src/SwapAI" status --short
  git -C "$HOME/src/llama.cpp" rev-parse HEAD
  git -C "$HOME/src/llama.cpp" status --short
  "$HOME/src/llama.cpp/build/bin/llama-server" --version
  sha256sum "$HOME/models/pi-model-q4.gguf"
  ls -lh "$HOME/models/pi-model-q4.gguf"
  cat "$HOME/.config/swapai/profiles.tsv"
} > "$HOME/deployment-records/versions.txt" 2>&1
cp "$HOME/src/llama.cpp/build/CMakeCache.txt" "$HOME/deployment-records/"
free -h
swapon --show
df -h "$HOME"
vmstat 1 10
vcgencmd measure_temp
vcgencmd get_throttled
cat /sys/class/thermal/thermal_zone0/temp
ps -o pid,etime,%cpu,%mem,rss,args -p "$(cat "$HOME/.local/state/swapai/runtime.pid")"
```

Run temperature/throttling/memory checks before and during load. The sysfs
thermal value is in millidegrees Celsius; RSS from `ps` is in KiB. A nonzero
`get_throttled` result may include historical events: preserve the raw hex value
and decode against official Raspberry Pi documentation rather than treating all
bits as current faults. If `vcgencmd` is missing or inaccessible, record that
fact and use the OS diagnostics; do not grant broad device/root access to the
service solely for monitoring. From the admin account, inspect kernel messages:

```sh
sudo journalctl -k -b --no-pager | grep -Ei 'voltage|thrott|thermal|oom|out of memory|killed process'
```

An empty grep result is not proof of adequate power or memory. For OOM, heavy
swap activity or an unresponsive host, stop inference, choose a smaller model
and/or context, and retry one request at a time. For thermal/power events, fix
supply/cooling before tuning threads. For illegal instructions, verify the
native architecture/build revision. For startup failure, inspect `swapai logs`,
GGUF compatibility/readability, free RAM and `ss`; do not keep raising timeouts
to hide a runtime that is crashing. Preserve logs before recovery.

## 7. Physical hardware acceptance checklist and results template

Copy this section into issue #5 and replace **NOT RUN** with measured evidence.
Never report mock tests or a successful CMake configure as Pi hardware testing.

| Check | Result / evidence |
| --- | --- |
| Physical Pi 4 8 GB, OS Lite 64-bit boot and architecture | NOT RUN |
| Date, OS image/release, kernel, compiler/CMake/systemd versions | NOT RUN |
| Exact SwapAI + llama.cpp commits and dirty diffs, CMakeCache | NOT RUN |
| Model publisher/revision/license/filename/bytes/SHA-256/quantization | NOT RUN |
| PSU rating/model, cooling, storage and attached USB devices | NOT RUN |
| Native build succeeds; version/help output archived | NOT RUN |
| Profile flags, free RAM/swap/disk before startup | NOT RUN |
| Cold startup time and `/v1/models` readiness | NOT RUN |
| Short 32-token request succeeds locally and through SSH tunnel | NOT RUN |
| Listener only on loopback; LAN cannot connect directly | NOT RUN |
| Idle/load temperature, raw throttling flags, RSS and vmstat samples | NOT RUN |
| Sustained sequential short requests (record count and duration) | NOT RUN |
| Prompt/output token counts, latency and throughput if measured | NOT RUN |
| Clean systemctl stop releases process and port; restart works | NOT RUN |
| Optional enabled-service reboot test and SSH reconnect | NOT RUN |
| Controlled backend crash: stale active(exited) understood; manual recovery | NOT RUN |
| Kernel OOM/power/thermal messages and failures attached | NOT RUN |

For a crash test, use only this dedicated idle test instance: identify and
confirm the runtime PID from its state file and process listing before manually
sending TERM, check actual API failure despite the unit state, then restart via
systemctl. Do not kill an arbitrary port owner. Reboots and failure injection
are optional operator actions, not automated tests in this repository.

Report exact prompts, client parameters, warm versus cold runs and sample count
for any timing. `swapai benchmark` can provide comparative observations but
runs two requests; inspect its saved responses and use identical workloads.
Its TTFT field uses curl start-transfer timing, not verified first-token timing.
The profile sets a 128-token generation default; clients should still request
explicit output limits. Benchmark requests have no built-in curl timeout: on
the Pi use `timeout 300 swapai benchmark 'Say hello briefly'` from the configured
service account shell, and record timeouts as failures rather than throughput.
No tokens-per-second, maximum model size or uptime promise is made here.
Hardware acceptance remains pending until the evidence above is collected.

## Official references

Consult the docs at the **checked-out llama.cpp revision** as well as upstream:

- Raspberry Pi getting started (power and setup):
  `https://www.raspberrypi.com/documentation/computers/getting-started.html`
- Raspberry Pi hardware/monitoring documentation:
  `https://www.raspberrypi.com/documentation/computers/os.html`
- llama.cpp CPU build and dependencies:
  `https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md`
- llama-server flags and API:
  `https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md`
- systemd service lifecycle and kill behavior (also `man systemd.service` and
  `man systemd.kill` on the host):
  `https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html`
  `https://www.freedesktop.org/software/systemd/man/latest/systemd.kill.html`
