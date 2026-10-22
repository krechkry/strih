"""Copies an MLX safetensors checkpoint without the image part (vision tower + projector).
Byte for byte: the text weights are untouched, so translation quality is the same.
Usage: python3 strip_vision.py in_dir out_dir"""
import json, os, struct, sys

src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)

def is_vision(name):
    return name.startswith(("vision_tower", "multi_modal_projector")) or ".vision_tower." in name

index = json.load(open(os.path.join(src, "model.safetensors.index.json")))
files = sorted(set(index["weight_map"].values()))
kept_map, total_in, total_out = {}, 0, 0
for f in files:
    path = os.path.join(src, f)
    total_in += os.path.getsize(path)
    with open(path, "rb") as fh:
        n = struct.unpack("<Q", fh.read(8))[0]
        header = json.loads(fh.read(n))
        base = 8 + n
        meta = header.pop("__metadata__", None)
        keep = {k: v for k, v in header.items() if not is_vision(k)}
        dropped = [k for k in header if is_vision(k)]
        print(f"{f}: {len(header)} tensors, dropping {len(dropped)} vision tensors")
        # new layout: kept tensors packed in their original order
        order = sorted(keep.items(), key=lambda kv: kv[1]["data_offsets"][0])
        new_header, off = {}, 0
        for k, v in order:
            a, b = v["data_offsets"]
            new_header[k] = {"dtype": v["dtype"], "shape": v["shape"], "data_offsets": [off, off + (b - a)]}
            off += b - a
        if meta is not None:
            new_header["__metadata__"] = meta
        hb = json.dumps(new_header, separators=(",", ":")).encode()
        hb += b" " * ((8 - len(hb) % 8) % 8)
        out = os.path.join(dst, f)
        with open(out, "wb") as o:
            o.write(struct.pack("<Q", len(hb)))
            o.write(hb)
            for k, v in order:
                a, b = v["data_offsets"]
                fh.seek(base + a)
                left = b - a
                while left:
                    chunk = fh.read(min(left, 64 << 20))
                    o.write(chunk)
                    left -= len(chunk)
        total_out += os.path.getsize(out)
        for k in keep:
            kept_map[k] = f

index["weight_map"] = kept_map
index.setdefault("metadata", {})["total_size"] = total_out
json.dump(index, open(os.path.join(dst, "model.safetensors.index.json"), "w"), indent=2)
print(f"weights: {total_in / 1e9:.2f} GB -> {total_out / 1e9:.2f} GB")
