import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
from unittest.mock import patch

probe_path = Path(__file__).resolve().parents[1] / "z8-kit/inference/probe.py"
spec = importlib.util.spec_from_file_location("probe", probe_path)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def run(parallel):
    def fake_response(request, timeout):
        payload = json.loads(request.data)
        assert payload["max_tokens"] == 256
        prompt = payload["messages"][-1]["content"]
        reply = prompt.rsplit(": ", 1)[-1] if prompt.startswith("Repeat exactly") else "ok"
        event = json.dumps({"choices": [{"delta": {"content": reply}}]}).encode()
        return io.BytesIO(b"data: " + event + b"\n\ndata: [DONE]\n\n")

    output = io.StringIO()
    args = ["probe.py", "--repeats", "1", *parallel]
    with (
        patch.object(probe, "urlopen", side_effect=fake_response) as urlopen,
        patch.object(sys, "argv", args),
        contextlib.redirect_stdout(output),
    ):
        probe.main()
    assert urlopen.call_count == (10 if parallel else 4)
    return [json.loads(line)["case"] for line in output.getvalue().splitlines()]


assert run([]) == ["A", "A-repeat", "B-shared", "A-after-B", "summary"]
assert "parallel-markers-combined" in run(["--parallel-pairs"])
print("Inference probe tests passed: single-slot default and explicit concurrent pairs.")
