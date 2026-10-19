# Local coding models on vLLM (rootless Podman + systemd)

Serves 30B-class coding models as an OpenAI-compatible endpoint on
`127.0.0.1:8000` for use with opencode.

Target host: Gentoo with systemd, single RTX 5090 (32GB, Blackwell sm_120).

- **llama-swap** (`llama-swap/`) — request-driven switching. opencode's `model`
  field selects the backend and llama-swap starts it. Use this day to day.


## Why vLLM and not Ollama

Ollama cannot pass `chat_template_kwargs`, which is how GLM-4.7-Flash's
Preserved Thinking mode is enabled. Z.ai's model card lists that mode as
required for multi-turn agentic tasks — without it the model re-derives its
reasoning every turn from a transcript with the reasoning stripped out, which
shows up as skipped verification and premature exit from the agent loop.

Ollama also silently evicts old context when the window overflows, rather than
erroring, so the task description can disappear mid-session without any signal.

SGLang is not an option here: it fails three ways on Blackwell with this model
(NVFP4 produces garbage, AWQ crashes on an MLA bug, FP16 OOMs at ~31GB).

## One-time host setup

```bash
sudo emerge -av app-containers/podman app-containers/nvidia-container-toolkit
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# rootless prerequisite - Gentoo does not always create these
grep "$USER" /etc/subuid /etc/subgid \
  || sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate

mkdir -p ~/.cache/huggingface ~/.cache/vllm
```

Confirm GPU passthrough before going further:

```bash
podman run --rm --device nvidia.com/gpu=all \
  docker.io/vllm/vllm-openai:glm5 nvidia-smi
```

## On the image version

The unit pins `vllm/vllm-openai:v0.29.0`, a stable release.

This used to require the nightly `vllm/vllm-openai:glm5` image, because the
model's `glm4_moe_lite` architecture needs transformers 5.x while vLLM pinned
`transformers < 5`. vLLM 0.28.0 bumped that requirement to transformers 5.15.0
as a breaking change, which resolved it. Released vLLM now deprecates
transformers v4 entirely.

The plain `v0.29.0` tag is built against CUDA 13.0, which requires a recent
driver. If `nvidia-smi` reports an older CUDA version, use
`v0.29.0-cu129` instead.

Version tags are effectively immutable, so digest pinning is optional here. If
you want it anyway:

```bash
podman pull docker.io/vllm/vllm-openai:v0.29.0
podman inspect --format='{{index .RepoDigests 0}}' docker.io/vllm/vllm-openai:v0.29.0
```

## Install and start

### Quadlet units

```bash
mkdir -p ~/.config/containers/systemd
cp *.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start glm-flash
journalctl --user -u glm-flash -f
```

Nemotron additionally needs its reasoning parser fetched to the host first, or
vLLM exits at startup:

```bash
mkdir -p ~/.cache/vllm-parsers && cd ~/.cache/vllm-parsers
wget https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16/resolve/main/nano_v3_reasoning_parser.py
```

### llama-swap

Installed from a Portage overlay. Confirm where the binary landed and whether the
ebuild shipped its own system unit:

```bash
command -v llama-swap && llama-swap --version
qlist -v <category>/llama-swap          # portage-utils; or `equery files` from gentoolkit
```

If `command -v` reports something other than `/usr/bin/llama-swap`, correct
`ExecStart=` in the unit. If the ebuild installed a **system** unit, leave it
disabled — the unit here is a **user** unit on purpose, because the spawned vLLM
containers must run as your user to get rootless podman, the HF cache under your
home, and `video` group membership for `/dev/nvidia*`.

```bash
mkdir -p ~/.config/llama-swap ~/.config/systemd/user
cp llama-swap/config.yaml ~/.config/llama-swap/
cp llama-swap/llama-swap.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user start llama-swap
```

Edit the `/home/myung` paths in `config.yaml` if your user differs — llama-swap
does not expand `$HOME` or systemd specifiers. Then:

```bash
curl -s localhost:8000/v1/models | jq -r '.data[].id'   # all four, none loaded yet
```

Requesting any of them loads it on demand. Stop llama-swap before starting a
Quadlet unit; they collide on port 8000 by design, and the `Conflicts=` lines make
systemd enforce it in both directions once all units are installed.

First boot downloads ~17GB of weights and compiles the model graph, so expect a
long wait. `TimeoutStartSec=1800` accounts for it.

The unit is **manual-start only** — it has no `[Install]` section, so nothing
brings it up at boot. Start and stop it yourself:

```bash
systemctl --user start glm-flash
systemctl --user stop glm-flash
```

Do **not** run `systemctl --user enable` — Quadlet-generated units cannot be
enabled. If you later want autostart, uncomment the `[Install]` section in the
`.container` file, run `daemon-reload`, and add `loginctl enable-linger "$USER"`
so your user session's systemd instance persists across logout.

Do not use `podman stop` either. `Restart=always` will bring the container
back; systemd owns the lifecycle.

## Verify

```bash
curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"glm-4.7-flash","messages":[{"role":"user","content":"What is 17*23?"}]}' \
  | jq '.choices[0].message | {reasoning_content, content}'
```

A populated `reasoning_content` means `--default-chat-template-kwargs` landed.
If it is `null`, Preserved Thinking is not active and everything downstream is
pointless — fix that before wiring up opencode.

Then copy `opencode.json` to your opencode config location.

## Day to day

llama-swap path — the service stays up and the models come and go under it:

```bash
systemctl --user status llama-swap
journalctl --user -u llama-swap -f            # swap decisions and lifecycle
podman logs -f vllm-glm-flash                 # the model's own vLLM output
curl -s localhost:8000/running | jq           # what is loaded right now
curl -sX POST localhost:8000/api/models/unload # free VRAM without stopping llama-swap
```

`journalctl` on `llama-swap` shows routing and start/stop; the vLLM startup
milestones and KV cache numbers are in `podman logs` for the model container,
since llama-swap does not own that output. Container names are `vllm-glm-flash`,
`vllm-qwen3-coder`, `vllm-nemotron`, `vllm-gemma4`.

## Configuration notes

**Preserved Thinking** is set server-side via `--default-chat-template-kwargs`
so opencode keeps sending plain OpenAI requests. `clear_thinking:false` is the
part that retains reasoning blocks across turns. Setting it client-side would
require smuggling a non-standard field through `extra_body`.

**Parsers.** GLM-4.7 uses `--tool-call-parser glm47` (changed from `glm4_moe`)
with `--reasoning-parser glm45`. A wrong tool-call parser produces malformed
calls that degrade into prose, which ends the agent loop early.

**Sampling** follows Z.ai's published eval settings for SWE-bench and Terminal
Bench: temperature 0.7, top-p 1.0. `repetition_penalty` is explicitly 1.0 —
vLLM already defaults to that, but Ollama's 1.1 default actively suppresses
verification steps and repeated JSON tool scaffolding, so it is pinned here to
document the intent.

**Quantization.** 4-bit is mandatory, not an optimization. At 31B parameters
the weights are ~62GB at native BF16 and ~31GB at FP8 — the latter technically
almost fits a 32GB card but leaves nothing for KV cache. AWQ 4-bit lands at
~17GB, leaving ~9GB of KV pool. NVFP4 scores slightly better on accuracy
(71.5 vs 69.4 MMLU) while AWQ is faster at single-request concurrency.

Note this is a separate axis from `--kv-cache-dtype fp8`, which quantizes the
KV cache rather than the weights.

**Caches.** `~/.cache/huggingface` holds the weights; `~/.cache/vllm` holds
torch.compile artifacts. Persisting the latter is what makes restarts faster
than first boot. It is invalidated when engine flags such as `--max-model-len`
change.

## Tuning

**Context.** `--max-model-len 65536` fits on this card without any KV cache
quantization — MLA compresses the cache enough that 64k is reachable with
16-bit KV.

Do **not** add `--kv-cache-dtype fp8`. It fails on consumer Blackwell; see
Troubleshooting.

If a given `--max-model-len` does not fit, vLLM refuses to start and reports the
maximum sequence length it could serve — use that number. The startup log's
memory profiling line shows where the budget went.

opencode's `limit.context` is deliberately lower than `--max-model-len`
(49152 vs 65536). Preserved Thinking keeps reasoning blocks in the transcript,
and opencode's token accounting probably does not count `reasoning_content`, so
without slack it will undercount and overshoot the server's limit.

Note that the model's architectural maximum (202,752) is far above its
*effective* range. Community reports put degradation for this model past
roughly 50k tokens in agentic sessions. Set `--max-model-len` to what VRAM
allows, but keep opencode's `limit.context` lower so compaction triggers before
quality drops.

**Throughput.** `--speculative-config.method mtp` with
`num_speculative_tokens 1` is worth trying, but MTP layers may not survive AWQ
quantization — get a known-good boot first.

**Startup time.** `--enforce-eager` skips CUDA graph capture, cutting startup
from roughly 1-2 minutes to 30-60 seconds at the cost of slower decode. Worth it
only if you restart or swap models frequently. Graph capture is never cached;
CUDA graphs are live GPU objects that cannot persist across processes.

Note that vLLM 0.28.0 raised the Blackwell CUDA graph capture default to 1024,
so startup on this card captures more graph sizes than it used to — more
startup time and more VRAM. Capping the captured sizes is a middle ground
between the default and `--enforce-eager`.

**Engine.** vLLM 0.29.0 made Model Runner V2 the default for all models. If you
hit unexplained instability, that is the largest recent change to suspect.

**Sharing the GPU.** `--gpu-memory-utilization` controls memory only, not
compute, and vLLM claims its pool statically at boot. Lowering it to 0.75 frees
~8GB but removes ~5GB of KV cache. For occasional GPU-heavy work,
`systemctl --user stop glm-flash` is simpler and costs nothing in context. CUDA
MPS (`CUDA_MPS_ACTIVE_THREAD_PERCENTAGE`) is the real compute-partitioning tool
if workloads must run concurrently, but its daemon runs on the host, not in the
container, and per-user UID matching under rootless Podman is fiddly.

## Model switching

**Request-driven, via llama-swap.** llama-swap reads the `model` field from the
incoming request, starts the matching backend if it isn't running, and proxies
through. Setup is in `llama-swap/llama-swap.service`; the model definitions are
in `llama-swap/config.yaml`.

It runs as a native binary rather than a container. It spawns podman containers
itself, so containerising it would mean bind-mounting the rootless podman socket
so it could start siblings — more moving parts, and another thing that can break
the way GPU passthrough did. It is a single static Go binary.

Three things worth knowing before committing to it:

- **It does not make swapping cheap, only automatic.** A swap is still a full
  vLLM cold start: roughly 1-2 minutes with a warm torch.compile cache, much
  longer on first run. llama-swap's default `healthCheckTimeout` of 120s is well
  short of that and produces spurious mid-swap failures, so the config sets 1800.
  There is a known readiness-check gap where a too-tight timeout surfaces errors
  to the client instead of queueing.
- **It wants to own the container lifecycle** through `cmd`/`cmdStop`. That is
  why the Quadlet units are not started alongside it — the port collision and the
  `Conflicts=` lines make the two paths mutually exclusive on purpose.
- **llama.cpp is its best-supported backend**, not vLLM. Running Python inference
  servers under podman is the project's own recommendation, which is what the
  config does.

`ttl: 1800` unloads an idle model after 30 minutes so the card is free when you
walk away. `POST /api/models/unload` does it immediately, and `/ui` shows what is
loaded.

## Model comparison

All four are 30B-class MoE with roughly 3-4B active parameters, so they are
comparable on speed. They differ in how KV cache grows, which is the thing that
actually binds at 32GB.

| Model | Total / active | Native context | KV growth | Thinking |
|---|---|---|---|---|
| GLM-4.7-Flash | 31.2B / ~3B | 202K | Global attention, MLA-compressed | Yes, server-side |
| Qwen3-Coder-30B-A3B | 30.5B / 3.3B | 262K | GQA, 4 KV heads over 48 layers | No — none at all |
| Nemotron 3 Nano 30B-A3B | 31.6B / ~3.2B | 1M | Only 6 of 29 layers attend; rest is fixed Mamba state | Yes, with token budget |
| Gemma 4 26B-A4B | 25.2B / 3.8B | 256K | 1024-token sliding window | Yes, off by default |

`--max-model-len` in each unit is a starting point, not a measurement. Only
GLM's 65536 is empirically confirmed on this hardware. The others are estimated
from head counts and layer depth; if vLLM refuses to start, step down, and if
`gpu_cache_usage_perc` stays low under real work, raise it.

**Why Nemotron is the interesting one here.** The diagnosed constraint is KV
cache at long context, and only 6 of its 29 layers use attention. The other 23
are Mamba-2, which carry fixed-size recurrent state that does not grow with
sequence length. NVFP4 is the only variant that fits — BF16 is ~60GB and FP8
~30GB leaves nothing for cache — and it is Blackwell-native and published by
NVIDIA rather than community-requantised. It needs a parser file fetched
separately; see the comment in `nemotron-nano.container`.

**Why Qwen3-Coder is worth running even though it is the oldest.** It emits no
reasoning blocks whatsoever, which makes it the clean measurement of what
thinking tokens actually cost. Note it wants different sampling than GLM
(`top_p` 0.8, `top_k` 20, `repetition_penalty` 1.05 — GLM explicitly wants no
penalty), so the setting does not carry over.

**Gemma 4 26B-A4B is incomplete.** Its tool-call parser is unresolved: Gemma 4
supports function calling, but which vLLM parser handles its format is not
confirmed here, and a wrong value fails at startup. Until that is settled the
unit only does plain chat, which is not useful for agentic work. The
`enable_thinking` key name is likewise unverified. Both are flagged inline.

**Gemma 4 31B is deliberately absent.** It is dense (30.7B, 60 layers), not MoE.
It fits 32GB at 4-bit, around 17-18GB of weights, so the problem is not memory:
it activates all 30.7B per token where these models activate 3-4B. Decode on a
single 5090 is memory-bandwidth-bound, so expect several times slower
generation. MoE is the reason the current setup feels responsive.

## What actually fills the context window

Worth recording, because it redirects the tuning effort. Setting
`clear_thinking: true` on GLM — which drops prior turns' reasoning from the
transcript — did **not** change compaction frequency. Still every 1-3 steps at
45056 client context, with cross-turn behaviour unchanged.

So reasoning retention was not the driver. Tool output is: a single 800-line file
read is comfortably 10-15k tokens, so two reads and a directory listing exhaust a
45k window regardless of what the model does internally. That is why the
comparison above is organised around KV efficiency rather than reasoning
behaviour, and it means the cheapest available lever is client-side — targeted
reads instead of whole-file reads, and tighter tool output — not model choice.

It also settles `clear_thinking`, which stays at **`false`**. `true` was supposed
to buy slower context growth and did not, so its only upside does not exist here,
while its cost does: the model stops seeing its own prior chain of thought.
Retained reasoning is also where it records which approaches it already tried and
rejected, and that is the first thing compaction destroys. Flip to `true` only if
you catch the model anchoring on a stale plan from an earlier turn.

Beware of one inference trap in evaluating this: both settings feel far better
than Ollama did, for reasons unrelated to either — real context and working
sampling parameters. Judging `clear_thinking` means comparing the two settings to
each other, not to the old setup.

## Why compaction fired every 1-3 steps

The window opencode actually works in is not `limit.context`. Before every model
call it estimates system prompt + messages + tool schemas and compacts if that
exceeds:

    limit.context - max(limit.output, compaction.buffer)

With the original `limit.context: 45056`, `limit.output: 16384` and the default
`compaction.buffer` of 20000, the trigger sat at **25056** tokens — a little over
half the configured limit. Two file reads. Meanwhile `keep.tokens` defaults to
15000, so each compaction retained 15k verbatim and summarized only the ~10k
above it: constant compaction that reclaimed almost nothing, which is the
recursive-summary churn that degrades quality fastest.

`limit.output` is the strongest lever because it sits inside that `max()`.
Lowering it from 16384 to 8192 and spending the freed room on context nearly
doubles the working window at no VRAM cost:

| Model | Server `max-model-len` | context | output | request total | compaction trigger |
|---|---|---|---|---|---|
| glm-4.7-flash | 65536 | 53248 | 8192 | 61440 | 45056 |
| qwen3-coder | 98304 | 86016 | 8192 | 94208 | 77824 |
| nemotron-nano-3 | 131072 | 118784 | 8192 | 126976 | 110592 |
| gemma-4-26b-a4b | 98304 | 86016 | 8192 | 94208 | 77824 |

GLM goes from 25056 to 45056 tokens of usable window, a 1.8x gain, and every row
leaves 4096 tokens of slack under its server ceiling. 8192 output tokens is still
generous for agentic coding; compaction's own summary call is capped at 4096
regardless.

`prune: true` is set because the diagnosed problem is tool output volume
specifically — it drops old completed tool results rather than summarizing them.
Note it is documented but reported as unused in some builds' core compaction
path, so treat it as opportunistic.

Two version caveats. The config schema moved around: some builds take
`compaction.buffer` and `compaction.keep.tokens`, others `compaction.reserved`.
Check what yours accepts. And setting `buffer` below `limit.output` does nothing,
since the `max()` takes whichever is larger.

Raise `keep.tokens` if post-compaction sessions keep losing recent specifics; it
costs room for new work, so move it in step with the trigger.

## Enforcing token discipline

Files in `opencode/` — copy to your project's `.opencode/`, or to
`~/.config/opencode/` to apply everywhere.

Two layers, and the difference in reliability is the whole point:

- `opencode/plugin/context-budget.ts` — **mechanical**. Truncates oversized tool
  output, rejects unscoped reads of large files, and rejects re-reads of files
  already in context. Cannot be ignored, and costs no context.
- `opencode/AGENTS.md` — **advisory**, for what hooks cannot express. Kept
  deliberately short: it sits in the system prompt on every request and
  compaction never reclaims it.

Prompt instructions alone do not hold. A 30B local model drifts from "grep before
reading" once a task gets complicated, which is exactly when context is scarcest.

Three implementation notes that are easy to get wrong:

- The plugin enforces by **throwing**, not by rewriting `output.args`. Argument
  mutation in `tool.execute.before` has a known bug where the tool still runs with
  the original arguments, so a rewrite can silently no-op. A thrown error reliably
  reaches the model as the tool result and doubles as a teaching signal.
- The re-read block compares **mtime**, so edit-then-verify loops still work: after
  an edit the file is newer and re-reading is allowed. A naive "read once" rule
  would break verification.
- `tool.execute.after` fires *before* output assembly for **MCP** tools, so
  truncation is a no-op there. Native tools (`read`, `grep`, `bash`) are fine.

Two related wins worth taking at the same time:

- **Disable tools you don't use.** Tool schemas are part of the fixed,
  uncompactable overhead, so a dozen unused tools cost real window on every
  request. Use V2 `permissions` (`{"action": "...", "resource": "*", "effect":
  "deny"}`) rather than the deprecated `tools` map.
- **Use subagents** (`mode: subagent`) for exploration. A subagent searches in its
  own context window and returns only its conclusions, so the main thread never
  accumulates the raw material. This is the single largest lever available, and it
  is how frontier harnesses keep long sessions coherent.

One trap: opencode V2 accepts an `instructions` array in config but **does not
resolve it** — globs, paths, and URLs there are silently ignored. Use `AGENTS.md`.
V1 did honour `instructions`.

### Prefer the community plugins over the hand-rolled ones

The two plugins in `opencode/plugin/` were written before surveying what exists.
They work, but the ecosystem versions are better and should be installed first.
See [awesome-opencode](https://github.com/awesome-opencode/awesome-opencode).

| Plugin | What it does | Claimed reduction |
|---|---|---|
| [opencode-agent-context-pruning](https://github.com/tuanhung303/opencode-agent-context-pruning) | Deduplicates re-reads; "one-file-one-view" keeps only the latest read/edit of each file. Zero config. | 50% typical, 65% file-heavy |
| [opencode-dcp](https://github.com/Opencode-DCP/opencode-dynamic-context-pruning) | Exposes a `compress` tool so the *model* chooses when and what to compress, per message or range | 50-70% long sessions |
| [opencode-snip](https://github.com/awesome-opencode/awesome-opencode) | Shell proxy that filters output per tool — knows `git`, `cargo`, `npm`, `docker`, `go` | 60-90% bash-heavy |
| OpenSlimedit | Shortens built-in tool *descriptions* and compacts read output; attacks the fixed uncompactable schema tax | 11-45% every call |

ACP supersedes the re-read logic in `context-budget.ts` and does it better: it
replaces the stale copy rather than throwing an error, so there is no failed
round-trip and the newest read simply wins. opencode-snip supersedes the
truncation, since per-tool semantic filtering beats a blind character cap —
it keeps errors and summary lines rather than an arbitrary head and tail.

`compaction-structured.ts` still has a place; none of the above replace the
compaction *prompt*.

**Magic Context needs a second model slot, but it does not have to be on the GPU.**
It runs a background "historian" that compresses history while the main agent
works. Pointing that at a GPU model would mean a llama-swap cycle per compression,
which is unusable here — but `historian.opencode.model` takes any
`provider/model-id`, so a CPU-hosted small model works and sidesteps the conflict.
See "Running the historian on CPU" below.

Measurement plugins worth having, since the budgeting above is guesswork without
them: Context Analysis, Token Monitor, Tokenscope.

### What the local-agent community converged on

- **Keep utilisation between 30% and 65%**, and compact well before the limit.
  Defaults are tuned for 200K frontier windows and fire far too late for a local
  32-64K one. Several practitioners target under 40%.
- **Compaction invalidates the KV prefix cache** from the changed point onward, so
  every compaction forces a full reprefill. This is a local-specific cost that API
  users do not feel the same way, and it is the mechanical reason short sessions
  often beat large windows on one GPU. It also means each compaction costs latency
  on top of the quality loss already documented above.
- **Manual handoff beats auto-compaction** for many: at 50-70% utilisation, have
  the agent write a summary to a file, clear the session, and resume from that
  file. You get to inspect and correct the summary before it becomes the only
  surviving record — which auto-compaction never offers.
- **Compress selectively, not uniformly.** The better tools run a "crushability"
  check first: repetitive logs and search hits compress well, but unique
  high-entropy records (distinct IDs, no ranking signal) lose entities if
  compressed, so they are passed through untouched.
- **Never let raw `find`, `ls -R`, or full test logs into the window.** Keep the
  tail of a failure, since that is where the assertion is.

### Running the historian on CPU

The historian summarizes a chunk of conversation and emits a short compartment.
That is prefill-heavy and generation-light, it runs in the background, and it does
not need a large model — which makes it one of the few genuinely CPU-suitable jobs
in this stack.

Rough arithmetic for a ~20k-token compartment producing a ~2k-token summary, with
llama.cpp on a modern desktop CPU:

| Historian model | Prefill | Generation | Total |
|---|---|---|---|
| 4B Q4 | ~100s | ~100s | 3-4 min |
| 8B Q4 | ~200s | ~165s | ~6 min |

Prefill is compute-bound and generation is bandwidth-bound — dual-channel DDR5 is
roughly 96 GB/s against the 5090's ~1.8 TB/s, so expect 15-25 tok/s of generation
from a 4B Q4 model rather than the GPU's triple digits.

Setup:

1. Run `llama-server` (not vLLM — its CPU backend is experimental and not built
   for this) with a 3-8B instruct model on a spare port, as its own systemd user
   service. Keep it **out of llama-swap**: it has to run concurrently with the GPU
   model, and llama-swap swaps by default.
2. Add it as a second opencode provider pointing at that port.
3. Reference it as `historian.opencode.model` in `magic-context.jsonc`.

Four things that will bite:

- **Pin the thread count.** llama.cpp will happily take every core and starve
  vLLM's scheduler, tokenizer, and API server, slowing GPU inference. Leave at
  least four cores free.
- **Raise `historian_timeout_ms`.** The default is 300000 (5 min), which a 4B
  single pass fits and an 8B or two-pass run does not.
- **Set `two_pass: true`.** The project explicitly recommends it for open-weight
  local models, where single-pass drafts are noisier. It also doubles historian
  time, so budget for that.
- **Built-in compaction must be disabled**, or the two systems corrupt each
  other's state. That means `compaction.auto: false`, and the tuning in "Why
  compaction fired every 1-3 steps" plus `compaction-structured.ts` stop applying.

The real risk is throughput, not latency. Background work is fine when it keeps
up; if the GPU generates context faster than a CPU historian can compress it, the
backlog grows and you end up in the same place. Watch `/ctx-status`.

Note the plugin's default historian is a cloud model
(`github-copilot/claude-sonnet-4-6`) and the design deliberately prefers
request-priced cloud routing for these single-prompt background calls. CPU-local is
going against the grain, which is fine, but it is not the tested path.

### On model "forks" with these optimisations

There are none, because this is harness-side work rather than weights-side. No
checkpoint can deduplicate your file reads or prune your tool output — the model
never sees the transcript it would need to edit.

What does exist at the model level, and is already covered by the choices here:
agentic post-training for tool-use discipline (all four models), non-thinking
variants that simply emit fewer tokens (Qwen3-Coder), explicit thinking-token
budgets (Nemotron), and RoPE-scaled long-context variants. Context *management*
stays in the harness.

## Monitoring

**Logs.** `--output=cat` strips systemd's prefix so vLLM's own formatting stays
readable:

```bash
journalctl --user -u glm-flash -f --output=cat
```

`podman logs -f glm-flash` reads the container directly and handles progress
bars better, since journald mangles carriage returns.

Startup milestones, in order: `Loading model weights took ... GB and ...
seconds`, torch.compile output (the slow phase on a cold cache),
`Graph capturing finished`, a line reporting GPU KV cache size and maximum
concurrency, then `Application startup complete`.

**Download progress** during first boot, which is otherwise a long silence:

```bash
watch -n5 du -sh ~/.cache/huggingface     # climbs toward ~17GB
```

**Readiness:**

```bash
curl -fsS localhost:8000/health && echo OK
```

**VRAM.** `nvidia-smi` will show ~90% used, because that is what
`--gpu-memory-utilization` was told to take. A near-full card is the expected
state, not a warning.

```bash
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
```

The useful breakdown — weights vs non-torch vs activation peak vs KV cache — is
in the startup log:

```bash
journalctl --user -u glm-flash \
  | grep -i -E 'memory profiling|KV cache size|model weights|maximum concurrency'
```

**Live KV utilization.** `vllm:gpu_cache_usage_perc` near 1.0 means you are at
your context limit and requests will queue or be preempted:

```bash
curl -s localhost:8000/metrics | grep -E 'gpu_cache_usage|num_requests'
```

## Troubleshooting

**Unit won't parse.** See the actual `podman run` command Quadlet generates:

```bash
/usr/libexec/podman/quadlet -dryrun -user
```

If your Podman version rejects CDI names in `AddDevice=`, replace that line
with `PodmanArgs=--device nvidia.com/gpu=all`.

### GPU not visible in the container

Test with a small image rather than pulling 10GB of vLLM to find out:

```bash
podman run --rm --device nvidia.com/gpu=all --group-add keep-groups \
  docker.io/nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi
```

Work through these in order.

**`Failed to initialize NVML: Insufficient Permissions`** — the common one on
Gentoo. Its udev rules make `/dev/nvidia*` mode 0660 owned by `root:video`,
which is why Gentoo requires joining the `video` group. Rootless Podman drops
supplementary groups by default, so the container user is not in `video`.
Fix with `--group-add keep-groups` (`GroupAdd=keep-groups` in the unit, already
set). Requires crun, not runc.

Confirm the premise with `ls -l /dev/nvidia*` and `id`.

**`Can't initialize NVML` / `No CUDA runtime found`** — usually no CDI spec.
Installing `nvidia-container-toolkit` does not generate one; `nvidia-ctk cdi
generate` is a separate step. Check `ls -l /etc/cdi/`.

**Stale CDI spec.** The spec hardcodes paths to versioned driver libraries
(e.g. `libcuda.so.610.57.04`). After any `nvidia-drivers` rebuild those paths
can dangle, and injection then silently produces a broken driver environment.
Compare the spec's mtime against the driver install and regenerate.

**`nvidia_uvm` not loaded at generation time.** If the module was absent when
the spec was generated, `/dev/nvidia-uvm` is omitted and CUDA fails even though
`nvidia-smi` may work. Check `lsmod | grep nvidia_uvm`, `modprobe nvidia-uvm`,
then regenerate.

A correct spec has all four global device nodes: `/dev/nvidia-uvm`,
`/dev/nvidia-uvm-tools`, `/dev/nvidiactl`, `/dev/nvidia-modeset`. Warnings from
`nvidia-ctk` about Vulkan layer files, persistenced/fabricmanager sockets, and
IMEX tools are cosmetic and irrelevant to compute.

**Still failing rootless.** Add `no-cgroups = true` to
`/etc/nvidia-container-runtime/config.toml`. On a hardened profile with
SELinux, also try `--security-opt=label=disable`. Comparing against
`sudo podman run ...` isolates whether the problem is rootless-specific.

### `OutOfResources: out of resource: shared memory`

```
Required 102400, Hardware Limit: 101376
```

Caused by `--kv-cache-dtype fp8`. 101376 bytes (99KB) is the maximum shared
memory per block on consumer Blackwell (sm_120); datacenter parts such as B200
and H100 have 227KB. The Triton MLA kernel with an fp8 KV cache needs 100KB and
overshoots by 1KB.

Not configurable around, and independent of `--max-model-len` — shared memory is
per-kernel-tile, set by head dimensions and block sizes, not sequence length.
Lowering the context length will not help.

Drop the flag. It is unnecessary here anyway, since 65536 fits with 16-bit KV.
Alternative MLA attention backends (FlashMLA, CUTLASS MLA) are datacenter-only,
so Triton MLA is the only path on this card.

### Out of memory

Two different failures both get called OOM. Identify which:

```bash
journalctl --user -u glm-flash | grep -i -E 'out of memory|maximum context|exceeds'
```

**"maximum context length is N tokens, however you requested M output tokens
and your prompt contains at least K input tokens"** — not a VRAM problem.

`--max-model-len` is a *total* budget: prompt plus requested output. A
`max_tokens` of 16384 against a 32768 window leaves only 16384 for the prompt,
whether or not the model generates that much. The rule is
`max_model_len >= prompt + max_tokens`.

opencode's `limit.output` becomes that reservation, so it has to be budgeted
for. Keep `limit.context + limit.output` comfortably below `--max-model-len`;
opencode may treat `limit.context` as the total window or as the maximum
prompt, and the settings here (53248 + 8192 against 65536, leaving 4096 spare)
are safe under either reading.

`limit.output` does double duty: besides this reservation it also sets the
compaction trigger point, which is why it is 8192 rather than 16384. See "Why
compaction fired every 1-3 steps" above.

Preserved Thinking makes the margin matter more, since reasoning blocks stay in
the transcript and opencode's accounting probably does not count
`reasoning_content`.

**A genuine CUDA OOM** means something else took VRAM after vLLM claimed its
pool at boot — a desktop session, a game, video decode. At 0.90 utilization
there is only ~3GB of headroom. Check with
`nvidia-smi --query-compute-apps=...` and drop to 0.85 or 0.80 if needed, at
the cost of KV cache.

**Failure on the first prompt of a fresh session** points at neither of the
above. A new session has no history to overflow, so the likely cause is another
live session still holding KV blocks. `--max-num-seqs 2` means concurrent
sessions share one fixed pool rather than each getting their own. Prefer one
session at a time; raising `max-num-seqs` does not help because the pool size
is fixed.

**Unknown flag at startup.** If `--default-chat-template-kwargs` or
`--override-generation-config` are rejected, drop
`--override-generation-config` first and set sampling in opencode instead.
Losing `--default-chat-template-kwargs` is the more serious one — without it
there is no Preserved Thinking.

**`glm4_moe_lite` architecture not recognized.** Historical, fixed in vLLM
0.28.0 by the transformers 5.15.0 bump. If you see it, you are on vLLM 0.27 or
older — upgrade rather than working around it. The old workaround was the
`vllm/vllm-openai:glm5` image, or installing vLLM nightly *first* and then
transformers from git (the reverse order let vLLM downgrade transformers back).

**Container starts but takes no arguments.** vLLM 0.29.0 deprecated
`python -m vllm.entrypoints.openai.api_server` in favor of `vllm serve`. The
unit passes bare flags and relies on the image entrypoint. If the image
entrypoint changed, prepend `serve` to the `Exec=` line.

**opencode doesn't see the model.** The provider block is written against the
standard `@ai-sdk/openai-compatible` shape; check it against current opencode
config docs.
