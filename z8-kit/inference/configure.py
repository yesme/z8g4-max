#!/usr/bin/env python3
"""Generate local DeepSeek 1017 launch profiles for 1Cat and Xolotl."""
import argparse
import json
from pathlib import Path


def existing(value):
    path = Path(value).expanduser().resolve()
    if not path.exists():
        raise argparse.ArgumentTypeError(f"{path} does not exist")
    return str(path)


def onecat(args):
    import yaml

    data = yaml.safe_load(Path(args.upstream).read_text(encoding="utf-8"))
    try:
        data["kernel-config"]["sm70_gguf"]["expert_cache_offload_fraction"] = args.offload
        data["kernel-config"]["sm70_gguf"]["expert_cache_prefill_tokens"] = args.batch
        data["model-loader-extra-config"]["engram_path"] = args.engram
    except (KeyError, TypeError) as exc:
        raise SystemExit(f"Expected the 1Cat #1277 recipe structure: {exc}") from exc

    speculative = data.pop("speculative-config", None)
    for key in ("no-enforce-eager", "compilation-config", "async-scheduling", "enable-prefix-caching"):
        data.pop(key, None)
    if args.draft:
        if not isinstance(speculative, dict) or speculative.get("method") != "dspark":
            raise SystemExit("For DSpark, use the matching 1Cat phase3 YAML as --upstream")
        speculative["model"] = args.draft
        data["speculative-config"] = speculative
    data.update({
        "model": args.model,
        "hf-config-path": args.tokenizer,
        "tokenizer": args.tokenizer,
        "host": "127.0.0.1",
        "port": args.port,
        "served-model-name": "deepseek-v4.1-flash-1017",
        "max-model-len": args.context,
        "max-num-seqs": 1,
        "max-num-batched-tokens": args.batch,
        "gpu-memory-utilization": 0.90,
        "enforce-eager": True,
        "no-enable-prefix-caching": True,
        "reasoning-parser": "deepseek_v4",
        "default-chat-template-kwargs": '{"thinking": false}',
    })
    return yaml.safe_dump(data, sort_keys=False)


def xolotl(args):
    repo = Path(args.repo)
    gpu = [int(value) for value in args.gpu.split(",")]
    if len(gpu) not in (1, 2, 4) or len(set(gpu)) != len(gpu) or min(gpu) < 0:
        raise SystemExit("Give one, two or four distinct GPU indices in PCI order")
    if len(gpu) > 1 and (args.parallel > 1 or args.prefix_cache):
        raise SystemExit("The DS41 layer-split path needs --parallel 1 and no persistent prefix cache")
    for key in ("docs/BUSTER.md", "tools/buster/buster-engine.sh"):
        if not (repo / key).is_file():
            raise SystemExit(f"Missing {repo / key}; check the pinned Xolotl tree")
    default_arena_gib = 24 if len(gpu) == 4 else 48
    arena_gib = args.arena_gib if args.arena_gib is not None else default_arena_gib
    data = {
        "exe": str(repo / "tools/buster/buster-engine.sh"),
        "cwd": str(repo),
        "args": [
            "-m", args.model, "--backend", "cuda", "--experts", "gpu",
            "--engram", ":".join(args.engram),
            "--ctx", str(args.context), "--stop", "1", "--arena-adapt",
            "--route-bias", "0", "--route-bias-file", "0",
            "--arena-gib", str(arena_gib), "--no-chunk-mmq",
            "--prompt-batch", str(args.batch), "--pcie", "0.55",
        ],
        "tokenizer": args.tokenizer,
        "model_name": "deepseek-v4.1-flash-1017",
        "log": str(Path(args.log).expanduser().resolve()),
        "host": "127.0.0.1",
        "port": args.port,
        "gpu": gpu,
        "sampling": {"temperature": 0, "top_p": 1},
        "parallel": args.parallel,
    }
    if args.rank:
        data["args"].extend(["--rank", args.rank])
    if len(gpu) > 1:
        data["layer_split"] = "20" if len(gpu) == 2 else "10,20,30"
    env = {"STRATA_ENGRAM_RAWDEV": "0"}
    if args.draft:
        env.update({
            "STRATA_SERVE_DSPARK": args.draft,
            "STRATA_DSPARK_DEPTH": str(args.draft_tokens),
        })
    if args.prefix_cache:
        env.update({
            "STRATA_PREFIX_CACHE_DIR": args.prefix_cache,
            "STRATA_PREFIX_CACHE_BYTES": str(16 << 30),
            "STRATA_PREFIX_CACHE_MIN_FREE_BYTES": str(20 << 30),
            "STRATA_PREFIX_CACHE_QUEUE_BYTES": str(2 << 30),
        })
    data["env"] = env
    return json.dumps(data, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    variants = parser.add_subparsers(dest="engine", required=True)
    cat = variants.add_parser("1cat")
    xo = variants.add_parser("xolotl")
    for variant, port, batch in ((cat, 18000, 512), (xo, 8150, 1024)):
        variant.add_argument("--model", type=existing, required=True)
        variant.add_argument("--tokenizer", type=existing, required=True)
        variant.add_argument("--context", type=int, default=4096)
        variant.add_argument("--port", type=int, default=port)
        variant.add_argument("--batch", type=int, default=batch)
        variant.add_argument("--output", type=Path, required=True)
        variant.add_argument("--draft", type=existing, help="DSpark weights on the PMem model volume")
    cat.add_argument("--upstream", type=existing, required=True)
    cat.add_argument("--engram", type=existing, required=True)
    cat.add_argument("--offload", type=float, default=0.75)
    xo.add_argument("--repo", type=existing, required=True)
    xo.add_argument("--engram", type=existing, nargs="+", required=True,
                    help="One Engram GGUF or two raw Engram directories")
    xo.add_argument("--rank", type=existing, help="Optional expert ranking for this model")
    xo.add_argument("--gpu", required=True)
    xo.add_argument("--log", default="xolotl-1017.log")
    xo.add_argument("--arena-gib", type=int, help="Pinned expert arena limit per stage, in GiB")
    xo.add_argument("--parallel", type=int, choices=(1, 2, 4), default=1)
    xo.add_argument("--draft-tokens", type=int, choices=range(1, 6), default=1)
    xo.add_argument("--prefix-cache", type=existing, help="Existing private PMem directory for single-stage checkpoints")
    args = parser.parse_args()

    if args.batch < 1 or args.context < 128 or not 1 <= args.port <= 65535:
        parser.error("Invalid batch, context or port")
    if args.engine == "1cat" and not 0 < args.offload < 1:
        parser.error("Offload must be in (0, 1)")
    if args.engine == "xolotl":
        engram_paths = [Path(value) for value in args.engram]
        if len(engram_paths) == 1:
            engram = engram_paths[0]
            if not engram.is_file() or engram.suffix != ".gguf":
                parser.error("A single Engram path must be a GGUF file")
        elif len(engram_paths) != 2 or not all(path.is_dir() for path in engram_paths):
            parser.error("Raw Engram requires two directories")
        if args.rank and not Path(args.rank).is_file():
            parser.error("Rank must be a file")
        if args.arena_gib is not None and args.arena_gib < 1:
            parser.error("Arena must be positive")
        if args.prefix_cache and not Path(args.prefix_cache).is_dir():
            parser.error("Prefix cache must be a directory")
    if args.draft and Path(args.draft).is_dir() != (args.engine == "1cat"):
        parser.error("DSpark requires a checkpoint directory for 1Cat or a GGUF file for Xolotl")
    content = onecat(args) if args.engine == "1cat" else xolotl(args)
    with args.output.open("x", encoding="utf-8") as out:
        out.write(content.rstrip() + "\n")


if __name__ == "__main__":
    main()
