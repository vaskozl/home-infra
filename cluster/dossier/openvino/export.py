# /// script
# dependencies = ["optimum-intel[openvino]", "torch", "torchvision"]
#
# [tool.uv.sources]
# torch = { index = "pytorch-cpu" }
# torchvision = { index = "pytorch-cpu" }
#
# [[tool.uv.index]]
# name = "pytorch-cpu"
# url = "https://download.pytorch.org/whl/cpu"
# explicit = true
# ///
"""export.py MODEL [ovms --configure args...]

Prepare any Hugging Face model (repo id or local dir) for OpenVINO Model Server:
export it to OpenVINO IR once, into /models/<name>, and write /models/config.json
for `ovms --config_path`. If OVMS can infer a generative task (LLM, VLM,
embeddings, whisper, diffusers, ...) it serves the OpenAI API under /v3;
otherwise each graph is a plain model on KServe /v2.

OPTIMUM_ARGS: `optimum-cli export openvino` flags (default "--weight-format int8").
"""
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

sys.path = [p for p in sys.path if not p.startswith("/ovms/")]  # OVMS' own bindings
import openvino as ov
from huggingface_hub import hf_hub_download, list_repo_files, snapshot_download

OVMS = "/ovms/bin/ovms"
CONFIG = Path("/models/config.json")
POOLING = ["modules.json", "1_Pooling/config.json"]  # embeddings pooling; optimum drops it
TOWERS = {"image_embeds": "vision", "text_embeds": "text"}  # CLIP-style dual encoders


def export(model, dst, args):
    local = Path(model).is_dir()
    files = ([str(p.relative_to(model)) for p in Path(model).rglob("*")] if local
             else list_repo_files(model))
    if any(re.fullmatch(r"openvino_[^/]*\.xml", f) for f in files):
        shutil.copytree(model, dst) if local else snapshot_download(model, local_dir=dst)
    else:
        env = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}
        try:
            subprocess.run(["optimum-cli", "export", "openvino", "-m", model, *args, str(dst)],
                           check=True, env=env)
        except subprocess.CalledProcessError:
            # Only image-only repos (a preprocessor, no tokenizer) can be converted directly.
            if (not any(f.endswith("preprocessor_config.json") for f in files)
                    or any("tokenizer" in f for f in files)):
                raise
            print("optimum export failed; converting the vision model directly",
                  file=sys.stderr, flush=True)
            shutil.rmtree(dst, ignore_errors=True)
            convert_vision(model, dst, args)
    for f in set(POOLING) & set(files):
        (dst / f).parent.mkdir(exist_ok=True)
        shutil.copy(Path(model) / f if local else hf_hub_download(model, f), dst / f)


def convert_vision(model, dst, args):
    """Fallback for image encoders optimum doesn't know (e.g. DINOv3, C-RADIO)."""
    import nncf
    import torch
    from transformers import AutoImageProcessor, AutoModel
    trust = "--trust-remote-code" in args
    proc = AutoImageProcessor.from_pretrained(model, trust_remote_code=trust)
    net = AutoModel.from_pretrained(model, trust_remote_code=trust, dtype=torch.float32).eval()
    size = getattr(proc, "crop_size", None) or getattr(proc, "size", None) or {}
    if not isinstance(size, int):
        size = size.get("height") or size.get("shortest_edge") or 224
    # Non-square so H and W are traced separately; 2:1 keeps W a multiple of the patch size.
    x = torch.rand(1, 3, size, 2 * size)
    with torch.no_grad():
        out = net(x)
    names = (list(out.keys()) if hasattr(out, "keys") else
             list(getattr(out, "_fields", [])) or [f"output_{i}" for i in range(len(out))])
    for gen in (m for m in net.modules() if type(m).__name__ == "ViTPatchGenerator" and m.cpe_mode):
        gen._get_pos_embeddings = radio_pos_embeddings.__get__(gen)
    graph = ov.convert_model(net, example_input=x, input=[[-1, 3, -1, -1]])
    graph.inputs[0].set_names({"pixel_values"})
    for out, name in zip(graph.outputs, names):
        out.set_names({name})
    if "int8" in args:
        graph = nncf.compress_weights(graph)
    dst.mkdir(parents=True, exist_ok=True)
    ov.save_model(graph, dst / "openvino_model.xml", compress_to_fp16="fp32" not in args)
    proc.save_pretrained(dst)


def radio_pos_embeddings(self, batch_size, input_dims):
    """C-RADIO's eval-mode position embeddings without Python max(), which the
    tracer would freeze to the example's aspect ratio."""
    import torch
    import torch.nn.functional as F
    h, w = input_dims
    pos = self.pos_embed.reshape(1, self.num_rows, self.num_cols, -1).permute(0, 3, 1, 2)
    s = torch.maximum(torch.as_tensor(h), torch.as_tensor(w))
    pos = F.interpolate(pos.float(), size=(s, s), mode="bilinear", align_corners=False)
    return pos[..., :h, :w].flatten(2).permute(0, 2, 1)


def inputs_of(model, output):
    seen, stack = set(), [output.get_node()]
    while stack:
        node = stack.pop()
        if node.get_friendly_name() not in seen:
            seen.add(node.get_friendly_name())
            stack += [i.get_source_output().get_node() for i in node.inputs()]
    return [p for p in model.get_parameters() if p.get_friendly_name() in seen]


def plain_config(src, name, fp16):
    """Lay out every graph (plus separable towers) as <src>/serve/<model>/1."""
    served, moved = [], []
    shutil.rmtree(src / "serve", ignore_errors=True)  # from an interrupted attempt
    for xml in src.glob("openvino_*.xml"):
        if "tokenizer" in xml.name:
            continue
        part = xml.stem.removeprefix("openvino_").removesuffix("model").strip("_")
        model = ov.Core().read_model(xml)
        towers = {}
        for out in model.outputs:
            tower = TOWERS.get(out.get_any_name())
            if tower and len(params := inputs_of(model, out)) < len(model.inputs):
                towers["-".join(filter(None, [part, tower]))] = (ov.Model([out], params), params)
        # Towers covering every input replace the joint graph (no duplicate weights).
        covered = {p.get_friendly_name() for _, ps in towers.values() for p in ps}
        graphs = {k: m for k, (m, _) in towers.items()}
        if len(covered) < len(model.inputs):
            graphs[part] = model
        for suffix, graph in graphs.items():
            path = src / "serve" / (suffix or "model")
            (path / "1").mkdir(parents=True)
            ov.save_model(graph, path / "1" / "model.xml", compress_to_fp16=fp16)
            served.append({"config": {"name": "-".join(filter(None, [name, suffix])),
                                      "base_path": str(path)}})
        moved.append(xml)
    for xml in moved:  # everything now lives under serve/
        xml.unlink()
        xml.with_suffix(".bin").unlink(missing_ok=True)
    return {"model_config_list": served}


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    model, extra = sys.argv[1], sys.argv[2:]
    args = shlex.split(os.environ.get("OPTIMUM_ARGS", "--weight-format int8"))
    name = re.sub(r"[^\w.-]+", "-", model.rstrip("/").split("/")[-1])
    out = Path("/models") / name
    done = out / ".done"  # records what the export was made from
    origin = shlex.join([model, *args])
    if done.exists() and done.read_text() not in ("", origin):
        sys.exit(f"{out} holds an export of `{done.read_text()}`, not `{origin}`; "
                 "delete it to export again")
    if not done.exists():
        shutil.rmtree(out, ignore_errors=True)
        export(model, out, args)
        done.write_text(origin)

    config = out / "ovms_config.json"
    if not config.exists():
        if not (out / "graph.pbtxt").exists():
            configure = subprocess.run([OVMS, "--configure", "--model_path", str(out), *extra],
                                       capture_output=True, text=True)
        if (out / "graph.pbtxt").exists():
            served = {"model_config_list": [],
                      "mediapipe_config_list": [{"name": name, "base_path": str(out)}]}
        else:
            print("no generative task inferred, serving plain graphs:",
                  configure.stderr.strip().rsplit("\n", 1)[-1], file=sys.stderr, flush=True)
            # Constants optimum left in fp32 (norms, biases, ...) go to fp16 unless asked not to.
            served = plain_config(out, name, "fp32" not in args)
        config.write_text(json.dumps(served, indent=2))
    shutil.copy(config, CONFIG)
    print(f"wrote {CONFIG} for {name}", file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
