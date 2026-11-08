FROM docker.io/vllm/vllm-openai:v0.32.0

RUN python3 - <<'PY'
from pathlib import Path

p = Path(
    "/usr/local/lib/python3.12/dist-packages/vllm/"
    "model_executor/layers/quantization/moe_wna16.py"
)
s = p.read_text()

old = '''        quant_method = quant_config.get("quant_method", "").lower()
        num_bits = quant_config.get("bits")
'''

new = '''        quant_method = quant_config.get("quant_method", "").lower()

        # WNA16 compatibility is only defined for GPTQ and AWQ.
        # Avoid running GPTQ validation on other quantization formats.
        if quant_method not in ("gptq", "awq"):
            return False

        num_bits = quant_config.get("bits")
'''

if s.count(old) != 1:
    raise RuntimeError("Expected source block not found exactly once")

p.write_text(s.replace(old, new, 1))
print("Patched", p)
PY
