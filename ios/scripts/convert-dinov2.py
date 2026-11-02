"""Converts Meta's DINOv2 (ViT-S/14, facebook/dinov2-small, Apache-2.0) to Core ML for Pip's
light-robust linking of sessions (see PipCore's ViewFeatures and docs/spatial-memory.md).

Fixed input: an RGB image of 434 x 574 (31 x 41 patches of 14 px), normalised inside the model.
Output "tokens": (1, 1 + 31*41, 384), the final layer's tokens (the class token first), as the
Hugging Face model gives them in `last_hidden_state`. The position embeddings are interpolated once
for this size here, so the model holds no interpolation.

Writes ios/Models/DINOv2/DINOv2Small.mlpackage (gitignored, like the EdgeTAM models).
Usage (a Python with torch, transformers and coremltools):
    python ios/scripts/convert-dinov2.py [out.mlpackage]
The weights come from Hugging Face (`trust_remote_code=False`, safetensors).
"""
import os
import sys

import coremltools as ct
import numpy as np
import torch
from transformers import AutoModel

WIDTH, HEIGHT, PATCH = 434, 574, 14
MEAN = (0.485, 0.456, 0.406)
STD = 0.226  # one scale for the three channels (0.229, 0.224, 0.225): within 1.3 %

here = os.path.dirname(os.path.abspath(__file__))
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "Models", "DINOv2", "DINOv2Small.mlpackage")

model = AutoModel.from_pretrained("facebook/dinov2-small", trust_remote_code=False, use_safetensors=True).eval()


class Fixed(torch.nn.Module):
    """DINOv2 for one input size: patch embedding, the class token, position embeddings
    interpolated for this size once, the encoder and the final norm."""

    def __init__(self, m):
        super().__init__()
        self.patch = m.embeddings.patch_embeddings
        self.cls = m.embeddings.cls_token
        self.encoder = m.encoder
        self.norm = m.layernorm
        with torch.no_grad():
            dummy = torch.zeros(1, 1 + (WIDTH // PATCH) * (HEIGHT // PATCH), m.config.hidden_size)
            self.register_buffer("pos", m.embeddings.interpolate_pos_encoding(dummy, HEIGHT, WIDTH).detach().clone())

    def forward(self, x):
        p = self.patch(x)  # (1, n, d)
        t = torch.cat([self.cls.expand(x.shape[0], -1, -1), p], dim=1) + self.pos
        h = self.encoder(t).last_hidden_state if hasattr(self.encoder(t), "last_hidden_state") else self.encoder(t)[0]
        return self.norm(h)


fixed = Fixed(model).eval()
example = torch.rand(1, 3, HEIGHT, WIDTH)
with torch.no_grad():
    # The wrapper agrees with the model itself on this size.
    ref = model(pixel_values=example).last_hidden_state
    got = fixed(example)
    print("wrapper vs model: max abs diff", float((ref - got).abs().max()))
    traced = torch.jit.trace(fixed, example)

mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=(1, 3, HEIGHT, WIDTH), color_layout=ct.colorlayout.RGB,
                         scale=1 / (255 * STD), bias=[-m / STD for m in MEAN])],
    outputs=[ct.TensorType(name="tokens")],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,
)
mlmodel.short_description = "Meta DINOv2 ViT-S/14 (facebook/dinov2-small, Apache-2.0): final tokens for a 434x574 image"
os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
mlmodel.save(out)
print("saved", out)
# The Apache-2.0 licence goes with the package, into the app (as EdgeTAM's).
folder = os.path.dirname(os.path.abspath(out))
with open(os.path.join(folder, "DINOv2-NOTICE.txt"), "w") as f:
    f.write("DINOv2Small.mlpackage\n"
            "Core ML conversion of DINOv2 ViT-S/14 (facebook/dinov2-small, https://github.com/facebookresearch/dinov2),\n"
            "Copyright (c) Meta Platforms, Inc. and affiliates, licensed under the Apache License, Version 2.0 (DINOv2-LICENSE.txt).\n\n"
            "Converted by ios/scripts/convert-dinov2.py for a fixed 434 x 574 input: the position embeddings are interpolated\n"
            "once for that size, the image is normalised inside the model, fp16; the weights are otherwise unchanged.\n"
            "Keep this NOTICE and the LICENSE with any copy of the package.\n")
licence = os.path.join(here, "..", "Models", "EdgeTAM", "EdgeTAM-LICENSE.txt")  # the Apache-2.0 text
if os.path.exists(licence):
    with open(licence) as src, open(os.path.join(folder, "DINOv2-LICENSE.txt"), "w") as dst:
        dst.write(src.read())

# Core ML (fp16) against PyTorch on a real-looking input, on the Mac.
try:
    from PIL import Image
    img = (np.random.rand(HEIGHT, WIDTH, 3) * 255).astype(np.uint8)
    pil = Image.fromarray(img)
    pred = mlmodel.predict({"image": pil})["tokens"]
    x = torch.tensor(((img / 255.0 - np.array(MEAN)) / STD).transpose(2, 0, 1)[None], dtype=torch.float32)
    with torch.no_grad():
        t = fixed(x).numpy()
    a = pred[0] / np.linalg.norm(pred[0], axis=1, keepdims=True)
    b = t[0] / np.linalg.norm(t[0], axis=1, keepdims=True)
    print("Core ML vs PyTorch: mean cosine", float((a * b).sum(1).mean()), "min", float((a * b).sum(1).min()))
except Exception as e:  # prediction needs macOS; the package is saved either way
    print("check skipped:", e)
